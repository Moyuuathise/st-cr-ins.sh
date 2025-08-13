#!/bin/bash

# ==============================================================================
# 项目名称: 随行终端
# 功能:     自动化安装、配置、管理 ClewdR 和 SillyTavern。
#           支持 Linux (Debian/Ubuntu/Arch based) 和 Termux 环境。
#           提供代理设置、服务管理、SSH管理、开机自启等便捷功能。
# 作者:     rzline (原始作者), 404nyaFound (改进与维护)
# 日期:     2025-08-14
# ==============================================================================

# --- 初始化设置 ---

# -e: 当任何命令以非零状态退出时，立即退出脚本。
# -u: 当尝试使用未声明的变量时，报错并退出。
# -o pipefail: 如果管道中的任何一个命令失败，则整个管道的退出状态为失败。
set -euo pipefail

# 设置内部字段分隔符为换行符和制表符，避免处理带空格的文件名时出错。
IFS=$'\n\t'

# --- 全局变量定义 ---

# 获取脚本文件所在的绝对目录
DIR=$(cd "$(dirname "$0")" && pwd)

# 定义相关目录和文件路径
CLEWDR_DIR="$DIR/clewdr"
CONFIG="$CLEWDR_DIR/clewdr.toml"
ST_DIR="$DIR/SillyTavern"
SERVICE="/etc/systemd/system/clewdr.service"
SETTINGS_FILE="$DIR/.settings.conf"
DEFAULT_PROXY="https://ghfast.top"

# SSH 相关设置
SSH_USER=$(whoami) # 使用当前用户名作为SSH登录名
SSH_PASS="123456"  # Termux环境下的默认SSH密码

# 临时文件路径，用于后台获取最新版本号
TMP_CLEWDR_VER_FILE=""
TMP_ST_VER_FILE=""

# --- 核心函数定义 ---

# @description: 脚本退出时执行的清理函数，确保临时文件被删除。
cleanup() {
    rm -f "$TMP_CLEWDR_VER_FILE" "$TMP_ST_VER_FILE"
}

# 设置一个陷阱，在脚本退出（EXIT）时自动调用 cleanup 函数
trap cleanup EXIT

# @description: 从 .settings.conf 文件加载设置，如果文件不存在则使用默认值。
load_settings() {
    if [ -f "$SETTINGS_FILE" ]; then
        source "$SETTINGS_FILE"
    fi
    # 使用参数扩展功能，如果变量未设置，则赋予其默认值
    USE_PROXY="${USE_PROXY:-true}"
    CURRENT_PROXY="${CURRENT_PROXY:-$DEFAULT_PROXY}"
    SSH_AUTOSTART="${SSH_AUTOSTART:-false}"
    save_settings
}

# @description: 将当前设置保存到 .settings.conf 文件。
save_settings() {
    echo "USE_PROXY=\"$USE_PROXY\"" > "$SETTINGS_FILE"
    echo "CURRENT_PROXY=\"$CURRENT_PROXY\"" >> "$SETTINGS_FILE"
    echo "SSH_AUTOSTART=\"$SSH_AUTOSTART\"" >> "$SETTINGS_FILE"
}

# @description: 打印红色错误信息并退出脚本。
# @param $1: 要显示的错误信息。
# @param $2: (可选) 退出码，默认为 1。
err() {
    echo -e "\033[31m错误:\033[0m $1" >&2
    exit "${2:-1}"
}

# @description: 检查脚本运行所需的核心依赖项。
check_deps() {
    # 列出所有必需的命令
    local deps=(curl unzip git npm node jq expect)
    local missing=()
    # 遍历检查每个依赖是否存在
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    # 如果有缺失的依赖，则提示用户安装
    if [ "${#missing[@]}" -gt 0 ]; then
        echo -e "\033[31m检测到缺少依赖：${missing[*]}\033[0m"
        echo -e "\033[33m请执行以下命令安装缺失依赖：\033[0m"
        # 根据是否为 Termux 环境提供不同的安装命令
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            echo "  pkg install -y ${missing[*]}"
        else
            echo "  sudo apt update && sudo apt install -y ${missing[*]}"
        fi
        err "依赖不足，安装完成后请重新运行脚本"
    fi
}

# @description: 检测系统架构和 C 库类型。
detect_arch_libc() {
    # 特殊处理 Termux 环境
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo "检测到 Termux 环境"
        ARCH="aarch64"
        LIBC="android"
        return 0
    fi

    # 检测 CPU 架构
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) err "不支持的架构：$(uname -m)" ;;
    esac

    # 默认 C 库为 musllinux (musl for linux)
    LIBC="musllinux"
    echo "检测到常规 Linux 环境"
}

# @description: 获取GitHub仓库最新release版本号。
#               优先通过API直连，失败则回退到网页解析（此方法遵循代理）。
# @param $1: 仓库名称，格式为 "user/repo"。
get_latest_ver() {
    local repo_name="$1"

    # 方法一: 尝试直连 API (不使用代理)
    local api_url="https://api.github.com/repos/$repo_name/releases/latest"
    local tag
    tag=$(curl -sL --connect-timeout 10 "$api_url" | jq -r .tag_name 2>/dev/null)

    if [[ -n "$tag" && "$tag" != "null" ]]; then
        echo "${tag#v}" # 移除 'v' 前缀并返回
        return 0
    fi

    # 方法二: 回退到解析网页 (遵循代理设置)
    local target_url="https://github.com/$repo_name/releases/latest"
    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_url="${CURRENT_PROXY}/${target_url}"
    fi
    
    local final_redirect_url
    final_redirect_url=$(curl -sL -o /dev/null --connect-timeout 10 -w "%{url_effective}" "$target_url")

    if [[ "$final_redirect_url" == *"github.com"* ]]; then
        local release_tag=$(basename "$final_redirect_url")
        if [ -n "$release_tag" ]; then
            echo "${release_tag#v}"
            return 0
        fi
    fi

    echo "获取失败"
    return 1
}

# @description: 获取本地 SillyTavern 的版本号。
get_st_ver() {
    if [ -f "$ST_DIR/package.json" ]; then
        jq -r .version "$ST_DIR/package.json"
    else
        echo "未安装"
    fi
}

# @description: 获取本地 ClewdR 的版本号。
get_clewdr_ver() {
    if [ -x "$CLEWDR_DIR/clewdr" ]; then
        # 执行 clewdr -V 并提取版本号
        "$CLEWDR_DIR/clewdr" -V 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+'
    else
        echo "未安装"
    fi
}

# @description: 检查 ClewdR 进程是否在运行。
is_clewdr_running() {
    pgrep -f "$CLEWDR_DIR/clewdr" >/dev/null
}

# @description: 检查 SillyTavern 进程是否在运行。
is_st_running() {
    local pids
    # 查找名为 "node server.js" 的进程
    pids=$(pgrep -f "node server.js")
    if [ -n "$pids" ]; then
        # 遍历所有找到的PID，检查其工作目录是否为SillyTavern的目录
        # 这是为了防止误判其他 node 应用
        for pid in $pids; do
            if [ -L "/proc/$pid/cwd" ] && [[ "$(readlink /proc/$pid/cwd)" == "$ST_DIR" ]]; then
                return 0 # 找到匹配进程，返回成功
            fi
        done
    fi
    return 1 # 未找到，返回失败
}

# @description: 检查 sshd 进程是否在运行。
is_ssh_running() {
    pgrep sshd >/dev/null
}

# @description: 检查本脚本的自启动项是否已添加到 .bashrc。
is_autostart_enabled() {
    grep -Fq "# clewdr_install_sh_autostart" "$HOME/.bashrc"
}

# @description: 获取 systemd 中 SSH 服务的确切名称（通常是 sshd 或 ssh）。
get_ssh_service_name() {
    if systemctl list-units --full -all | grep -q 'sshd.service'; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

# @description: 检查 SSH 服务是否设置为开机自启。
is_ssh_autostart_enabled() {
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        # Termux 下的自启是通过脚本内变量控制的
        [ "$SSH_AUTOSTART" = true ]
    else
        # Linux 下通过 systemctl 检查
        local ssh_service
        ssh_service=$(get_ssh_service_name)
        systemctl is-enabled "$ssh_service" &>/dev/null
    fi
}

# @description: 下载并安装最新版的 ClewdR。
install_clewdr() {
    detect_arch_libc
    local file="clewdr-${LIBC}-${ARCH}.zip"
    local target_url="https://github.com/Xerxes-2/clewdr/releases/latest/download/$file"

    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_url="${CURRENT_PROXY}/${target_url}"
    fi

    mkdir -p "$CLEWDR_DIR"
    echo -e "\033[36m开始下载 ClewdR: $target_url\033[0m"
    curl -fL "$target_url" -o "$CLEWDR_DIR/$file" || err "下载失败"
    unzip -oq "$CLEWDR_DIR/$file" -d "$CLEWDR_DIR" || err "解压失败"
    chmod +x "$CLEWDR_DIR/clewdr"
    rm -f "$CLEWDR_DIR/$file"
    echo -e "\033[32mClewdR 安装/更新完成（${ARCH}/${LIBC}）\033[0m"
}

# @description: 下载/更新并安装 SillyTavern。
install_st() {
    local target_repo_url="https://github.com/SillyTavern/SillyTavern"

    if [ "$USE_PROXY" = true ] && [ -n "$CURRENT_PROXY" ]; then
        target_repo_url="${CURRENT_PROXY}/${target_repo_url}"
    fi

    if [ -d "$ST_DIR/.git" ]; then
        echo -e "\033[33m检测到 SillyTavern 已存在，正在更新...\033[0m"
        (cd "$ST_DIR" && git pull)
    else
        echo -e "\033[33m正在克隆 SillyTavern: $target_repo_url\033[0m"
        git clone --depth 1 --branch release "$target_repo_url" "$ST_DIR"
    fi
    (cd "$ST_DIR" && npm install) || err "npm依赖安装失败"
    # [BUG修复] 修复了颜色代码，原为 \032m
    echo -e "\033[32mSillyTavern 安装完成\033[0m"
}

# @description: 编辑 ClewdR 配置文件，若文件不存在则尝试自动生成。
edit_config() {
    if [ ! -f "$CONFIG" ]; then
        if [ ! -x "$CLEWDR_DIR/clewdr" ]; then
            echo -e "\033[31m错误: ClewdR 程序不存在，无法生成默认配置。\033[0m"
            echo -e "\033[33m请先执行选项 '1' 安装 ClewdR。\033[0m"
            return 1
        fi
        
        # [BUG修复 & 优化] 使用循环检测代替固定时间的 sleep，更稳定可靠
        echo -e "\033[33m配置文件不存在，将尝试运行 ClewdR 生成默认配置...\033[0m"
        "$CLEWDR_DIR/clewdr" &
        local clewdr_pid=$!
        
        echo -n "正在等待配置文件生成"
        for _ in {1..10}; do
            if [ -f "$CONFIG" ]; then
                echo -e "\n\033[32m配置文件已生成。\033[0m"
                break
            fi
            echo -n "."
            sleep 1
        done
        
        # 无论是否成功生成，都停止后台的ClewdR进程
        kill "$clewdr_pid" &>/dev/null || true
        
        if [ ! -f "$CONFIG" ]; then
            echo -e "\n\033[31m错误：自动生成配置失败。请尝试手动运行一次 ClewdR。 \033[0m"
            return 1
        fi
    fi
    # 优先使用 vim，如果不存在则使用 nano
    if command -v vim &>/dev/null; then
        vim "$CONFIG"
    else
        nano "$CONFIG"
    fi
}

# @description: 修改 ClewdR 配置，监听 0.0.0.0 以允许公网访问。
set_public_ip() {
    sed -i 's/127\.0\.0\.1/0.0.0.0/' "$CONFIG"
    echo -e "\033[32m已开放公网访问\033[0m"
}

# @description: 修改 ClewdR 配置中的监听端口。
set_port() {
    read -rp "请输入新端口[1-65535]: " port
    if [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port < 65536)); then
        # 如果已存在 port 配置项（无论是否被注释），则替换它
        if grep -qE '^(#?\s*port\s*=)' "$CONFIG"; then
            sed -i -E "s/^(#?\s*port\s*=).*/port = $port/" "$CONFIG"
        else
            # 否则在文件末尾追加
            echo "port = $port" >> "$CONFIG"
        fi
        echo -e "\033[32m端口已修改为 $port\033[0m"
    else
        err "无效端口"
    fi
}

# @description: 创建 clewdr 的 systemd 服务文件（需要 root 权限）。
create_service() {
    [ "$EUID" -ne 0 ] && err "需root权限"
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
    echo -e "\033[32m服务已创建，可使用 systemctl 管理 clewdr 服务\033[0m"
}

# @description: 安装 OpenSSH 服务。
install_ssh() {
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        echo -e "\033[36m安装 OpenSSH (for Termux)...\033[0m"
        pkg install -y openssh
    else
        [ "$EUID" -ne 0 ] && err "需要root权限。请使用 'sudo apt install openssh-server' 或您发行版的包管理器来安装。"
        echo -e "\033[36m正在尝试为您的系统安装 OpenSSH...\033[0m"
        if command -v apt-get &>/dev/null; then
             apt-get install -y openssh-server
        elif command -v dnf &>/dev/null; then
             dnf install -y openssh-server
        elif command -v pacman &>/dev/null; then
             pacman -S --noconfirm openssh
        else
            err "无法确定包管理器。请手动安装 'openssh-server'。"
        fi
    fi
    echo -e "\033[32mSSH 服务端已安装。\033[0m"
}

# @description: 启动 SSH 服务。
start_ssh_server() {
    if is_ssh_running; then
        echo -e "\033[33mSSH 服务已经在运行中，无需重复启动。\033[0m"
        return 0
    fi
    
    echo -e "\033[36m启动 SSH 服务...\033[0m"
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        # [优化] expect 依赖已在 check_deps 中检查，此处无需重复安装
        # 使用 expect 脚本自动设置密码
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
        echo -e "\033[36mTermux 密码已设置为: $SSH_PASS\033[0m"
        echo -e "\033[33m请使用以下信息远程登录 Termux：\033[0m"
        echo -e " 用户名: \033[32m$SSH_USER\033[0m"
        echo -e " 密码:   \033[32m$SSH_PASS\033[0m"
        echo -e " 端口:   \033[32m8022\033[0m"
        sshd
    else
       local ssh_service
       ssh_service=$(get_ssh_service_name)
       systemctl start "$ssh_service"
    fi
    echo -e "\n\033[32mSSH 服务已启动！\033[0m"
}

# @description: 停止 SSH 服务。
stop_ssh_server() {
    if ! is_ssh_running; then
        echo -e "\033[33mSSH 服务未在运行。\033[0m"
        return 0
    fi
    echo -e "\033[36m正在停止 SSH 服务...\033[0m"
    if [[ "$PREFIX" == *"/com.termux"* ]]; then
        pkill sshd || true
    else
        local ssh_service
        ssh_service=$(get_ssh_service_name)
        systemctl stop "$ssh_service"
    fi
    sleep 1
    if is_ssh_running; then
        echo -e "\033[31m停止 SSH 服务失败。\033[0m"
    else
        echo -e "\033[32mSSH 服务已停止。\033[0m"
    fi
}

# @description: 切换 SSH 服务的开机自启状态。
toggle_ssh_autostart() {
    if [[ "$PREFIX" != *"/com.termux"* ]] && [ "$EUID" -ne 0 ]; then
        err "需要root权限来管理 SSH 服务自启动"
    fi

    if is_ssh_autostart_enabled; then
        echo -e "\033[36m正在禁用 SSH 服务自启动...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            SSH_AUTOSTART="false"
        else
            local ssh_service
            ssh_service=$(get_ssh_service_name)
            systemctl disable "$ssh_service"
        fi
        save_settings
        echo -e "\033[32mSSH 服务自启动已禁用。\033[0m"
    else
        echo -e "\033[36m正在启用 SSH 服务自启动...\033[0m"
        if [[ "$PREFIX" == *"/com.termux"* ]]; then
            SSH_AUTOSTART="true"
            echo -e "\033[33mTermux 的 SSH 服务将在下次运行本脚本时自动启动。\033[0m"
        else
            local ssh_service
            ssh_service=$(get_ssh_service_name)
            systemctl enable "$ssh_service"
        fi
        save_settings
        echo -e "\033[32mSSH 服务自启动已启用。\033[0m"
    fi
}

# @description: 将本脚本的启动命令添加到 ~/.bashrc 以实现开机（登录时）自启。
enable_autostart() {
    local marker="# clewdr_install_sh_autostart"
    if is_autostart_enabled; then
        echo -e "\033[33m脚本自启动已启用，无需重复设置。\033[0m"
    else
        # 追加启动命令到 .bashrc，并用标记包裹方便以后删除
        echo -e "\n$marker\n# 随行终端自启动脚本\ncd \"$DIR\" && bash \"$0\"\n# clewdr_install_sh_autostart_end\n" >> "$HOME/.bashrc"
        echo -e "\033[32m已添加自启动到 .bashrc，下次登录后将自动运行本脚本。\033[0m"
    fi
}

# @description: 从 ~/.bashrc 中移除本脚本的自启动项。
disable_autostart() {
    local marker_start="# clewdr_install_sh_autostart"
    local marker_end="# clewdr_install_sh_autostart_end"
    if is_autostart_enabled; then
        # 使用 sed 根据标记删除对应的行范围
        sed -i "/$marker_start/,/$marker_end/d" "$HOME/.bashrc"
        echo -e "\033[32m已移除脚本自启动设置。\033[0m"
    else
        echo -e "\033[33m未检测到自启动设置，无需移除。\033[0m"
    fi
}

# @description: 显示和处理系统设置菜单。
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
        echo -e "\033[97m                    系统设置                    \033[0m"
        echo -e "\033[36m============================================\033[0m"
        echo -e "\033[34m[代理设置]\033[0m"
        echo -e "  \033[97m状态: $proxy_status  |  地址: \033[33m$CURRENT_PROXY\033[0m"
        echo -e "  \033[32m1)\033[0m [切换] 代理"
        echo -e "  \033[32m2)\033[0m 自定义代理地址"
        echo -e "  \033[32m3)\033[0m 重置为默认代理"
        echo ""
        echo -e "\033[34m[脚本自启动管理]\033[0m"
        echo -e "  \033[32m4)\033[0m [切换] 自启动          $autostart_status"
        echo ""
        echo -e "\033[34m[SSH 服务管理]\033[0m"
        echo -e "  \033[32m5)\033[0m 安装 OpenSSH           $ssh_installed_status"
        echo -e "  \033[32m6)\033[0m [切换] SSH 服务        $ssh_status"
        echo -e "  \033[32m7)\033[0m [切换] SSH 自启        $ssh_autostart_status"
        echo ""
        echo -e "  \033[31m0)\033[0m 返回主菜单"
        echo -e "\033[36m============================================\033[0m"
        read -rp "请选择操作 [0-7]: " opt

        case "$opt" in
            1)
                [ "$USE_PROXY" = true ] && USE_PROXY="false" || USE_PROXY="true"
                save_settings 
                [ "$USE_PROXY" = true ] && echo -e "\033[32m代理已开启。\033[0m" || echo -e "\033[33m代理已关闭。\033[0m"
                ;;
            2)
                read -rp "请输入新的代理地址 (例如: https://ghproxy.com): " new_proxy
                if [[ -n "$new_proxy" ]]; then CURRENT_PROXY="$new_proxy"; USE_PROXY="true"; save_settings; echo -e "\033[32m代理已更新为: $CURRENT_PROXY 并已自动开启。\033[0m"; else echo -e "\033[31m输入为空，未作更改。\033[0m"; fi 
                ;;
            3)
                CURRENT_PROXY="$DEFAULT_PROXY"; USE_PROXY="true"; save_settings; echo -e "\033[32m代理已重置为默认地址: $DEFAULT_PROXY 并已自动开启。\033[0m" 
                ;;
            4)
                if is_autostart_enabled; then disable_autostart; else enable_autostart; fi
                ;;
            5)
                install_ssh
                ;;
            6)
                if ! command -v sshd &>/dev/null; then err "请先通过选项 5 安装 OpenSSH"; fi
                if [[ "$PREFIX" != *"/com.termux"* ]] && [ "$EUID" -ne 0 ]; then err "需要root权限来启停 SSH 服务"; fi
                if is_ssh_running; then stop_ssh_server; else start_ssh_server; fi
                ;;
            7)
                if ! command -v sshd &>/dev/null; then err "请先通过选项 5 安装 OpenSSH"; fi
                toggle_ssh_autostart
                ;;
            0)
                return 0 
                ;;
            *)
                echo -e "\033[31m无效选项\033[0m" 
                ;;
        esac
        read -n1 -rsp $'\n按任意键继续...'
    done
}

# @description: 显示感谢名单页面。
show_thanks_menu() {
    clear
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[97m                   感谢支持                   \033[0m"
    echo -e "\033[36m==============================================\033[0m"
    echo ""
    echo -e "\033[34m[项目]\033[0m"
    echo -e "  \033[97mClewdR\033[0m"
    echo -e "  \033[90mhttps://github.com/Xerxes-2/clewdr\033[0m"
    echo ""
    echo -e "  \033[97mSillyTavern\033[0m"
    echo -e "  \033[90mhttps://github.com/SillyTavern/SillyTavern\033[0m"
    echo ""
    echo -e "\033[34m[社区]\033[0m"
    echo -e "  \033[97m旅程 ΟΡΙΖΟΝΤΑΣ\033[0m"
    echo -e "  \033[90m关于AI的开源、共享、创作和技术交流社区"
    echo -e "  \033[90mhttps://discord.gg/elysianhorizon\033[0m"
    echo ""
    echo -e "\033[34m[开发者]\033[0m"
    echo -e "  \033[97mrzline\033[0m"
    echo -e "  \033[90m一键启动脚本的奠基者\033[0m"
    echo ""
    echo -e "  \033[97m404nyaFound\033[0m"
    echo -e "  \033[90m在rzline的基础上进行改进和维护\033[0m"
    echo ""
    echo -e "\033[36m==============================================\033[0m"
}

# @description: 绘制主菜单UI界面。
draw_main_menu() {
    local CLEWDR_VER="$1"
    local ST_VER="$2"
    local CLEWDR_LATEST_MSG="$3"
    local ST_LATEST_MSG="$4"
    local clewdr_is_up="$5"
    local st_is_up="$6"
    local ssh_is_up="$7"

    clear
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[97m                   随行终端                   \033[0m"
    echo -e "\033[36m==============================================\033[0m"
    echo -e "\033[90mClewdR 版本:      \033[32m$CLEWDR_VER\033[0m \033[90m→\033[0m \033[33m$CLEWDR_LATEST_MSG\033[0m"
    echo -e "\033[90mSillyTavern 版本: \033[32m$ST_VER\033[0m \033[90m→\033[0m \033[33m$ST_LATEST_MSG\033[0m"

    if [ "$clewdr_is_up" = true ] || [ "$st_is_up" = true ] || [ "$ssh_is_up" = true ]; then
        echo -e "\033[36m---------------- 服务运行状态 ----------------\033[0m"
        if [ "$clewdr_is_up" = true ]; then echo -e "  \033[97mClewdR      \033[32m[运行中]\033[0m"; fi
        if [ "$st_is_up" = true ]; then echo -e "  \033[97mSillyTavern \033[32m[运行中]\033[0m"; fi
        if [ "$ssh_is_up" = true ]; then echo -e "  \033[97mSSH 服务    \033[32m[运行中]\033[0m"; fi
    fi

    echo -e "\033[36m----------------------------------------------\033[0m"
    echo -e "\033[34m[ClewdR 管理]\033[0m"
    echo -e "  \033[32m1)\033[0m 安装/更新 ClewdR"
    echo -e "  \033[32m2)\033[0m 启动 ClewdR"
    echo -e "  \033[32m3)\033[0m 编辑配置文件"
    echo -e "  \033[32m4)\033[0m 开放公网IP"
    echo -e "  \033[32m5)\033[0m 修改监听端口"
    echo -e "  \033[32m6)\033[0m 创建 systemd 服务"
    echo ""
    echo -e "\033[34m[SillyTavern 管理]\033[0m"
    echo -e "  \033[32m7)\033[0m 安装/更新 SillyTavern"
    echo -e "  \033[32m8)\033[0m 启动 SillyTavern"
    echo ""
    echo -e "\033[34m[其他]\033[0m"
    echo -e "  \033[32m9)\033[0m 系统设置"
    echo -e "  \033[32m10)\033[0m 感谢支持"
    echo ""
    echo -e "  \033[31m0)\033[0m 退出"
    echo -e "\033[36m==============================================\033[0m"
}

# @description: 主菜单逻辑循环。
main_menu() {
    # 使用 mktemp 创建安全的临时文件
    TMP_CLEWDR_VER_FILE=$(mktemp)
    TMP_ST_VER_FILE=$(mktemp)

    # 在后台异步获取最新版本号，避免阻塞菜单显示
    (get_latest_ver "Xerxes-2/clewdr" > "$TMP_CLEWDR_VER_FILE") &
    (get_latest_ver "SillyTavern/SillyTavern" > "$TMP_ST_VER_FILE") &

    local CLEWDR_LATEST_MSG="获取中..."
    local ST_LATEST_MSG="获取中..."
    local clewdr_fetched=false
    local st_fetched=false
    local all_fetched=false
    local opt

    while true; do
        # 检查后台版本获取任务是否完成
        if [ "$all_fetched" = false ]; then
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
            if [ "$clewdr_fetched" = true ] && [ "$st_fetched" = true ]; then
                all_fetched=true
            fi
        fi

        # 获取本地版本和服务状态
        local CLEWDR_VER ST_VER
        CLEWDR_VER=$(get_clewdr_ver)
        ST_VER=$(get_st_ver)

        local clewdr_is_up st_is_up ssh_is_up
        clewdr_is_up=false; is_clewdr_running && clewdr_is_up=true
        st_is_up=false; is_st_running && st_is_up=true
        ssh_is_up=false; is_ssh_running && ssh_is_up=true

        # 绘制菜单
        draw_main_menu "$CLEWDR_VER" "$ST_VER" "$CLEWDR_LATEST_MSG" "$ST_LATEST_MSG" "$clewdr_is_up" "$st_is_up" "$ssh_is_up"

        # 如果版本信息还没获取完，则不接受输入
        if [ "$all_fetched" = false ]; then
            echo -e "正在获取最新版本信息，请稍候..."
            sleep 0.25
            continue
        fi
        
        read -rp "请选择操作 [0-10]: " opt
        
        # 处理用户输入
        if [ -n "$opt" ]; then
            case "$opt" in
                1) check_deps; install_clewdr ;;
                2) if is_clewdr_running; then echo -e "\033[33mClewdR 已经在运行中。\033[0m"; else echo -e "\033]0;ClewdR\a"; "$CLEWDR_DIR/clewdr"; fi ;;
                3) edit_config ;;
                4) set_public_ip ;;
                5) set_port ;;
                6) create_service ;;
                7) check_deps; install_st ;;
                8) if is_st_running; then echo -e "\033[33mSillyTavern 已经在运行中。\033[0m"; else (cd "$ST_DIR" && node server.js); fi ;;
                9) settings_menu
                   continue ;;
                10) show_thanks_menu ;;
                0) echo -e "\033[36m下次再见，晚安~\033[0m"; break ;;
                *) echo -e "\033[31m无效选项\033[0m" ;;
            esac
            read -n1 -rsp $'\n按任意键返回菜单...'
        fi
    done
}

# --- 脚本主入口 ---

# 1. 加载配置
load_settings

# 2. 如果是 Termux 环境且开启了 SSH 自启，则尝试启动 SSH 服务
if [[ "$PREFIX" == *"/com.termux"* ]] && [ "$SSH_AUTOSTART" = true ] && ! is_ssh_running; then
    echo -e "\033[36m检测到 SSH 自动启动已开启，正在后台启动 SSH 服务...\033[0m"
    sshd
    sleep 1
fi

# 3. 处理命令行参数或显示主菜单
case "${1:-}" in
    -h) echo "用法: $0 [-h 帮助|-ic 安装clewdr|-is 安装酒馆|-sc 启动clewdr|-ss 启动酒馆]" && exit 0 ;;
    -ic) check_deps; install_clewdr ;;
    -is) check_deps; install_st ;;
    -sc) "$CLEWDR_DIR/clewdr" ;;
    -ss) (cd "$ST_DIR"; node server.js) ;;
    *) main_menu ;;
esac