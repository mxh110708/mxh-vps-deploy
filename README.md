# MXH VPS Deploy

面向个人 Debian/Ubuntu VPS 的中文交互式部署与维护工具。Windows 端负责向导、私有归档和客户端配置，远端操作拆成可验证、可恢复的 Bash 模块。

它解决的不是“运行一条安装命令”，而是 VPS 的完整生命周期：新机部署、既有实例纳管、协议共存与切换、网络调优、日常维护、客户端配置生成以及最终退役。

## 从这里开始

环境要求：

- Windows 10/11；
- PowerShell 7（`pwsh.exe`）；
- Windows OpenSSH Client（`ssh.exe`、`scp.exe`、`ssh-keygen.exe`）；
- 目标机使用 systemd/apt，推荐 Debian 12/13 或 Ubuntu 22.04/24.04；
- 目标机有可用的 root SSH 登录方式，可以是密码，也可以是服务商现有私钥。

首次使用先运行离线自检：

```powershell
pwsh -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
```

然后双击 `Start-VPSDeploy.cmd`，或运行：

```powershell
pwsh -File .\Start-VPSDeploy.ps1
```

主菜单固定为：

```text
1. 新部署
2. 继续未完成部署
3. 导入/纳管没有 deployment-plan 的现有 VPS
4. 现有 VPS 协议管理
5. 现有 VPS 运维中心
6. 现有 VPS 独立网络调优
7. Clash/sing-box 客户端权威配置设计器
8. 项目离线自检
9. 退出
```

交互命令只有一套语义：

- `9`：只在主菜单退出程序；
- `0`：只在子菜单、向导字段或确认页面返回上一级；
- `b`、`back`：始终是普通输入，不是控制命令；
- `clear`、`cls`：清屏并重新显示当前提示；
- `help`、`h`、`?`：显示当前入口的帮助；
- 留空：采用方括号中的默认值。

当某个字段本身允许数值 `0`（例如备份保留数量）时，界面会明确说明“0 是有效数值”；此时返回应在上一层菜单完成。

完整的新手说明见 [中文完整使用手册](docs/USER-GUIDE.zh-CN.md)。

部署 AnyTLS 或 Reality 本机 target 前，建议单独收藏 [Cloudflare、Certbot、AnyTLS 与 Reality 本机 target 配置手册](docs/CLOUDFLARE-CERTBOT.zh-CN.md)。

## 应该选择哪个入口

| 你的目标 | 主菜单 |
|---|---:|
| 配置一台新 VPS | 1 |
| 上次中断后继续执行同一份计划 | 2 |
| 现有 VPS 已经有 Reality、AnyTLS 或 Shadowsocks，但还没有本工具计划 | 3 |
| 在已纳管实例上安装备用协议、切换、停用、卸载或清理协议备份 | 4 |
| 做恢复、审计、凭据轮换、SSH/防火墙维护、升级、Komari 或退役 | 5 |
| 只调整网络参数，不改变协议和防火墙 | 6 |
| 组合多台入口/落地节点并生成 Clash 与 sing-box 完整配置 | 7 |
| 只检查项目文件、脚本语法和离线测试 | 8 |

“继续未完成部署”只用于已有 `deployment-plan.json` 且模块未全部完成的任务，不等同于“给现有 VPS 增加协议”。没有计划的现有 VPS 应先纳管；已经纳管的实例应进入协议管理或运维中心。

## 当前功能

### 新部署与纳管

- 初始登录支持 root 密码或服务商现有 OpenSSH 私钥；
- 现有私钥默认复制为实例规范文件名并继续复用，不修改源文件、不轮换服务器公钥；
- 密码引导或人工明确选择时才生成新的 Ed25519 管理密钥；
- 新部署创建 `admin`、收口为 key-only；初始为 22/低位端口时迁移到两个随机高位端口，服务商已提供非特权高位端口时复用为主端口并只新增一个救援端口；
- 既有 VPS 纳管默认保留当前 SSH 认证策略、端口和防火墙，只识别标准路径中的受支持协议；
- 新产物统一进入实例目录下的 `MXH-VPS-Deploy` 受管子目录，旧版根目录计划仍可读取。

### 代理协议

- Xray VLESS + REALITY + Vision；
- sing-box AnyTLS + 公共 CA 可信 TLS + ECH；
- sing-box Shadowsocks 2022 多用户落地；
- Reality 与 AnyTLS 可以同时安装，但因共用 TCP 443，只能有一个启用并运行；
- Shadowsocks 使用独立高位 TCP/UDP 端口，可与入口协议同时运行；
- 协议管理支持安装并切换、安装为停用备用、启停、切换、卸载和受限备份清理。

### Reality、证书与 AnyTLS

- 外部 Reality target 会检查 TCP/443、TLS 1.3、h2、证书、跳转、CDN 特征与多次握手时延；
- 自动门槛不通过时展示非敏感结果，默认要求更换，也允许人工输入确认短语并记录原因后继续；
- Reality 也可使用自有域名和只监听回环地址的静态 HTTPS target；
- AnyTLS 使用 DNS-01、Certbot、ECDSA 证书、ECH 和低权限 systemd 服务；
- 证书续期由专用 systemd timer 自动执行，成功后热更新服务；
- AnyTLS padding 采用每实例生成、长期固定的保守方案，由服务端下发，客户端无需重复填写。

### 网络、防火墙与验证

- 新部署在干净 VPS 上应用最小 nftables；
- Shadowsocks 端口按可信入口地址限制 TCP/UDP；
- 网络调优需要服务商标称带宽，代表性 RTT 可留空；
- 脚本结合远端实测内存和用户提供的套餐数据选择保守参数，不运行公网测速，也不把虚拟网卡速率当作套餐带宽；
- 每次受管变更先建立本地/远端快照并启用 VPS 端自动回滚计时器；
- Reality/AnyTLS 要做真实客户端握手、HTTPS 出口与 UDP 测试；Shadowsocks 还支持从另一台可信入口执行链式探测。

### 运维与客户端配置

- 手动恢复中心；
- 只读健康审计和配置漂移检测；
- 代理凭据轮换；
- SSH 独立维护与独立回滚；
- 防火墙独立审计、重建和 Shadowsocks 白名单维护；
- Xray、sing-box、Komari Agent/Controller 的可控版本升级；
- Komari Agent、Controller、数据库/主题备份恢复、Tunnel Token 轮换与卸载；
- 分级退役，始终保留 SSH 和基础系统；
- 基于项目通用模板生成 Clash/sing-box 完整配置；
- 从已纳管实例提取节点，也可隐藏输入未纳管节点；
- 自定义地区入口、落地 transit/detour、组内排序、业务组默认值和显示顺序；
- 生成新配置，或在校验和备份后原子覆盖用户指定的权威配置。

## 私有归档布局

通用布局为：

```text
<实例归档根目录>\<服务商>\<实例>\MXH-VPS-Deploy\
├─ deployment-plan.json
├─ deployment-state.json
├─ deployment-secrets.private.json
├─ deployment.log
├─ ssh\
├─ client-exports\
├─ server-configs\
├─ health-audits\
├─ migration-backups\
├─ maintenance-backups\
└─ SHA256SUMS-private.txt
```

具体目录只在向导确认后创建。默认归档根目录解析顺序为：

1. `-InstanceRoot`；
2. 环境变量 `MXH_VPS_INSTANCE_ROOT`；
3. 被 Git 忽略的 `config/app-defaults.local.json`；
4. 项目内的通用相对默认值。

所有要求填写本地路径的向导项和命令行参数都接受 `/` 或 `\` 作为分隔符；同一条路径必须统一使用一种写法，混用会在访问文件前明确拒绝。接受后会规范化为当前系统的本机分隔符。

项目源码和 Git 仓库不得保存真实 IP、端口、UUID、私钥、密码、Token 或完整个人客户端配置。

## 客户端设计器依赖

只有使用客户端权威配置设计器时需要 Python 3 和固定的 round-trip YAML 依赖：

```powershell
python -m pip install -r .\requirements-client-merge.txt
```

设计器默认从 `templates/client/` 的通用骨架生成，不依赖任何个人路径。通用布局在 `config/client-layout.default.json`；本机偏好写入被 Git 忽略的 `config/client-layout.local.json`，可在设计器子菜单中查看、修改或恢复。

工具拒绝写入 Clash Verge AppData。覆盖模式只接受用户明确指定的一对独立权威文件，并在 Mihomo/JSON/引用/体积检查通过后建立时间戳备份和原子替换。

## 命令行模式

```powershell
# 新部署
pwsh -File .\Start-VPSDeploy.ps1 -Mode New

# 使用指定归档根目录
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -InstanceRoot 'D:\Private-VPS-Archive'

# 等价的正斜杠写法（同一路径不要混用两种分隔符）
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -InstanceRoot 'D:/Private-VPS-Archive'

# 继续计划
pwsh -File .\Start-VPSDeploy.ps1 -Mode Resume `
  -PlanPath '<实例受管目录>\deployment-plan.json'

# 纳管没有计划的现有 VPS
pwsh -File .\Start-VPSDeploy.ps1 -Mode Import

# 协议管理
pwsh -File .\Start-VPSDeploy.ps1 -Mode Migrate `
  -PlanPath '<实例受管目录>\deployment-plan.json'

# 运维中心
pwsh -File .\Start-VPSDeploy.ps1 -Mode Maintain `
  -PlanPath '<实例受管目录>\deployment-plan.json'

# 独立网络调优
pwsh -File .\Start-VPSDeploy.ps1 -Mode TuneNetwork `
  -PlanPath '<实例受管目录>\deployment-plan.json'

# 客户端权威配置设计器
pwsh -File .\Start-VPSDeploy.ps1 -Mode ClientConfig

# 项目离线自检
pwsh -File .\Start-VPSDeploy.ps1 -Mode ValidateProject

# 只生成/预览计划，不连接服务器
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -DryRun
```

`-Mode Migrate` 是为了兼容旧命令保留的名称，实际入口是“现有 VPS 协议管理”。`-OnlyModule` 只面向明确理解依赖关系的维护场景，不应借此跳过首次部署的 SSH、防火墙和最终验收顺序。

## 安全边界

- 工具不操作服务商网页安全组、VNC/救援控制台或删除云端实例；
- 新部署的最小 nftables 只适用于审计确认的干净 VPS；
- 导入实例默认使用 `PreserveExisting`，不会静默覆盖 Docker、面板或第三方规则；
- Cloudflare 和 Komari Token 通过隐藏输入或私有文件取得，不写入普通日志或 Git；
- Windows 私有文件 ACL 默认尽力收紧；设置 `MXH_VPS_STRICT_LOCAL_ACL=1` 可把 ACL 失败改为硬错误；
- 远端修改在提交前均保留恢复路径，高风险清理/退役要求额外确认；
- “服务监听”“语法通过”不能替代真实客户端握手、出口 IP、HTTPS 与 UDP 验收。

详细说明：

- [中文完整使用手册](docs/USER-GUIDE.zh-CN.md)
- [Cloudflare、Certbot、AnyTLS 与 Reality 本机 target 配置手册](docs/CLOUDFLARE-CERTBOT.zh-CN.md)
- [安全模型](docs/SECURITY.md)
- [模块开发与内部结构](docs/MODULES.md)
- [变更记录](CHANGELOG.md)

检查上游版本但不修改任何配置：

```powershell
pwsh -File .\scripts\Check-UpstreamVersions.ps1
```

版本升级必须先更新 `config/versions.json` 中的精确版本、资产名和 SHA-256，再通过项目测试与真实协议验收。项目不会把模糊的 `latest` 直接写进部署计划。
