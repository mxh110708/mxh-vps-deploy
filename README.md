# MXH VPS Deploy

面向个人 Debian/Ubuntu VPS 的中文交互式部署工具。Windows 端运行一个向导，远端操作拆成可独立增删的 Bash 模块。

当前版本覆盖已经多次实际验证的流程：

- 初始只读审计，发现 Docker、面板、复杂防火墙或既有代理服务时默认停止；
- 初始入口同时支持 root 密码和服务商现有私钥（如 DMIT 的 key-only 模板）；
- 为每台实例生成新的独立 Ed25519 密钥，并收紧 Windows ACL；
- 创建 `admin` 管理用户，保留 root/admin 公钥登录，关闭 SSH 密码登录；
- 分阶段迁移到主、救援两个随机高位 SSH 端口；
- 对 REALITY target 做 TLS 1.3、h2、证书、跳转、CDN 特征与 20 次握手时延审计；
- 固定安装 Xray 26.3.27，部署 VLESS + TCP + REALITY + Vision 主/救援入口；
- 可选择纯落地角色，固定安装 sing-box 1.13.19 并部署多用户 Shadowsocks 2022；
- Shadowsocks 主 IPv4 用户和可选 IPv6 用户都会执行 HTTPS 出口及 UDP DNS 往返功能测试；
- Shadowsocks 端口同时支持 TCP/UDP，但只允许向导中填写的可信入口 VPS 地址；
- 可选为第二个 SS2022 用户绑定独立 IPv6 源地址/网卡，实现同端口不同出口；
- 应用最小 nftables，并按角色、内存、标称带宽和代表性 RTT 计算保守 BBR/fq 与 TCP 参数；
- 可选安装低权限、无公网监听、关闭 Web SSH/自动更新的 Komari Agent；
- 生成 Mihomo 与 sing-box 私有客户端片段、服务器配置快照和最终归档；
- 只有新 SSH 入口、Xray、防火墙全部验收后，才关闭服务商初始 SSH 端口。

## 最简单的用法

要求：Windows 10/11、PowerShell 7、Windows OpenSSH Client；目标机是带 systemd/apt 的 Debian 12/13 或 Ubuntu 22.04/24.04，初始可用 root SSH 登录。

双击 `Start-VPSDeploy.cmd`，或运行：

```powershell
pwsh -File .\Start-VPSDeploy.ps1
```

向导会让你选择初始认证方式：

- 密码：工具不读取或保存密码，由 `ssh.exe` 自己显示密码提示；
- 现有私钥：填写 OpenSSH 私钥文件路径，工具只用它完成一次引导并写入新生成的实例专用公钥。现有私钥内容不会复制到源码目录或上传 GitHub。

部署开始前，请先在服务商安全组临时放行向导生成的两个 SSH 高位端口、443 和可选 Xray 救援端口。

## 安全边界

- 源码目录和 Git 仓库内不保存任何实例信息或秘密。
- 每台实例的计划、状态、日志、SSH 私钥、UUID、Reality 密钥、short-id、Komari 配置和客户端片段只写入：
  `F:\VPS\VPS-Instances\<服务商>\<实例名>`。
- 工具不修改 Clash Verge AppData，也不自动合并 `Clash_General.yaml` 或 `sing-box-general.json`；它只在实例私有归档中生成待审计片段。
- Komari Token 通过隐藏输入取得，只经 SSH 标准输入传送，不写入命令行和普通日志。
- 远程配置每次修改前建立带时间戳备份；失败即停止，不连续跨层“盲修”。
- nftables 模块面向干净 VPS。已有 Docker、面板或复杂规则时必须单独审计，不能强制套用。

详细设计见 [安全模型](docs/SECURITY.md) 和 [模块开发](docs/MODULES.md)。

只检查上游版本而不修改配置：

```powershell
pwsh -File .\scripts\Check-UpstreamVersions.ps1
```

固定版本升级必须先阅读变更、更新 `config/versions.json` 的版本/下载校验，再跑配置测试和真实握手，不能把“发现新版本”等同于“自动升级”。

## 保守自适应网络调优

向导不会运行测速脚本，也不会把虚拟网卡显示的 10G/25G 当作套餐带宽。入口或落地角色可以填写服务商标称带宽和代表性 RTT：入口填写主要使用地到入口的 RTT，落地填写常用入口 VPS 到落地机的 RTT。

脚本结合远端审计得到的实际内存，以两倍带宽时延积（2×BDP）计算 TCP 缓冲区目标，并设置严格内存上限：不超过 512 MiB、1 GiB、2 GiB 和更大内存分别最多使用 4、8、16、32 MiB。它只提高不足的上限，不降低内核或服务商已有值；若现有值已经超过本机保守上限，则原样保留而不覆盖。

所有角色仍保留 fq、可用时的 BBR、TCP Fast Open 和 MTU 探测。入口与落地仅保证较低的监听/SYN 队列下限；监控角色默认只使用基础项，不调整缓冲区。用户也可以在向导中关闭自适应部分。

## 运行模式

```powershell
# 新部署
pwsh -File .\Start-VPSDeploy.ps1 -Mode New

# 从实例私有归档中的计划继续
pwsh -File .\Start-VPSDeploy.ps1 -Mode Resume `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\deployment-plan.json'

# 只做项目离线自检
pwsh -File .\Start-VPSDeploy.ps1 -Mode ValidateProject

# 预览模块和计划，不连接服务器
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -DryRun
```

`-OnlyModule` 是维护模式，只运行指定模块及其必要检查。不要用它跳过首次部署的 SSH/防火墙安全顺序。

## 当前明确不自动处理的内容

- 服务商网页安全组、VNC/救援控制台；
- 已有 Docker、3x-ui/s-ui、复杂 nftables 或生产服务的主机；
- 服务商专有的附加 IPv6 获取脚本、策略路由或网络命名空间；
- AnyTLS/Hysteria 等其他备用协议；
- 对权威 Clash/sing-box 多节点配置的自动合并；
- Cloudflare Tunnel Token、Komari 主控和数据库迁移。

这些功能可以按同一模块接口增加，但不会为了“功能多”牺牲可回滚性。

## Shadowsocks 落地角色

向导会要求填写允许访问落地端口的入口 VPS 公网 IP。sing-box 使用 `2022-blake3-aes-128-gcm` 多用户结构，主用户走普通 IPv4 出口；存在可用 IPv6 时，可增加第二用户并绑定指定 IPv6 地址和可选接口。部署自测会分别验证 TCP HTTPS 出口和经 SS2022 转发的 UDP DNS 响应，避免只凭监听状态判断 UDP 可用。

生成的 Mihomo 节点使用 `dialer-proxy`，sing-box 出站使用 `detour`，都指向向导填写的入口组/tag。工具只生成实例私有片段，不直接修改权威多节点配置。

Shadowsocks 不是伪装协议，不能把落地端口当作受限网络直连入口。服务商安全组也必须按相同来源白名单限制 TCP 和 UDP。
