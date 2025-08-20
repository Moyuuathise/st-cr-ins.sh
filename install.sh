#!/bin/bash

# ==============================================================================
# 项目名称: 随行终端
# 功能:     自动化安装、配置、管理 ClewdR、SillyTavern 和 geminicli2api。
#           支持 Linux (Debian/Ubuntu/Arch 系) 和 Termux 环境。
#           提供代理设置、服务管理、SSH 管理、开机自启等功能。
# 作者:     rzline (原始作者), 404nyaFound (改进与维护)
# 版本：    v1.0.1
# ==============================================================================

# --- 初始化设置 ---

# 启用严格模式：
# -e: 命令非零退出时终止脚本
# -u: 使用未定义变量时报错
# -o pipefail: 管道中任一命令失败则整体失败
set -euo pipefail

# 设置字段分隔符为换行和制表符，避免空格文件名问题
IFS=$'\n\t'

# --- 全局变量定义 ---

# 获取脚本所在绝对路径
DIR=$(cd "$(dirname "$0")" && pwd)

# 定义核心路径
CLEWDR_DIR="$DIR/clewdr"
CONFIG="$CLEWDR_DIR/clewdr.toml"
ST_DIR="$DIR/SillyTavern"
CLI_DIR="$DIR/geminicli2api"
CLI_LOG="$CLI_DIR/proxy.log"
SERVICE="/etc/systemd/system/clewdr.service"
SETTINGS_FILE="$DIR/.settings.conf"
DEFAULT_PROXY="https://ghfast.top"

# 定义配置白名单
WHITELISTED_SETTINGS=(
    "USE_PROXY"
    "CURRENT_PROXY"
    "SSH_AUTOSTART"
    "LAST_VERSION_CHECK"
    "LATEST_SCRIPT_VER"
    "LATEST_CLEWDR_VER"
    "LATEST_ST_VER"
    "LATEST_CLI_VER"
)

# SSH 设置
SSH_USER=$(whoami)  # 当前用户作为 SSH 登录名
SSH_PASS="123456"   # Termux 默认 SSH 密码

# 临时文件用于版本检查
TMP_CLEWDR_VER_FILE=""
TMP_ST_VER_FILE=""
TMP_CLI_VER_FILE=""
TMP_SCRIPT_VER_FILE=""

# --- 核心函数定义 ---

# 清理临时文件
cleanup() {
    rm -f "$TMP_CLEWDR_VER_FILE" "$TMP_ST_VER_FILE" "$TMP_CLI_VER_FILE" "$TMP_SCRIPT_VER_FILE"
}

# 设置退出时自动清理
trap cleanup EXIT

# 保存配置到文件 (白名单模式)
save_settings() {
    local tmp_settings
    tmp_settings=$(mktemp)
    # 遍历白名单，将当前变量值写入临时文件
    for var_name in "${WHITELISTED_SETTINGS[@]}"; do
        # 使用间接变量引用获取变量值，如果未设置则为空
        local value="${!var_name:-}"
        echo "$var_name=\"$value\"" >> "$tmp_settings"
    done
    # 原子操作替换旧的配置文件，防止写入中断
    mv "$tmp_settings" "$SETTINGS_FILE"
}

# 加载配置文件，设置默认值，并清理无效配置
load_settings() {
    # 如果配置文件存在，则加载
    if [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE"
    fi

    # 为白名单内的变量设置默认值（如果它们未被加载）
    USE_PROXY="${USE_PROXY:-true}"
    CURRENT_PROXY="${CURRENT_PROXY:-$DEFAULT_PROXY}"
    SSH_AUTOSTART="${SSH_AUTOSTART:-false}"
    LAST_VERSION_CHECK="${LAST_VERSION_CHECK:-0}"
    LATEST_SCRIPT_VER="${LATEST_SCRIPT_VER:-}"
    LATEST_CLEWDR_VER="${LATEST_CLEWDR_VER:-}"
    LATEST_ST_VER="${LATEST_ST_VER:-}"
    LATEST_CLI_VER="${LATEST_CLI_VER:-}"

    # 立即保存一次，根据白名单清理掉历史遗留的配置项
    save_settings
}

# 打印错误信息并退出
# 参数: $1 错误信息, $2 退出码 (默认 1)
err() {
    echo -e "\033[31m错误: $1\033[0m" >&2
    exit "${2:-1}"
}

# 检查核心依赖
check_deps() {
    local deps=(curl unzip git npm node jq expect)
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "\033[31m缺少依赖: ${missing[*]}\033[0m"
        # 询问用户是否自动安装
        read -rp $'\033[33m是否自动安装依赖? (y/n): \033[0m' confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            err "依赖不足，用户取消安装，退出脚本"
        fi

        # 根据环境执行安装命令
        echo -e "\033[36m开始自动安装依赖...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            pkg update -y && pkg install -y "${missing[*]}" || err "Termux 依赖安装失败"
        else
            # 非 Termux 需 root 权限，提前检查
            [ "$EUID" -ne 0 ] && err "非 Termux 环境安装依赖需 root 权限，请使用 sudo 重新运行脚本"
            sudo apt update -y && sudo apt install -y "${missing[*]}" || err "Linux 依赖安装失败"
        fi
        echo -e "\033[32m核心依赖安装完成\033[0m"
    fi
}

# 检测系统架构和 C 库
detect_arch_libc() {
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo "检测到 Termux 环境"
        ARCH="aarch64"
        LIBC="android"
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) err "不支持的架构: $(uname -m)" ;;
    esac
    LIBC="musllinux"
    echo "检测到常规 Linux 环境"
}

# 获取 GitHub 仓库最新 release 版本或 commit 标记
# 参数: $1 仓库名称 (user/repo), $2 类型 (release 或 commit)
get_latest_ver() {
    local repo_name="$1" type="$2"
    local api_url="https://api.github.com/repos/$repo_name/releases/latest"
    local tag

    if [ "$type" = "commit" ]; then
        api_url="https://api.github.com/repos/$repo_name/commits/main"
        tag=$(curl -sL --connect-timeout 10 "$api_url" | jq -r .sha 2>/dev/null)
    else
        tag=$(curl -sL --connect-timeout 10 "$api_url" | jq -r .tag_name 2>/dev/null)
    fi

    if [[ -n "$tag" && "$tag" != "null" ]]; then
        # 如果是 commit 类型，只取前 7 位
        if [ "$type" = "commit" ]; then
            tag="${tag:0:7}"
        fi
        echo "${tag#v}"
        return 0
    fi

    # 如果是 commit 类型且 API 失败，则直接返回失败
    if [ "$type" = "commit" ]; then
        echo "获取失败"
        return 1
    fi

    local target_url="https://github.com/$repo_name/releases/latest"
    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_url="${CURRENT_PROXY}/${target_url}"
    fi
    local final_redirect_url
    final_redirect_url=$(curl -sL -o /dev/null --connect-timeout 10 -w "%{url_effective}" "$target_url")
    if [[ "$final_redirect_url" == *"github.com"* ]]; then
        local release_tag=$(basename "$final_redirect_url")
        # 避免失败时返回 "latest"
        if [ -n "$release_tag" ] && [ "$release_tag" != "latest" ]; then
            echo "${release_tag#v}"
            return 0
        fi
    fi
    echo "获取失败"
    return 1
}

# 获取本地脚本版本
get_script_ver() {
    # 从脚本自身的注释中提取版本号
    local ver
    ver=$(grep -i '^# 版本：' "$0" | awk '{print $NF}')

    if [ -n "$ver" ]; then
        echo "${ver#v}"
    else
        echo "未知版本"
    fi
}


# 获取本地 SillyTavern 版本
get_st_ver() {
    if [ -f "$ST_DIR/package.json" ]; then
        jq -r .version "$ST_DIR/package.json"
    else
        echo "未安装"
    fi
}

# 获取本地 ClewdR 版本
get_clewdr_ver() {
    if [ -x "$CLEWDR_DIR/clewdr" ]; then
        local ver
        ver=$("$CLEWDR_DIR/clewdr" -V 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
        if [ -n "$ver" ]; then
            echo "$ver"
        else
            echo "未知版本" # 可执行文件存在但无法解析版本
        fi
    else
        echo "未安装"
    fi
}

# 获取本地 geminicli2api commit 标记
get_cli_ver() {
    if [ -d "$CLI_DIR/.git" ]; then
        local ver
        # 抑制错误输出，以防 git 命令失败
        ver=$(cd "$CLI_DIR" && git rev-parse --short=7 HEAD 2>/dev/null)
        if [ -n "$ver" ]; then
            echo "$ver"
        else
            echo "未知版本"
        fi
    else
        echo "未安装"
    fi
}

# 刷新版本缓存
refresh_version_cache() {
    echo -e "\033[36m刷新版本缓存，下次返回主菜单时将重新获取最新版本信息。\033[0m"
    LAST_VERSION_CHECK="0"
    save_settings
}

# 检查 ClewdR 进程
is_clewdr_running() {
    pgrep -f "$CLEWDR_DIR/clewdr" >/dev/null
}

# 检查 SillyTavern 进程
is_st_running() {
    local pids
    pids=$(pgrep -f "node server.js")
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if [ -L "/proc/$pid/cwd" ] && [[ "$(readlink /proc/$pid/cwd)" == "$ST_DIR" ]]; then
                return 0
            fi
        done
    fi
    return 1
}

# 检查 geminicli2api 进程
is_cli_running() {
    local pids
    pids=$(pgrep -f "$CLI_DIR/venv/bin/python.*run\.py")
    if [ -n "$pids" ]; then
        for pid in $pids; do
            if [ -L "/proc/$pid/cwd" ] && [[ "$(readlink /proc/$pid/cwd)" == "$CLI_DIR" ]]; then
                return 0
            fi
        done
    fi
    return 1
}

# 检查 SSH 进程
is_ssh_running() {
    pgrep sshd >/dev/null
}

# 检查脚本自启动
is_autostart_enabled() {
    grep -Fq "# install_sh_autostart" "$HOME/.bashrc"
}

# 获取 SSH 服务名称
get_ssh_service_name() {
    if systemctl list-units --full -all | grep -q 'sshd.service'; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

# 检查 SSH 自启动
is_ssh_autostart_enabled() {
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        [ "$SSH_AUTOSTART" = true ]
    else
        local ssh_service
        ssh_service=$(get_ssh_service_name)
        systemctl is-enabled "$ssh_service" &>/dev/null
    fi
}

# 安装 ClewdR
install_clewdr() {
    detect_arch_libc
    local file="clewdr-${LIBC}-${ARCH}.zip"
    local target_url="https://github.com/Xerxes-2/clewdr/releases/latest/download/$file"

    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_url="${CURRENT_PROXY}/${target_url}"
    fi

    mkdir -p "$CLEWDR_DIR"
    echo -e "\033[36m下载 ClewdR: $target_url\033[0m"
    curl -fL "$target_url" -o "$CLEWDR_DIR/$file" || err "下载失败"
    unzip -oq "$CLEWDR_DIR/$file" -d "$CLEWDR_DIR" || err "解压失败"
    chmod +x "$CLEWDR_DIR/clewdr"
    rm -f "$CLEWDR_DIR/$file"
    echo -e "\033[32mClewdR 安装/更新完成 (${ARCH}/${LIBC})\033[0m"
    read -rsp $'\n按任意键返回主菜单...'
    refresh_version_cache
}

# 安装 SillyTavern
install_st() {
    local target_repo_url="https://github.com/SillyTavern/SillyTavern"
    [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ] && target_repo_url="${CURRENT_PROXY}/${target_repo_url}"

    # ── 只让用户选 release 或 staging ──
    local ST_BRANCH="release"
    if [ -t 0 ]; then
        echo -e "\033[36m请选择要更新的分支：\033[0m"
        select b in "release" "staging"; do
            case $b in
                release|staging) ST_BRANCH="$b"; break ;;
                *) echo -e "\033[31m无效选项，请重新选择。\033[0m" ;;
            esac
        done
    fi
    # ------------------------------------

    if [ -d "$ST_DIR/.git" ]; then
        echo -e "\033[33m检测到 SillyTavern 已存在，正在切换到分支 $ST_BRANCH 并拉取最新代码...\033[0m"
        (
            cd "$ST_DIR"
            git fetch origin
            git checkout "$ST_BRANCH"
            git pull origin "$ST_BRANCH"
        )
    else
        echo -e "\033[33m正在克隆 SillyTavern 分支 $ST_BRANCH...\033[0m"
        git clone --depth 1 --branch "$ST_BRANCH" "$target_repo_url" "$ST_DIR"
    fi

    (cd "$ST_DIR" && npm install) || err "npm依赖安装失败"
    echo -e "\033[32mSillyTavern 安装/更新完成（分支：$ST_BRANCH）\033[0m"
}

# 安装 geminicli2api
install_cli() {
    local deps=(python rust)
    local missing=()
    # 检查依赖是否缺失（rust 需同时检查 rustc 和 cargo）
    for dep in "${deps[@]}"; do
        if [ "$dep" = "rust" ]; then
            if ! command -v rustc &>/dev/null && ! command -v cargo &>/dev/null; then
                missing+=("rust")
            fi
        else
            if ! command -v "$dep" &>/dev/null; then
                missing+=("$dep")
            fi
        fi
    done

    # 依赖缺失时询问用户
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "\033[31m缺少 geminicli2api 依赖: ${missing[*]}\033[0m"
        read -rp $'\033[33m是否自动安装依赖? (y/n): \033[0m' confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "\033[33m用户取消依赖安装，返回主菜单\033[0m"
            return 1
        fi

        # 自动安装依赖
        echo -e "\033[36m开始自动安装 geminicli2api 依赖...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            pkg update -y && pkg install -y "${missing[*]}" || err "Termux 依赖安装失败"
        else
            [ "$EUID" -ne 0 ] && err "非 Termux 环境安装依赖需 root 权限，请使用 sudo 重新运行脚本"
            sudo apt update -y && sudo apt install -y "${missing[*]}" || err "Linux 依赖安装失败"
        fi
        echo -e "\033[32mgeminicli2api 依赖安装完成\033[0m"
    fi

    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo -e "\033[36m检测到 Termux 环境，正在更新软件源并安装必需的系统工具...\033[0m"
        pkg update && pkg upgrade -y
        pkg install clang libuv build-essential binutils pkg-config -y || err "Termux 基础工具安装失败"
    fi

    local target_repo_url="https://github.com/gzzhongqi/geminicli2api"

    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_repo_url="${CURRENT_PROXY}/${target_repo_url}"
    fi

    if [ -d "$CLI_DIR/.git" ]; then
        echo -e "\033[33m检测到 geminicli2api，正在更新...\033[0m"
        (cd "$CLI_DIR" && git pull) || err "git pull 失败"
    else
        echo -e "\033[33m正在克隆 geminicli2api: $target_repo_url\033[0m"
        git clone --depth 1 "$target_repo_url" "$CLI_DIR" || err "git clone 失败"
    fi

    cd "$CLI_DIR" || err "进入 geminicli2api 目录失败"

    if [ ! -d "venv" ]; then
        echo -e "\033[36m创建 Python 虚拟环境...\033[0m"
        python -m venv venv || err "创建虚拟环境失败"
    fi

    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo -e "\033[36m设置 Termux 编译环境变量...\033[0m"
        export CC=clang
        export CFLAGS="-I$PREFIX/include"
        export LDFLAGS="-L$PREFIX/lib"
    fi

    echo -e "\033[36m在虚拟环境中安装/更新 geminicli2api 依赖...\033[0m"
    ./venv/bin/pip install -r requirements.txt || err "依赖安装失败"

    echo -e "\033[32mgeminicli2api 安装/更新完成\033[0m"
    read -rsp $'\n按任意键返回主菜单...'
    refresh_version_cache
}

# 更新随行终端脚本
install_script() {
    local repo_name="404nyaFound/st-cr-ins.sh"
    local target_url="https://github.com/${repo_name}/releases/latest/download/install.sh"

    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_url="${CURRENT_PROXY}/${target_url}"
    fi

    echo -e "\033[36m检查更新随行终端，下载最新脚本: $target_url\033[0m"
    curl -fL "$target_url" -o "$0.new" || err "下载失败"
    mv "$0.new" "$0"
    chmod +x "$0"
    echo -e "\033[32m随行终端 更新完成，请重新运行脚本\033[0m"
    refresh_version_cache
    exit 0
}

# 启动 geminicli2api
run_cli() {
    if is_cli_running; then
        echo -e "\033[33mCLI 反代已在运行\033[0m"
        return 0
    fi

    local python_executable="$CLI_DIR/venv/bin/python"
    if [ ! -f "$python_executable" ]; then
        echo -e "\033[31m错误: 未找到虚拟环境中的 Python 执行文件。\033[0m"
        echo -e "\033[33m请先执行选项 '10' 安装/更新 geminicli2api。\033[0m"
        return 1
    fi

    echo -e "\033[36m启动 CLI 反代 (按 Ctrl+C 停止)...\033[0m"
    cd "$CLI_DIR" || err "进入 geminicli2api 目录失败"

    echo -e "\033[32mCLI 反代已启动 (默认: http://127.0.0.1:8888 密码: 123456)\033[0m"
    exec "$python_executable" run.py
}

# 编辑 ClewdR 配置文件
edit_config() {
    if [ ! -f "$CONFIG" ]; then
        if [ ! -x "$CLEWDR_DIR/clewdr" ]; then
            echo -e "\033[31m错误: ClewdR 未安装\033[0m"
            echo -e "\033[33m请先执行选项 '2' 安装 ClewdR\033[0m"
            return 1
        fi
        echo -e "\033[33m配置文件不存在，尝试生成默认配置...\033[0m"
        "$CLEWDR_DIR/clewdr" &
        local clewdr_pid=$!
        echo -n "等待配置文件生成"
        for _ in {1..10}; do
            if [ -f "$CONFIG" ]; then
                echo -e "\n\033[32m配置文件已生成\033[0m"
                break
            fi
            echo -n "."
            sleep 1
        done
        kill "$clewdr_pid" &>/dev/null || true
        if [ ! -f "$CONFIG" ]; then
            echo -e "\033[31m生成配置文件失败，请手动运行 ClewdR\033[0m"
            return 1
        fi
    fi
    if command -v vim &>/dev/null; then
        vim "$CONFIG"
    else
        nano "$CONFIG"
    fi
}

# 设置公网 IP
set_public_ip() {
    sed -i 's/127\.0\.0\.1/0.0.0.0/' "$CONFIG"
    echo -e "\033[32m已开放公网访问\033[0m"
}

# 修改监听端口
set_port() {
    read -rp "请输入新端口[1-65535]: " port
    if [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port < 65536)); then
        if grep -qE '^(#?\s*port\s*=)' "$CONFIG"; then
            sed -i -E "s/^(#?\s*port\s*=).*/port = $port/" "$CONFIG"
        else
            echo "port = $port" >> "$CONFIG"
        fi
        echo -e "\033[32m端口已修改为 $port\033[0m"
    else
        err "无效端口"
    fi
}

# 创建 systemd 服务
create_service() {
    [ "$EUID" -ne 0 ] && err "需要 root 权限"
    cat > "$SERVICE" <<EOF
[Unit]
Description=ClewdR Service
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=$CLEWDR_DIR
ExecStart=$CLEWDR_DIR/clewdr
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo -e "\033[32m服务已创建，可用 systemctl 管理\033[0m"
}

# 安装 OpenSSH
install_ssh() {
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo -e "\033[36m安装 OpenSSH (Termux)...\033[0m"
        pkg install -y openssh
    else
        [ "$EUID" -ne 0 ] && err "需要 root 权限，请使用包管理器安装 openssh-server"
        echo -e "\033[36m安装 OpenSSH...\033[0m"
        if command -v apt-get &>/dev/null; then
            apt-get install -y openssh-server
        elif command -v dnf &>/dev/null; then
            dnf install -y openssh-server
        elif command -v pacman &>/dev/null; then
            pacman -S --noconfirm openssh
        else
            err "无法识别包管理器，请手动安装 openssh-server"
        fi
    fi
    echo -e "\033[32mSSH 服务端已安装\033[0m"
}

# 启动 SSH 服务
start_ssh_server() {
    if is_ssh_running; then
        echo -e "\033[33mSSH 服务已在运行\033[0m"
        return 0
    fi
    echo -e "\033[36m启动 SSH 服务...\033[0m"
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        expect << EOF
spawn passwd
expect {
  "New password:" {
    send "$SSH_PASS\r"
    expect "Retype new password:"
    send "$SSH_PASS\r"
    send "\r"
  }
  timeout { exit 1 }
  eof {}
}
EOF
        echo -e "\033[36mTermux 密码设置为: $SSH_PASS\033[0m"
        echo -e "\033[33mTermux SSH 登录信息：\033[0m"
        echo -e " 用户名: \033[32m$SSH_USER\033[0m"
        echo -e " 密码: \033[32m$SSH_PASS\033[0m"
        echo -e " 端口: \033[32m8022\033[0m"
        sshd
    else
        local ssh_service
        ssh_service=$(get_ssh_service_name)
        systemctl start "$ssh_service"
    fi
    echo -e "\033[32mSSH 服务已启动\033[0m"
}

# 停止 SSH 服务
stop_ssh_server() {
    if ! is_ssh_running; then
        echo -e "\033[33mSSH 服务未运行\033[0m"
        return 0
    fi
    echo -e "\033[36m停止 SSH 服务...\033[0m"
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        pkill sshd || true
    else
        local ssh_service
        ssh_service=$(get_ssh_service_name)
        systemctl stop "$ssh_service"
    fi
    sleep 1
    if is_ssh_running; then
        echo -e "\033[31m停止 SSH 服务失败\033[0m"
    else
        echo -e "\033[32mSSH 服务已停止\033[0m"
    fi
}

# 切换 SSH 自启动
toggle_ssh_autostart() {
    if [[ "$PREFIX" != *"/com.termux"* ]] && [ "$EUID" -ne 0 ]; then
        err "需要 root 权限管理 SSH 自启动"
    fi
    if is_ssh_autostart_enabled; then
        echo -e "\033[36m禁用 SSH 自启动...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            SSH_AUTOSTART="false"
        else
            local ssh_service
            ssh_service=$(get_ssh_service_name)
            systemctl disable "$ssh_service"
        fi
        save_settings
        echo -e "\033[32mSSH 自启动已禁用\033[0m"
    else
        echo -e "\033[36m启用 SSH 自启动...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            SSH_AUTOSTART="true"
            echo -e "\033[33mTermux SSH 将在下次运行脚本时自动启动\033[0m"
        else
            local ssh_service
            ssh_service=$(get_ssh_service_name)
            systemctl enable "$ssh_service"
        fi
        save_settings
        echo -e "\033[32mSSH 自启动已启用\033[0m"
    fi
}

# 启用脚本自启动
enable_autostart() {
    local marker="# install_sh_autostart"
    # .bashrc所有内容
    > "$HOME/.bashrc"
    # 添加自启动配置
    echo -e "\n$marker\n# 随行终端自启动\ncd \"$DIR\" && bash \"$0\"\n# install_sh_autostart_end\n" >> "$HOME/.bashrc"
    echo -e "\033[32m已清空.bashrc并启用脚本自启动\033[0m"
}

# 禁用脚本自启动
disable_autostart() {
    local marker_start="# install_sh_autostart"
    local marker_end="# install_sh_autostart_end"
    # 清空.bashrc所有内容
    > "$HOME/.bashrc"
    echo -e "\033[32m已清空.bashrc并禁用脚本自启动\033[0m"
}

# 系统设置菜单
settings_menu() {
    while true; do
        clear
        local proxy_status autostart_status ssh_status ssh_autostart_status ssh_installed_status
        [ "$USE_PROXY" = true ] && proxy_status="\033[32m[已开启]\033[0m" || proxy_status="\033[90m[已关闭]\033[0m"
        is_autostart_enabled && autostart_status="\033[32m[已启用]\033[0m" || autostart_status="\033[90m[已关闭]\033[0m"
        is_ssh_running && ssh_status="\033[32m[运行中]\033[0m" || ssh_status="\033[90m[已停止]\033[0m"
        is_ssh_autostart_enabled && ssh_autostart_status="\033[32m[已启用]\033[0m" || ssh_autostart_status="\033[90m[已关闭]\033[0m"
        command -v sshd &>/dev/null && ssh_installed_status="\033[32m[已安装]\033[0m" || ssh_installed_status="\033[90m[未安装]\033[0m"

        echo -e "\033[36m============================================\033[0m"
        echo -e "\033[97m                  系统设置                  \033[0m"
        echo -e "\033[36m============================================\033[0m"
        echo -e "\033[34m[代理设置]\033[0m"
        echo -e "  \033[97m状态: $proxy_status  |  地址: \033[33m$CURRENT_PROXY\033[0m"
        echo -e "  \033[32m1)\033[0m [切换] 代理"
        echo -e "  \033[32m2)\033[0m 自定义代理地址"
        echo -e "  \033[32m3)\033[0m 重置默认代理"
        echo ""
        echo -e "\033[34m[脚本自启动]\033[0m"
        echo -e "  \033[32m4)\033[0m [切换] 自启动 $autostart_status"
        echo ""
        echo -e "\033[34m[SSH 服务]\033[0m"
        echo -e "  \033[32m5)\033[0m 安装 OpenSSH $ssh_installed_status"
        echo -e "  \033[32m6)\033[0m [切换] SSH 服务 $ssh_status"
        echo -e "  \033[32m7)\033[0m [切换] SSH 自启 $ssh_autostart_status"
        echo ""
        echo -e "\033[34m[更新]\033[0m"
        echo -e "  \033[32m8)\033[0m 强制更新检查"
        echo ""
        echo -e "  \033[31m0)\033[0m 返回主菜单"
        echo -e "\033[36m============================================\033[0m"
        read -rp "请选择 [0-8]: " opt

        case "$opt" in
            1)
                [ "$USE_PROXY" = true ] && USE_PROXY="false" || USE_PROXY="true"
                save_settings
                [ "$USE_PROXY" = true ] && echo -e "\033[32m代理已开启\033[0m" || echo -e "\033[33m代理已关闭\033[0m"
                ;;
            2)
                read -rp "请输入新代理地址 (如 https://ghproxy.com): " new_proxy
                if [[ -n "$new_proxy" ]]; then CURRENT_PROXY="$new_proxy"; USE_PROXY="true"; save_settings; echo -e "\033[32m代理更新为: $CURRENT_PROXY\033[0m"; else echo -e "\033[31m输入为空，未更改\033[0m"; fi
                ;;
            3)
                CURRENT_PROXY="$DEFAULT_PROXY"; USE_PROXY="true"; save_settings; echo -e "\033[32m代理重置为: $DEFAULT_PROXY\033[0m"
                ;;
            4)
                if is_autostart_enabled; then disable_autostart; else enable_autostart; fi
                ;;
            5)
                install_ssh
                ;;
            6)
                if ! command -v sshd &>/dev/null; then err "请先安装 OpenSSH (选项 5)"; fi
                if [[ "$PREFIX" != *"/com.termux"* ]] && [ "$EUID" -ne 0 ]; then err "需要 root 权限启停 SSH"; fi
                if is_ssh_running; then stop_ssh_server; else start_ssh_server; fi
                ;;
            7)
                if ! command -v sshd &>/dev/null; then err "请先安装 OpenSSH (选项 5)"; fi
                toggle_ssh_autostart
                ;;
            8)
                LAST_VERSION_CHECK="0"
                save_settings
                echo -e "\033[32m版本缓存已清除，返回主菜单后将开始检查更新。\033[0m"
                sleep 1
                break
                ;;
            0)
                break
                ;;
            *)
                echo -e "\033[31m无效选项\033[0m"
                ;;
        esac
        read -rsp $'\n按任意键继续...'
    done
}

# 感谢名单页面
show_thanks_menu() {
    clear
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[97m                   感谢支持                   \033[0m"
    echo -e "\033[36m==============================================\033[0m"
    echo ""
    echo -e "\033[34m[依赖项目]\033[0m"
    echo -e "  \033[97mClewdR\033[0m"
    echo -e "  \033[90mhttps://github.com/Xerxes-2/clewdr\033[0m"
    echo ""
    echo -e "  \033[97mSillyTavern\033[0m"
    echo -e "  \033[90mhttps://github.com/SillyTavern/SillyTavern\033[0m"
    echo ""
    echo -e "  \033[97mgeminicli2api\033[0m"
    echo -e "  \033[90mhttps://github.com/gzzhongqi/geminicli2api\033[0m"
    echo ""
    echo -e "\033[34m[开发者]\033[0m"
    echo -e "  \033[97mrzline\033[0m"
    echo -e "  \033[90m脚本原始作者\033[0m"
    echo ""
    echo -e "  \033[97m404nyaFound\033[0m"
    echo -e "  \033[90m脚本改进与维护\033[0m"
    echo ""
    echo -e "\033[34m[结语]\033[0m"
    echo -e "  \033[97m感谢所有支持与使用此脚本的用户\033[0m"
    echo -e "  \033[90m欢迎来旅程玩~\033[0m"
    echo ""
    echo -e "  \033[97m旅程 ΟΡΙΖΟΝΤΑΣ\033[0m"
    echo -e "  \033[90mAI 开源与技术交流社区\033[0m"
    echo -e "  \033[90mhttps://discord.gg/elysianhorizon\033[0m"
    echo ""
    echo -e "  \033[31m0)\033[0m 返回主菜单"
    echo -e "\033[36m==============================================\033[0m"
    read -rsp $'\n按任意键返回主菜单...'
}

# 主菜单 UI
draw_main_menu() {
    local CLEWDR_VER="$1" ST_VER="$2" CLI_VER="$3" SCRIPT_VER="$4"
    local CLEWDR_LATEST_MSG="$5" ST_LATEST_MSG="$6" CLI_LATEST_MSG="$7" SCRIPT_LATEST_MSG="$8"
    local clewdr_is_up="$9" st_is_up="${10}" ssh_is_up="${11}" cli_is_up="${12}"

    clear
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[97m                  随行终端                   \033[0m"
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[90m随行终端 版本:        \033[32m$SCRIPT_VER\033[0m \033[90m→\033[0m \033[33m$SCRIPT_LATEST_MSG\033[0m"
    echo -e "\033[90mClewdR 版本:          \033[32m$CLEWDR_VER\033[0m \033[90m→\033[0m \033[33m$CLEWDR_LATEST_MSG\033[0m"
    echo -e "\033[90mSillyTavern 版本:     \033[32m$ST_VER\033[0m \033[90m→\033[0m \033[33m$ST_LATEST_MSG\033[0m"
    echo -e "\033[90mGeminicli2api 版本:   \033[32m$CLI_VER\033[0m \033[90m→\033[0m \033[33m$CLI_LATEST_MSG\033[0m"
    echo -e "\033[0m检查更新说明\033[0m"
    echo -e "\033[90m每72H检查更新&刷新缓存，系统设置可强制刷新\033[0m"
    echo -e "\033[90m如获取失败或卡在获取中，可关闭梯子重启\033[0m"
    if [ "$clewdr_is_up" = true ] || [ "$st_is_up" = true ] || [ "$ssh_is_up" = true ] || [ "$cli_is_up" = true ]; then
        echo -e "\033[36m---------------- 服务运行状态 ----------------\033[0m"
        [ "$clewdr_is_up" = true ] && echo -e "  \033[97mClewdR      \033[32m[运行中]\033[0m"
        [ "$st_is_up" = true ] && echo -e "  \033[97mSillyTavern \033[32m[运行中]\033[0m"
        [ "$cli_is_up" = true ] && echo -e "  \033[97mGeminicli2api \033[32m[运行中]\033[0m"
        [ "$ssh_is_up" = true ] && echo -e "  \033[97mSSH 服务    \033[32m[运行中]\033[0m"
    fi

    echo -e "\033[36m----------------------------------------------\033[0m"
    echo -e "\033[34m[ClewdR 管理]\033[0m"
    echo -e "  \033[32m1)\033[0m 安装/更新 ClewdR"
    echo -e "  \033[32m2)\033[0m 启动 ClewdR"
    echo -e "  \033[32m3)\033[0m 编辑配置文件"
    echo -e "  \033[32m4)\033[0m 开放公网 IP"
    echo -e "  \033[32m5)\033[0m 修改监听端口"
    echo -e "  \033[32m6)\033[0m 创建 systemd 服务"
    echo ""
    echo -e "\033[34m[SillyTavern 管理]\033[0m"
    echo -e "  \033[32m7)\033[0m 安装/更新 SillyTavern"
    echo -e "  \033[32m8)\033[0m 启动 SillyTavern"
    echo ""
    echo -e "\033[34m[Geminicli2api 管理]\033[0m"
    echo -e "  \033[32m9)\033[0m 安装/更新 Geminicli2api"
    echo -e "  \033[32m10)\033[0m 启动 Geminicli2api"
    echo ""
    echo -e "\033[34m[其他]\033[0m"
    echo -e "  \033[32m11)\033[0m 重装/更新随行终端"
    echo -e "  \033[32m12)\033[0m 系统设置"
    echo -e "  \033[32m13)\033[0m 感谢支持"
    echo ""
    echo -e "  \033[31m0)\033[0m 退出"
    echo -e "\033[36m==============================================\033[0m"
}

# 主菜单逻辑
main_menu() {
    # 定义退出标志
    local exit_flag=false
    # 外部循环，用于在强制刷新后重新执行版本检查
    while true; do
        if [ "$exit_flag" = true ]; then
            echo -e "\033[33m下次再见，晚安~\033[0m"
            exit 0
        fi
        local last_check=${LAST_VERSION_CHECK:-0}
        local current_time
        current_time=$(date +%s)
        
        local CLEWDR_LATEST_MSG ST_LATEST_MSG CLI_LATEST_MSG SCRIPT_LATEST_MSG
        local all_fetched=false

        # 如果缓存有效（72小时内），则从变量读取
        if [ "$last_check" -ne 0 ] && [ $((current_time - last_check)) -lt 259200 ]; then
            SCRIPT_LATEST_MSG="$LATEST_SCRIPT_VER"
            CLEWDR_LATEST_MSG="$LATEST_CLEWDR_VER"
            ST_LATEST_MSG="$LATEST_ST_VER"
            CLI_LATEST_MSG="$LATEST_CLI_VER"
            all_fetched=true
        else
            # 缓存过时或不存在，执行新的版本检查
            TMP_CLEWDR_VER_FILE=$(mktemp)
            TMP_ST_VER_FILE=$(mktemp)
            TMP_CLI_VER_FILE=$(mktemp)
            TMP_SCRIPT_VER_FILE=$(mktemp)

            (get_latest_ver "404nyaFound/st-cr-ins.sh" release > "$TMP_SCRIPT_VER_FILE") &
            (get_latest_ver "Xerxes-2/clewdr" release > "$TMP_CLEWDR_VER_FILE") &
            (get_latest_ver "SillyTavern/SillyTavern" release > "$TMP_ST_VER_FILE") &
            (get_latest_ver "gzzhongqi/geminicli2api" commit > "$TMP_CLI_VER_FILE") &

            CLEWDR_LATEST_MSG="获取中..."
            ST_LATEST_MSG="获取中..."
            CLI_LATEST_MSG="获取中..."
            SCRIPT_LATEST_MSG="获取中..."
            local clewdr_fetched=false st_fetched=false cli_fetched=false script_fetched=false
        fi

        # 内部循环，处理用户输入和菜单显示
        while true; do
            if [ "$all_fetched" = false ]; then
                if [ "$script_fetched" = false ] && [ -s "$TMP_SCRIPT_VER_FILE" ]; then
                    SCRIPT_LATEST_MSG=$(<"$TMP_SCRIPT_VER_FILE")
                    [ -z "$SCRIPT_LATEST_MSG" ] && SCRIPT_LATEST_MSG="获取失败"
                    script_fetched=true
                fi
                if [ "$clewdr_fetched" = false ] && [ -s "$TMP_CLEWDR_VER_FILE" ]; then
                    CLEWDR_LATEST_MSG=$(<"$TMP_CLEWDR_VER_FILE")
                    [ -z "$CLEWDR_LATEST_MSG" ] && CLEWDR_LATEST_MSG="获取失败"
                    clewdr_fetched=true
                fi
                if [ "$st_fetched" = false ] && [ -s "$TMP_ST_VER_FILE" ]; then
                    ST_LATEST_MSG=$(<"$TMP_ST_VER_FILE")
                    [ -z "$ST_LATEST_MSG" ] && ST_LATEST_MSG="获取失败"
                    st_fetched=true
                fi
                if [ "$cli_fetched" = false ] && [ -s "$TMP_CLI_VER_FILE" ]; then
                    CLI_LATEST_MSG=$(<"$TMP_CLI_VER_FILE")
                    [ -z "$CLI_LATEST_MSG" ] && CLI_LATEST_MSG="获取失败"
                    cli_fetched=true
                fi

                if [ "$clewdr_fetched" = true ] && [ "$st_fetched" = true ] && [ "$cli_fetched" = true ] && [ "$script_fetched" = true ]; then
                    # 所有版本信息获取完毕，更新全局变量并保存
                    LAST_VERSION_CHECK="$current_time"
                    LATEST_SCRIPT_VER="$SCRIPT_LATEST_MSG"
                    LATEST_CLEWDR_VER="$CLEWDR_LATEST_MSG"
                    LATEST_ST_VER="$ST_LATEST_MSG"
                    LATEST_CLI_VER="$CLI_LATEST_MSG"
                    save_settings
                    all_fetched=true
                fi
            fi

            local CLEWDR_VER ST_VER CLI_VER SCRIPT_VER
            CLEWDR_VER=$(get_clewdr_ver)
            ST_VER=$(get_st_ver)
            CLI_VER=$(get_cli_ver)
            SCRIPT_VER=$(get_script_ver)

            local clewdr_is_up st_is_up ssh_is_up cli_is_up
            clewdr_is_up=false; is_clewdr_running && clewdr_is_up=true
            st_is_up=false; is_st_running && st_is_up=true
            ssh_is_up=false; is_ssh_running && ssh_is_up=true
            cli_is_up=false; is_cli_running && cli_is_up=true

            draw_main_menu "$CLEWDR_VER" "$ST_VER" "$CLI_VER" "$SCRIPT_VER" "$CLEWDR_LATEST_MSG" "$ST_LATEST_MSG" "$CLI_LATEST_MSG" "$SCRIPT_LATEST_MSG" \
                           "$clewdr_is_up" "$st_is_up" "$ssh_is_up" "$cli_is_up"

            if [ "$all_fetched" = false ]; then
                echo -e "正在获取版本信息..."
                sleep 0.25
                continue
            fi

            read -rp "请选择 [0-13]: " opt
            
            case "$opt" in
                1) check_deps; install_clewdr ;;
                2) if is_clewdr_running; then echo -e "\033[33mClewdR 已在运行\033[0m"; else echo -e "\033]0;ClewdR\a"; "$CLEWDR_DIR/clewdr"; fi ;;
                3) edit_config ;;
                4) set_public_ip ;;
                5) set_port ;;
                6) create_service ;;
                7) check_deps; install_st ;;
                8) if is_st_running; then echo -e "\033[33mSillyTavern 已在运行\033[0m"; else (cd "$ST_DIR" && node --max-old-space-size=4096 server.js); fi ;;
                9) install_cli ;;
                10) if is_cli_running; then echo -e "\033[33mGeminicli2api 已在运行\033[0m"; else echo -e "\033]0;Geminicli2api\a"; run_cli; fi ;;
                11) check_deps; install_script ;;
                12) 
                    settings_menu
                    # 从设置菜单返回后，重新加载配置以防有变
                    load_settings
                    # 如果用户在设置中强制刷新了版本检查（LAST_VERSION_CHECK被设为0）
                    # 则跳出内层循环，让外层循环重新开始，触发版本检查
                    if [ "${LAST_VERSION_CHECK:-0}" = "0" ]; then
                        break
                    fi
                    ;;
                13) show_thanks_menu ;;
                0) 
                    exit_flag=true 
                    break ;;
                *) echo -e "\033[31m无效选项\033[0m" ;;
            esac
        done
    done
}

# --- 主入口 ---

# 首次加载配置，并根据白名单清理
load_settings

if [[ "$PREFIX" == *"/com.termux"* ]] && [ "$SSH_AUTOSTART" = true ] && ! is_ssh_running; then
    echo -e "\033[36m检测到 SSH 自启动，启动服务...\033[0m"
    sshd
    sleep 1
fi

case "${1:-}" in
    -h) echo "用法: $0 [-h 帮助|-ic 安装clewdr|-is 安装酒馆|-sc 启动clewdr|-ss 启动酒馆]" && exit 0 ;;
    -ic) check_deps; install_clewdr ;;
    -is) check_deps; install_st ;;
    -sc) "$CLEWDR_DIR/clewdr" ;;
    -ss) (cd "$ST_DIR"; node --max-old-space-size=4096 server.js) ;;
    *) main_menu ;;
esac
