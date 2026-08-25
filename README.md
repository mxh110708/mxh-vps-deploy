# MXH VPS Deploy

面向个人 Debian/Ubuntu VPS 的中文交互式部署工具。Windows 端运行一个向导，远端操作拆成可独立增删的 Bash 模块。

当前版本覆盖已经多次实际验证的流程：

- 初始只读审计，发现 Docker、面板、复杂防火墙或既有代理服务时默认停止；
- 初始入口同时支持 root 密码和服务商现有私钥（如 DMIT 的 key-only 模板）；
- 新部署向导支持逐项返回修改，切换角色、认证方式或 target 模式时会清除不再适用的旧分支参数；
- 为每台实例生成新的独立 Ed25519 密钥，并收紧 Windows ACL；
- 创建 `admin` 管理用户，保留 root/admin 公钥登录，关闭 SSH 密码登录；
- 分阶段迁移到主、救援两个随机高位 SSH 端口；
- 对 REALITY target 做 TLS 1.3、h2、证书、跳转、CDN 特征与 20 次握手时延审计；
- 固定安装 Xray 26.3.27，部署 VLESS + TCP + REALITY + Vision 主/救援入口；
- REALITY 可改用自有域名和仅监听回环地址的静态 HTTPS target，避免把未认证流量转发到第三方共享入口；
- 可选择互斥的 AnyTLS 入口角色，在 TCP 443 部署公共 CA 可信 TLS、ECH 和低权限 sing-box 服务；
- 通过 Cloudflare DNS-01 与 Certbot 签发 ECDSA 证书，验证模拟续期，并用专用 systemd 计时器自动续期和热部署；
- 可选择纯落地角色，固定安装 sing-box 1.13.19 并部署多用户 Shadowsocks 2022；
- Shadowsocks 主 IPv4 用户和可选 IPv6 用户都会执行 HTTPS 出口及 UDP DNS 往返功能测试；
- Shadowsocks 端口同时支持 TCP/UDP，但只允许向导中填写的可信入口 VPS 地址；
- 可选为第二个 SS2022 用户绑定独立 IPv6 源地址/网卡，实现同端口不同出口；
- 应用最小 nftables，并按角色、内存、标称带宽和代表性 RTT 计算保守 BBR/fq 与 TCP 参数；
- 可选安装低权限、无公网监听、关闭 Web SSH/自动更新的 Komari Agent；
- 生成 Mihomo 与 sing-box 私有客户端片段、服务器配置快照和最终归档；
- 只有新 SSH 入口、Xray、防火墙全部验收后，才关闭服务商初始 SSH 端口。

## 最简单的用法

第一次使用建议先阅读：[中文完整使用手册](docs/USER-GUIDE.zh-CN.md)。手册包含 Windows 环境准备、角色选择、向导逐项填写、Cloudflare/Komari 前置条件、失败恢复、客户端导入和部署后验收。

要求：Windows 10/11、PowerShell 7、Windows OpenSSH Client；目标机是带 systemd/apt 的 Debian 12/13 或 Ubuntu 22.04/24.04，初始可用 root SSH 登录。

双击 `Start-VPSDeploy.cmd`，或运行：

```powershell
pwsh -File .\Start-VPSDeploy.ps1
```

向导会让你选择初始认证方式：

- 密码：工具不读取或保存密码，由 `ssh.exe` 自己显示密码提示；
- 现有私钥：填写 OpenSSH 私钥文件路径，工具只用它完成一次引导并写入新生成的实例专用公钥。现有私钥内容不会复制到源码目录或上传 GitHub。

填写中发现上一项有误时，普通输入或是/否提示整项只输入 `b`，编号菜单输入 `0` 或 `b`。只有去除首尾空格后恰好等于 `b` 才是返回命令，`BreadCloud` 等以 b 开头的正常名称不受影响。在新部署第一项返回会回到主菜单；继续部署的路径输入和计划摘要也有完整返回链路。最后的部署摘要可返回修改或无写入取消，只有选择“确认方案并继续”后才会创建部署计划。

部署开始前，请先在服务商安全组临时放行向导生成的两个 SSH 高位端口。Reality 角色还需要 TCP 443 和 Xray 救援端口，AnyTLS 角色只额外需要 TCP 443；Shadowsocks 落地端口必须按可信入口地址同时限制 TCP/UDP。

## 安全边界

- 源码目录和 Git 仓库内不保存任何实例信息或秘密。
- 每台实例的计划、状态、日志、SSH 私钥、UUID、Reality 密钥、short-id、AnyTLS 密码、TLS 私钥、ECH 服务端密钥、Komari 配置和客户端片段只写入：
  `F:\VPS\VPS-Instances\<服务商>\<实例名>`。
- 工具不修改 Clash Verge AppData，也不自动合并 `Clash_General.yaml` 或 `sing-box-general.json`；它只在实例私有归档中生成待审计片段。
- Komari Token 通过隐藏输入取得，只经 SSH 标准输入传送，不写入命令行和普通日志。
- Cloudflare API Token 从实例私有文件读取，只经 SSH 标准输入传送，并在服务器保存为 root-only 的 Certbot 凭据；Token 值不进入部署计划、普通日志或 Git。
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

## Reality target 与 AnyTLS 的选择

入口协议在向导中三选一使用，不叠加占用 443：

- Reality + 外部 target：保留经过严格实测的大学、机构或成熟企业站点，不需要自有证书；
- Reality + 本机 target：Certbot 为自有域名签发证书，nginx 只监听 `127.0.0.1/[::1]:8443`，Xray 的未认证回落只到本机；
- AnyTLS + 可信 TLS + ECH：独立低权限 sing-box 服务监听 TCP 443，Xray 会停止并禁用，二者由 systemd `Conflicts` 保证互斥。

AnyTLS 的 padding 只配置在服务端。新部署计划会生成一组每实例不同、范围保守且长期固定的 `PerInstanceConservativeV1` 方案；客户端首次会话使用协议默认值，随后自动接收服务端方案，因此 Mihomo 和 sing-box 客户端片段不重复填写 padding。旧计划没有该字段时显式使用官方默认方案。不要为了“更随机”随意扩大到超大分包范围；修改后必须重新做 TCP、UDP 和真实出口测试。

本机 Reality target 更容易控制回落流量，代价是伪装内容和域名由自己维护；外部 target 的站点外观更自然，但需要持续复核 CDN、证书、延迟与握手稳定性。工具不把两种方案宣称为“绝对抗封锁”，应根据网络环境选择。

### Cloudflare 与 Certbot 准备

需要可信 TLS 的角色，先完成以下准备：

1. 在 Cloudflare 创建 DNS-only（灰云）的 A/AAAA 记录。AnyTLS 使用两个不同名称：内部证书/SNI 域名和 ECH public name；本机 Reality target 使用一个独立域名。
2. 创建只作用于该 Zone 的 API Token：`Zone / DNS / Edit` 与 `Zone / Zone / Read`。不要使用 Global API Key 或 Origin CA Key。
3. 如设置客户端 IP 白名单，必须包含实际运行 Certbot 的每台 VPS 公网出口地址；地址变化前先更新 Token，否则自动续期会失败。
4. 将 Token 作为唯一一行保存到实例私有归档中的 `cloudflare-certbot-token.private.txt`，不要粘贴到聊天、源码或公开文档。
5. 准备有效的 ACME 联系邮箱。Certbot 是本工具采用的 ACME 客户端；文件或旧 Token 名称中出现 `acme` 不代表部署了另一个证书程序。

Certbot 安装在实际持有证书的每台 VPS 上。脚本会申请 ECDSA P-256 证书、执行 staging 模拟续期、关闭发行版的重复 `certbot.timer`，并启用 `mxh-certbot-renew.timer` 每日两次运行。续期成功后，部署 hook 会以原子方式复制证书并重启 AnyTLS 或 reload 本机 nginx target。

## 当前明确不自动处理的内容

- 服务商网页安全组、VNC/救援控制台；
- 已有 Docker、3x-ui/s-ui、复杂 nftables 或生产服务的主机；
- 服务商专有的附加 IPv6 获取脚本、策略路由或网络命名空间；
- Hysteria 等其他备用协议；
- 同一台 VPS 上同时运行 Xray Reality 与 AnyTLS，或让两者同时占用 TCP 443；
- 对权威 Clash/sing-box 多节点配置的自动合并；
- Cloudflare Tunnel Token、Komari 主控和数据库迁移。

这些功能可以按同一模块接口增加，但不会为了“功能多”牺牲可回滚性。

## Shadowsocks 落地角色

向导会要求填写允许访问落地端口的入口 VPS 公网 IP。sing-box 使用 `2022-blake3-aes-128-gcm` 多用户结构，主用户走普通 IPv4 出口；存在可用 IPv6 时，可增加第二用户并绑定指定 IPv6 地址和可选接口。部署自测会分别验证 TCP HTTPS 出口和经 SS2022 转发的 UDP DNS 响应，避免只凭监听状态判断 UDP 可用。

生成的 Mihomo 节点使用 `dialer-proxy`，sing-box 出站使用 `detour`，都指向向导填写的入口组/tag。工具只生成实例私有片段，不直接修改权威多节点配置。

Shadowsocks 不是伪装协议，不能把落地端口当作受限网络直连入口。服务商安全组也必须按相同来源白名单限制 TCP 和 UDP。
