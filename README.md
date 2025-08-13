# 随行终端
(酒馆+ClewdR一键脚本)

一个用于自动化安装、配置和管理 [ClewdR](https://github.com/Xerxes-2/clewdr) 和 [SillyTavern](https://github.com/SillyTavern/SillyTavern) 的 Shell 脚本。

支持 `Linux` (Debian/Ubuntu/Arch) 和 `Termux` 环境。

随行终端为rzline一键启动脚本的分支项目，在此感谢rzline的指导和帮助。

## 如何使用

#### 1. 安装依赖

**Debian / Ubuntu**
```bash
apt update && apt install -y curl unzip git nodejs npm jq expect
```

**Termux**
```bash
pkg update && pkg install -y curl unzip git nodejs nodejs-lts jq expect
```

#### 2. 运行脚本

把下面这行命令扔进你的终端就行。

**通用版**
```bash
curl -L "https://raw.githubusercontent.com/404nyaFound/st-cr-ins.sh/main/install.sh" -o i.sh && chmod +x i.sh && ./i.sh
```

**中国大陆特供版 (使用代理)**
```bash
curl -L "https://ghfast.top/https://raw.githubusercontent.com/404nyaFound/st-cr-ins.sh/main/install.sh" -o i.sh && chmod +x i.sh && ./i.sh
```

## 主要功能

- **安装与更新**: 一键安装或更新 ClewdR 和 SillyTavern。
- **服务管理**: 启动、停止 ClewdR 与 SillyTavern 进程。
- **配置修改**: 编辑配置、开放公网访问、修改端口。
- **SSH 管理**: 安装、启停、设置开机自启 SSH 服务。
- **代理设置**: 方便地切换网络代理以加速下载。
- **开机自启**: 可将脚本设为自启动。

## 致谢

- **项目**: [ClewdR](https://github.com/Xerxes-2/clewdr), [SillyTavern](https://github.com/SillyTavern/SillyTavern)
- **作者**: rzline (原作者), 404nyaFound (分支改进与维护)
- **社区**: 旅程 ΟΡΙΖΟΝΤΑΣ

## 更新日志

<details>
<summary>点击展开</summary>

### 25.8.14
- 由 `404nyaFound` 重构脚本。
- 新增 SSH 管理、自启动、代理设置、依赖检查等功能。
- 优化交互界面与操作逻辑。
</details>