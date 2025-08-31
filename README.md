# 「随行终端 ERALINK」
> あなたのそばにへ

<p align="center">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20Termux-blue.svg" alt="Platform">
  <img src="https://img.shields.io/badge/shell-Bash-lightgrey.svg" alt="Shell">
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License">
</p>

`ERALINK`，一位为使用者而生的终端脚本。

它的诞生，源于一个纯粹的愿望：将 `SillyTavern`, `ClewdR`, `gcli2api` 等强大工具的繁琐部署与管理流程，化繁为简。通过一个可扩展的模块化框架，为您提供贴心、可靠的一键部署体验。

本项目的成长，离不开原作者 `rzline` 的启发与指导，在此致以诚挚的感谢。

## ❖ 核心理念 (Concept)

ERALINK 的设计围绕四大核心理念构建：

*   **✦ 模块化架构 (Modular Architecture)**
    不再是臃肿的单体脚本，每个核心功能（如 SillyTavern 管理）都是一个独立的、可插拔的模块。这使得添加新功能或进行维护变得前所未有的简单。

*   **✦ 动态化菜单 (Dynamic Menu)**
    主菜单界面会根据您启用的模块动态生成，为您呈现一个清爽、个性化的操作面板。您可以随时在设置中“召唤”或“隐藏”特定模块，定制您的专属工作台。

*   **✦ 统一化管理 (Unified Management)**
    从依赖安装、版本检查、服务启停，到网络代理、SSH配置乃至最终的软件卸载，所有操作都被收纳于一个统一、可视化的管理界面中，告别散乱的命令。

*   **✦ 轻量化体验 (Lightweight Experience)**
    基于纯 Shell 构建，无需繁重的运行时环境。ERALINK 追求以最轻盈的姿态，为您提供最可靠的服务。

## ❖ 核心功能 (Features)

| 分类             | 具体能力                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| **模块安装与更新** | 一键安装/更新 `ClewdR`, `SillyTavern`, `gcli2api` 等模块，以及 `ERALINK` 框架自身。                   |
| **服务状态监控**   | 在主菜单实时展示所有模块的运行状态 (`[运行中]` 或 `[已停止]`)，让您对系统状况一目了然。              |
| **版本智能检查**   | 启动时异步检查各模块与框架的最新版本，并与本地版本对比展示。支持缓存机制与手动强制刷新。           |
| **框架管理**       | ✧ **模块显示管理**：在设置中自由选择要在主菜单显示的模块。<br>✧ **安全卸载**：提供完整的卸载管理器，可选择性移除任一模块、依赖、配置文件乃至 `ERALINK` 自身。<br>✧ **调试模式**：为开发者与高级用户提供详细的后台日志输出。 |
| **系统级配置**     | ✧ **SSH 管理**：安装、启停 `OpenSSH` 服务，并配置开机自启。<br>✧ **网络代理**：支持全局代理的开启/关闭、自定义地址与重置。<br>✧ **开机自启**：一键配置 `ERALINK` 脚本自身的开机自启动。 |

## ❖ 快速开始 (Installation)

**1. 一键安装**

```bash
apt update && apt install curl unzip git nodejs jq expect -y && pkg upgrade -y && curl -L -o install.sh.tmp -C - https://github.com/404nyaFound/eralink/releases/latest/download/install.sh && mv -f install.sh.tmp install.sh && chmod +x install.sh && ./install.sh || { echo "安装过程中出错"; rm -f install.sh.tmp; exit 1; }
```
安装成功后，请及时开启：系统设置-脚本自启动
手动启动指令：
```bash
cd eralink
bash core.sh
```

**2. 启动脚本**


```首次启动时，脚本将自动检查并提示安装所需的核心依赖 (`curl`, `git`, `jq` 等)。

## ❖ 使用指南 (How to Use)

启动后，您将看到一个清晰的功能菜单，主要分为两大区域：

*   **`[模块名] 管理`**
    这里是各个具体AI工具的管理入口，例如 `[SillyTavern 管理]`。您可以在这里对该模块执行安装、更新、启动、停止等专属操作。

*   **`[系统管理]`**
    这里是 `ERALINK` 框架的核心设置区，包含了对所有模块都有影响的全局功能：
    - **检查更新**: 手动触发一次所有模块的版本检查。
    - **重装/更新随行终端**: 更新 `ERALINK` 框架本身。
    - **系统设置**:
        - **代理设置**: 管理网络连接。
        - **模块管理**: **选择哪些模块显示在主菜单上**。
        - **SSH 服务**: 远程连接管理。
        - **卸载管理**: **安全、彻底地移除不再需要的组件**。
    - **感谢支持**: 查看项目贡献者与社区信息。

## ❖ 框架结构 (Structure)
```
eralink/
├── core.sh          # ❖ 主程序入口 (Main script)
├── conf/            # ❖ 配置文件存放目录 (Configuration files)
│   ├── menu.conf
│   └── settings.conf
└── modules/         # ❖ 所有功能模块的核心所在 (All modules reside here)
    ├── clewdr/
    ├── sillytavern/
    └── ...
```

## ❖ 致谢 (Acknowledgments)

`ERALINK` 的旅程，离不开以下项目与开发者的支持，向他们致以诚挚的感谢。

**依赖项目 (Dependencies):**
*   [SillyTavern](https://github.com/SillyTavern/SillyTavern)
*   [ClewdR](https://github.com/Xerxes-2/clewdr)
*   [gcli2api](https://github.com/su-kaka/gcli2api)

**开发者 (Developers):**
*   **rzline**: 原版脚本作者，为项目奠定了坚实的基础。
*   **404nyaFound**: `ERALINK` 框架重构与维护者。

**友情链接 (Community):**
*   **旅程 ΟΡΙΖΟΝΤΑΣ**: 一个充满创造与分享精神的 AI 开源社区 [Discord](https://discord.gg/elysianhorizon)
