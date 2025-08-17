# 随行终端
（SillyTavern + ClewdR + geminicli2api 一键管理脚本）

一个用于自动化安装、配置和管理 **ClewdR**、**SillyTavern** 与 **geminicli2api** 的 Shell 脚本，支持 `Linux`（Debian/Ubuntu/Arch 系）和 `Termux` 环境，提供全流程可视化操作与服务管理能力。

本脚本为 rzline 原始一键脚本的分支项目，感谢原作者的指导与支持。


## 核心特性
| 功能模块                | 具体能力                                                                 |
|-------------------------|--------------------------------------------------------------------------|
| **多工具集成管理**      | 一键安装/更新 ClewdR、SillyTavern、geminicli2api 及脚本本身               |
| **服务启停与监控**      | 实时显示各工具运行状态，支持启动、停止操作（含进程唯一性校验）             |
| **配置灵活调整**        | 编辑 ClewdR 配置文件、开放公网访问、修改监听端口、创建 systemd 服务        |
| **SSH 全流程管理**      | 安装 OpenSSH、启停 SSH 服务、切换 SSH 开机自启（适配 Termux 与常规 Linux）|
| **网络代理优化**        | 支持代理切换、自定义代理地址、重置默认代理 |
| **自启动配置**          | 一键启用/禁用脚本开机自启（基于 `.bashrc` 配置，操作前自动清空历史内容）  |
| **版本智能检查**        | 自动检测各工具最新版本（72小时缓存周期，支持手动强制刷新）                 |
| **依赖自动修复**        | 检测缺失依赖（如 curl、npm、python 等），支持一键自动安装                 |


## 环境要求
| 环境类型       | 支持系统/架构                                                                 |
|----------------|------------------------------------------------------------------------------|
| **常规 Linux** | Debian/Ubuntu 系、Arch 系；支持 x86_64、aarch64 架构                          |
| **移动终端**   | Termux（Android）；仅支持 aarch64 架构                                       |
| **权限要求**   | 非 Termux 环境安装依赖/管理 SSH 需 root 权限（建议通过 `sudo` 运行脚本）       |


## 快速开始
### 1. 一键安装&运行脚本
方式一（无代理）：
```bash
apt update && apt install curl unzip git nodejs jq expect -y && pkg upgrade -y && curl -L -o install.sh.tmp -C - https://github.com/404nyaFound/st-cr-ins.sh/releases/latest/download/install.sh && mv -f install.sh.tmp install.sh && chmod +x install.sh && ./install.sh || { echo "安装过程中出错"; rm -f install.sh.tmp; exit 1; }
```
方式二（代理）：
```bash
apt update && apt install curl unzip git nodejs jq expect -y && pkg upgrade -y && curl -L -o install.sh.tmp -C - https://ghfast.top/https://github.com/404nyaFound/st-cr-ins.sh/releases/latest/download/install.sh && mv -f install.sh.tmp install.sh && chmod +x install.sh && ./install.sh || { echo "安装过程中出错"; rm -f install.sh.tmp; exit 1; }
```

### 2. 命令行参数（快捷操作）
除交互菜单外，支持通过参数直接执行核心操作：
| 参数   | 功能描述                     |
|--------|------------------------------|
| `-h`   | 查看帮助信息                 |
| `-ic`  | 一键安装/更新 ClewdR         |
| `-is`  | 一键安装/更新 SillyTavern    |
| `-sc`  | 直接启动 ClewdR              |
| `-ss`  | 直接启动 SillyTavern（4GB内存限制） |


## 功能操作指南
### 主菜单核心选项（0-13）
| 选项 | 功能分类                | 操作描述                                                                 |
|------|-------------------------|--------------------------------------------------------------------------|
| 1    | ClewdR 管理             | 安装/更新 ClewdR（自动适配系统架构与 C 库）                               |
| 2    | ClewdR 管理             | 启动 ClewdR（已运行时提示，避免重复启动）                                 |
| 3    | ClewdR 管理             | 编辑 ClewdR 配置文件（优先用 vim，无则用 nano；未生成时自动触发生成）       |
| 4    | ClewdR 管理             | 开放 ClewdR 公网访问（将配置中 127.0.0.1 替换为 0.0.0.0）                  |
| 5    | ClewdR 管理             | 修改 ClewdR 监听端口（支持 1-65535 范围内自定义）                          |
| 6    | ClewdR 管理             | 创建 ClewdR systemd 服务（需 root 权限，支持 systemctl 管理）              |
| 7    | SillyTavern 管理        | 安装/更新 SillyTavern（已安装时执行 git pull 更新）                        |
| 8    | SillyTavern 管理        | 启动 SillyTavern（设置 4GB 内存限制，避免内存溢出）                        |
| 9    | geminicli2api 管理      | 安装/更新 geminicli2api（自动安装 python、rust 依赖，创建虚拟环境）        |
| 10   | geminicli2api 管理      | 启动 geminicli2api（默认地址：http://127.0.0.1:8888，密码：123456）        |
| 11   | 脚本自身管理            | 重装/更新当前随行终端脚本（覆盖原文件，更新后需重启脚本）                  |
| 12   | 系统设置                | 进入子菜单：代理切换、自启动配置、SSH 管理、强制版本检查                   |
| 13   | 致谢与社区              | 查看依赖项目、开发者信息及社区链接                                       |
| 0    | 退出                    | 退出脚本                                         |

### 系统设置子菜单（0-8）
进入主菜单「12. 系统设置」后，可配置以下功能：
- **代理设置**：切换代理开关、自定义代理地址、重置为默认代理
- **脚本自启动**：一键启用/禁用脚本开机自启（基于 `.bashrc`）
- **SSH 管理**：安装 OpenSSH、启停 SSH 服务、切换 SSH 自启
- **版本更新**：强制清除版本缓存，立即重新检查所有工具最新版本


## 关键说明
1. **geminicli2api 默认配置**：启动后默认监听 `127.0.0.1:8888`，默认密码 `123456`，需在对应工具中配置使用。
2. **Termux SSH 特殊说明**：Termux 环境下 SSH 默认端口 `8022`，默认用户名 `当前用户`，默认密码 `123456`（首次启动时自动设置）。
3. **版本检查机制**：默认每 72 小时自动刷新版本缓存，若获取失败或卡住，可关闭代理后重启脚本，或通过「系统设置-8」强制刷新。
4. **配置文件路径**：ClewdR 配置文件路径为 `脚本所在目录/clewdr/clewdr.toml`，脚本配置文件为 `脚本所在目录/.settings.conf`（仅保留白名单配置项）。


## 致谢
### 依赖项目
- [ClewdR](https://github.com/Xerxes-2/clewdr)
- [SillyTavern](https://github.com/SillyTavern/SillyTavern)
- [geminicli2api](https://github.com/gzzhongqi/geminicli2api)

### 开发者
- **rzline**：脚本原始作者，提供基础框架与指导
- **404nyaFound**：脚本分支改进与维护（新增 SSH/代理/自启动等功能）

### 友情链接
- **旅程 ΟΡΙΖΟΝΤΑΣ**：AI 开源与技术交流社区 [Discord 链接](https://discord.gg/elysianhorizon)
</details>