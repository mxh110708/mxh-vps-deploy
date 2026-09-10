# MXH VPS Deploy

面向个人 Debian VPS 的中文部署与运维工具，由 Windows 控制端统一管理部署计划、远端操作、私有归档和客户端配置。

支持新机部署、已有实例接入、协议管理、网络调优、维护恢复及实例退役。交互向导负责收集与确认，远端 Bash 模块负责执行，计划与状态文件用于继续任务和核对结果。

## 项目基准

- **兼容性**：明确支持范围，尊重已有实例的配置选择；遇到不兼容条件先提示，不隐式切换协议或接管防火墙。
- **稳定性**：关键变更使用快照、回滚保护和结果复验；区分已通过、用户跳过与尚未完成，不把服务启动当成完整验收。
- **易用性**：按任务组织中文菜单，支持返回、默认值与帮助；复杂参数和恢复限制放在具体操作提示及使用手册中。

这些是实现与审计基准，不代表所有环境和故障场景都已验证。离线测试、远端模拟和真实 VPS 验收各有边界。

## 快速开始

### 1. 准备环境

| 项目 | 支持范围或要求 |
|---|---|
| 控制端 | Windows 10/11，amd64 |
| PowerShell | 7.4 或更高版本，命令为 `pwsh.exe` |
| SSH 工具 | Windows OpenSSH Client：`ssh.exe`、`scp.exe`、`ssh-keygen.exe` |
| 目标 VPS | Debian 12/13，amd64，使用 systemd 和 apt |
| 初始登录 | 可用的 root SSH 登录方式：密码或已有 OpenSSH 私钥 |
| 客户端配置设计器 | Python 3.9+，以及项目固定的 YAML 依赖 |

使用客户端配置设计器前安装依赖：

```powershell
python -m pip install -r .\requirements-client-merge.txt
```

Debian 是远端目标环境，不是控制端运行平台。操作前请保留服务商控制台或其他恢复入口；服务商安全组需要自行放行。

### 2. 本地自检

在项目目录打开 PowerShell，运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
```

自检不连接 VPS，检查项目文件、脚本和离线测试；通过不等于真实服务器或代理连接已经验收。

### 3. 启动工具

双击 `Start-VPSDeploy.cmd`，或运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1
```

## 按任务选择入口

| 主菜单 | 适用场景 |
|---|---|
| **1. 部署新 VPS** | 建立 SSH 管理入口，部署协议、网络参数和防火墙 |
| **2. 继续未完成部署** | 继续已有计划，或在恢复点可验证时放弃并回滚 |
| **3. 接入已有 VPS（首次管理）** | 为尚无本工具计划的现有实例建立管理记录 |
| **4. 管理代理协议** | 安装、切换、启停、卸载协议，管理备用协议与备份 |
| **5. VPS 运维中心** | 健康审计、恢复、凭据轮换、SSH、防火墙、更新、Komari 和退役 |
| **6. 调整网络参数** | 独立调整网络参数，不切换协议或接管防火墙 |
| **7. 客户端配置（Clash / sing-box）** | 组合入口与落地节点，生成、校验并发布配置 |
| **8. 本地自检（不连接 VPS）** | 检查本地项目与离线测试 |
| **9. 退出** | 退出程序 |

“继续未完成部署”需要已有 `deployment-plan.json`，不是为已有 VPS 增加协议的入口。未纳管实例先选 **3**，已纳管实例通常选 **4** 或 **5**。

### 交互约定

- 主菜单用 `9` 退出；子菜单、向导和确认页用 `0` 返回。
- 如果字段允许数值 `0`，提示中会说明，改用 `/back` 返回。
- 直接回车采用显示的默认值；`clear` / `cls` 清屏，`help` / `h` / `?` 查看帮助。
- `b`、`back` 是普通输入，不是返回命令。
- 只有明确提示支持的字段才将 `!empty` 解释为清空默认值。
- 向导回退保留适用的非敏感输入；敏感值不回显，必要时需要重新填写。

## 功能与边界

### 部署与接入

新部署支持密码引导或复用服务商私钥。复用时默认建立实例规范副本，不修改源私钥或轮换服务器公钥；只有密码引导或明确选择时才生成新的管理密钥。

新部署创建 `admin` 并配置公钥登录。初始为低位 SSH 端口时迁移到随机高位主、救援端口；已有非特权高位端口时复用为主端口，再新增救援端口。

已有实例接入默认保留当前 SSH 认证策略、端口和防火墙，只识别标准路径中的受支持协议，不是任意第三方面板配置的迁移工具。

### 代理协议

| 协议 | 用途与特点 | 共存限制 |
|---|---|---|
| Xray VLESS + REALITY + Vision | 入口；外部目标或本机静态 HTTPS 目标 | 与 AnyTLS 可同时安装，只能启用一个 |
| sing-box AnyTLS + TLS + ECH | 入口；公共 CA 证书、DNS-01 与自动续期 | 与 Reality 共用 TCP 443 |
| sing-box Shadowsocks 2022 | 多用户落地；独立高位 TCP/UDP 端口 | 可与入口协议同时运行 |

外部 Reality 目标会检查 TCP、TLS 1.3、h2、证书及连接耗时。自动门槛未通过时，默认要求更换，也支持明确确认并记录原因后继续。

AnyTLS 和 Reality 本机 HTTPS 目标的准备步骤，见[证书与域名配置手册](docs/CLOUDFLARE-CERTBOT.zh-CN.md)。

### 网络与真实连接验收

- 新部署在审计确认的干净 VPS 上应用最小 nftables；Shadowsocks 按可信入口地址限制访问。
- 网络调优使用套餐标称带宽、远端内存和可选代表性 RTT，不运行公网测速，也不以虚拟网卡速率代替套餐带宽。
- Reality / AnyTLS 使用稳定版 Mihomo 和 sing-box，按地址族测试真实握手、HTTPS、出口 IP 与 UDP；Shadowsocks 支持自测及可信入口链式探测。
- 项目携带 Windows amd64 测试核心及校验值，解压到 `.cache/client-cores/`，不读取 Clash Verge 安装、PATH 中的代理核心或注册表。
- 核心不可用时可按提示重试、手动选择或明确跳过。本机 IPv6 验收路径不可用时，可选择受支持的外部验收路径或明确跳过。跳过记为 `SkippedByUser`，不算通过；非交互模式不能自动跳过。

### 运维与恢复

运维中心提供健康审计和配置漂移检查、代理凭据轮换、SSH 与防火墙维护、组件更新、Komari 管理及分级退役。

关键维护操作建立本地和远端备份，并使用远端回滚保护。中断后先进入“处理未完成的维护操作”，核对服务器状态并同步本地记录；不能把本地失败直接当成远端未执行。

| 操作 | 重要边界 |
|---|---|
| 只恢复配置 | 保留当前版本、服务启停和防火墙；协议集合、端口或证书设置不兼容时拒绝恢复。涉及正在运行的 nginx 时，检查后重新加载 |
| 完整恢复协议相关文件和设置 | 不是系统重装，不恢复旧 SSH 身份；备份的 SSH 端口与当前不同会拒绝加载历史防火墙，恢复后重新验证管理入口 |
| 更新代理服务 | 重启目标服务并核对运行进程使用的二进制，再做连接验收；停用备用协议须先启用或切换后再更新 |
| 选择更新版本 | 通常使用 `config/versions.json` 的固定资产，不等于官方最新版；Xray 还可保持计划版本或解析官方最新稳定版，并记录实际版本 |
| 审计已有 SSH 策略 | 尊重纳管时明确保留的认证策略，但关闭公钥认证仍视为严重异常 |
| 退役 | 分级清理受管组件，保留 SSH 和基础系统，不删除服务商实例 |

### 客户端方案工作台

从主菜单 **7 → 快速创建方案** 开始：添加节点、确认连接关系、生成候选，再查看摘要并发布。

- 从受管实例提取节点，或手动录入未纳管节点。
- 独立编辑节点、入口与落地连接关系、地区分组、排序和业务默认出口。
- 草稿使用当前 Windows 用户加密，保存在 `private/client-schemes`；不能直接跨账号解密，重开后需要重新校验。
- 生成候选不改正式配置；发布前校验两端核心、来源与目标指纹，并建立备份和恢复记录。
- 默认从通用模板生成；导入已有配置可保留高级 DNS、TUN 与规则，但不是任意字段的可视化编辑器。
- 正式配置必须是用户指定的独立权威文件，拒绝写入 Clash Verge AppData。双文件发布使用锁和阶段记录处理失败，不应视为跨文件的单次原子操作。

详见[方案工作台与事务恢复](docs/WORKBENCH-AND-RECOVERY.zh-CN.md)。

## 私有数据与权限

源码、通用模板和 Git 仓库不应包含实例真实 IP、端口、UUID、私钥、密码、Token 或完整个人配置。请单独保管实例归档，不要上传到公开仓库。

```text
<实例归档根目录>\<服务商>\<实例>\MXH-VPS-Deploy\
├─ deployment-plan.json             部署计划
├─ deployment-state.json            执行状态
├─ deployment-secrets.private.json  私有凭据
├─ deployment.log                   操作日志
├─ ssh\                            管理密钥
├─ client-exports\                 客户端导出
├─ server-configs\                 服务端配置归档
├─ health-audits\                   健康审计
├─ migration-backups\               协议变更备份
├─ maintenance-backups\             维护备份
└─ SHA256SUMS-private.txt            归档校验值
```

归档根目录依次取自 `-InstanceRoot`、环境变量 `MXH_VPS_INSTANCE_ROOT`、本地覆盖文件 `config/app-defaults.local.json`，最后使用项目通用默认值。旧版根目录计划仍可读取。

普通归档沿用用户目录权限，不做额外 ACL 收紧；**受管 SSH 私钥是例外**：为满足 Windows OpenSSH 最低运行要求，仅在其权限过宽时修复必要权限，不改服务商源私钥，也不因其他错误调整 ACL。

本地路径接受 `/` 或 `\`，但同一条路径不要混用。Cloudflare、Komari 等 Token 使用隐藏输入或私有文件，不应写入普通日志或提交到 Git。

## 命令行入口

交互菜单适合日常使用；已有计划也可直接进入指定功能：

```powershell
# 新部署；可用 -InstanceRoot 指定私有归档根目录
pwsh -File .\Start-VPSDeploy.ps1 -Mode New

# 预览新部署计划，不连接服务器
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -DryRun

# 接入已有 VPS
pwsh -File .\Start-VPSDeploy.ps1 -Mode Import

# 继续计划
pwsh -File .\Start-VPSDeploy.ps1 -Mode Resume -PlanPath '<实例受管目录>\deployment-plan.json'

# 协议管理
pwsh -File .\Start-VPSDeploy.ps1 -Mode Migrate -PlanPath '<实例受管目录>\deployment-plan.json'

# 运维中心
pwsh -File .\Start-VPSDeploy.ps1 -Mode Maintain -PlanPath '<实例受管目录>\deployment-plan.json'

# 独立网络调优
pwsh -File .\Start-VPSDeploy.ps1 -Mode TuneNetwork -PlanPath '<实例受管目录>\deployment-plan.json'

# 客户端配置
pwsh -File .\Start-VPSDeploy.ps1 -Mode ClientConfig
```

`Migrate` 是为兼容旧命令保留的名称，实际对应协议管理。`-OnlyModule` 仅用于理解依赖关系的维护场景，不应绕过首次部署的 SSH、防火墙和最终验收顺序；局部模块完成不代表整套部署完成。

## 验证与开发

```powershell
# 完整本地测试入口
pwsh -NoProfile -File .\tests\Run-Tests.ps1 -ProjectRoot $PWD

# 查询上游版本，不修改配置
pwsh -File .\scripts\Check-UpstreamVersions.ps1
```

测试包含 PowerShell 逻辑、交互、工作台、SSH 私钥权限、菜单契约及具备依赖时的 Bash 隔离模拟。固定资产更新需要同步版本、文件名和 SHA-256，再进行项目测试与真实协议验收。

CI 使用 Windows 验证控制端；Debian 12/13 容器验证远端 Bash、包名与 OpenSSH 契约。隔离模拟不等于真实 systemd 调度、网络故障或 VPS 全流程验收。

## 文档导航

| 文档 | 内容 |
|---|---|
| [中文完整使用手册](docs/USER-GUIDE.zh-CN.md) | 环境准备、部署、维护与验收 |
| [方案工作台与事务恢复](docs/WORKBENCH-AND-RECOVERY.zh-CN.md) | 客户端草稿、发布与中断恢复 |
| [证书与域名配置](docs/CLOUDFLARE-CERTBOT.zh-CN.md) | Cloudflare、Certbot、AnyTLS 与 Reality 本机目标 |
| [安全模型](docs/SECURITY.md) | 凭据、权限与操作边界 |
| [模块开发](docs/MODULES.md) | 模块结构与开发约定 |
| [交互维护](docs/INTERACTION-MAINTENANCE.md) | 导航规范与回归约定 |
| [变更记录](CHANGELOG.md) | 功能调整与修复历史 |
