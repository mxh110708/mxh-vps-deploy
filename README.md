# MXH VPS Deploy

面向个人 Debian/Ubuntu VPS 的中文交互式部署工具。Windows 端运行一个向导，远端操作拆成可独立增删的 Bash 模块。

当前版本覆盖已经多次实际验证的流程：

- 初始只读审计，发现 Docker、面板、复杂防火墙或既有代理服务时默认停止；
- 初始入口同时支持 root 密码和服务商现有私钥（如 DMIT 的 key-only 模板）；
- 可导入没有 `deployment-plan.json` 的现有标准 Xray Reality / AnyTLS / Shadowsocks VPS：默认复用当前 OpenSSH 私钥、不轮换服务器公钥，SSH 认证策略可选择保持现状或收口为 key-only；
- 新部署向导支持逐项返回修改，切换角色、认证方式或 target 模式时会清除不再适用的旧分支参数；
- 已完成且由本工具管理的实例支持 Reality、AnyTLS、Shadowsocks 生命周期管理：补充安装、安装为备用、启用/停用、切换和安全卸载，不按干净新机重跑；
- Reality 与 AnyTLS 可同时保留完整安装，但共用 TCP 443，只允许其中一个开机启用并运行；Shadowsocks 使用独立高位端口，可与入口协议同时运行；
- 每次协议变更会先备份本地计划/状态/凭据/客户端片段，并在 VPS 端保存全部协议文件、systemd 状态、nftables/sysctl，启用 20 分钟独立自动回滚；
- 协议管理提供受限备份清理：本地与远端可分别操作并保留最近 N 份，活动回滚期间强制拒绝删除；
- 所有普通交互提示支持整项输入 `clear` 或 `cls` 清屏，不影响 `Clearwater` 等正常字段；
- 初始密码登录会生成独立 Ed25519 管理密钥；初始已有私钥时默认复制为规范文件名并复用，只有人工选择后才生成和写入新公钥；
- 创建 `admin` 管理用户，保留 root/admin 公钥登录，关闭 SSH 密码登录；
- 分阶段迁移到主、救援两个随机高位 SSH 端口；
- 对 REALITY target 做 TLS 1.3、h2、证书、跳转、CDN 特征与多次握手时延审计；不通过时展示完整非敏感结果，默认更换，也允许输入确认短语并记录原因后人工覆写；
- Xray 可选择当前固定验证版或从 XTLS/Xray-core 官方发布页解析的最新稳定版，解析后的具体版本会写入计划并用于验收；
- REALITY 可改用自有域名和仅监听回环地址的静态 HTTPS target，避免把未认证流量转发到第三方共享入口；
- 可选择 AnyTLS 入口角色，在 TCP 443 部署公共 CA 可信 TLS、ECH 和低权限 sing-box 服务；可与 Reality 同时安装但不能同时启用；
- 通过 Cloudflare DNS-01 与 Certbot 签发 ECDSA 证书，验证模拟续期，并用专用 systemd 计时器自动续期和热部署；
- 可选择纯落地角色，固定安装 sing-box 1.13.19 并部署多用户 Shadowsocks 2022；
- Shadowsocks 主 IPv4 用户和可选 IPv6 用户都会执行 HTTPS 出口及 UDP DNS 往返功能测试；
- Shadowsocks 端口同时支持 TCP/UDP，但只允许向导中填写的可信入口 VPS 地址；
- 可选为第二个 SS2022 用户绑定独立 IPv6 源地址/网卡，实现同端口不同出口；
- 应用最小 nftables，并按角色、内存、标称带宽和代表性 RTT 计算保守 BBR/fq 与 TCP 参数；
- 套餐标称带宽必须填写，参考 RTT 可留空；无 RTT 时只据角色、实测内存和标称带宽选择保守队列，不修改 TCP 缓冲区上限；
- 可选安装低权限、无公网监听、关闭 Web SSH/自动更新的 Komari Agent；
- 生成 Mihomo 与 sing-box 私有客户端片段、服务器配置快照和最终归档；所有新产物统一放入实例目录下的 `MXH-VPS-Deploy` 子目录；
- 提供独立客户端权威配置候选设计器：从已纳管计划提取节点，也可隐藏输入未纳管节点；可选择地区入口、节点成员、落地 transit/detour、各组顺序和首次默认值；
- 提供统一的现有 VPS 运维中心：手动恢复、只读健康/漂移审计、凭据轮换、SSH/防火墙独立维护、固定资产升级、客户端权威候选、Komari 生命周期和分级退役；
- 只有新 SSH 入口、Xray、防火墙全部验收后，才关闭服务商初始 SSH 端口。

## 最简单的用法

第一次使用建议先阅读：[中文完整使用手册](docs/USER-GUIDE.zh-CN.md)。手册包含 Windows 环境准备、角色选择、向导逐项填写、Cloudflare/Komari 前置条件、失败恢复、客户端导入和部署后验收。

要求：Windows 10/11、PowerShell 7、Windows OpenSSH Client；目标机是带 systemd/apt 的 Debian 12/13 或 Ubuntu 22.04/24.04，初始可用 root SSH 登录。

只有使用“客户端权威配置候选设计器”时还需要 Python 3 和 round-trip YAML 依赖。首次使用缺失时，向导会询问是否安装固定依赖；也可提前手动安装：

```powershell
python -m pip install -r .\requirements-client-merge.txt
```

双击 `Start-VPSDeploy.cmd`，或运行：

```powershell
pwsh -File .\Start-VPSDeploy.ps1
```

向导会让你选择初始认证方式：

- 密码：工具不读取或保存密码，由 `ssh.exe` 自己显示密码提示；
- 现有私钥：默认复用同一把 OpenSSH 私钥，复制到实例 `MXH-VPS-Deploy\ssh` 下并改为规范文件名；原文件不改名、不删除，服务器公钥不轮换。也可明确选择生成新的 Ed25519 管理密钥，旧密钥仍保留作引导/救援。

新部署第一项会显示 VPS 私有归档根目录，默认是 `F:\VPS\VPS-Instances`。它只是 `-InstanceRoot` 提供的可编辑默认值，不会在显示提示时创建；可以直接输入另一个完整绝对路径。实例目录仍是 `<根目录>\<服务商>\<实例>`，本工具创建的计划、密钥、日志、快照和候选统一进入其下的 `MXH-VPS-Deploy` 子目录。旧版直接放在实例根目录的计划仍可继续使用。

填写中发现上一项有误时，普通输入或是/否提示整项只输入 `b`，编号菜单输入 `0` 或 `b`。只有去除首尾空格后恰好等于 `b` 才是返回命令，`BreadCloud` 等以 b 开头的正常名称不受影响。在新部署第一项返回会回到主菜单；继续部署的路径输入和计划摘要也有完整返回链路。最后的部署摘要可返回修改或无写入取消，只有选择“确认方案并继续”后才会创建部署计划。

输出过长时，在普通文本、是/否或编号菜单中整项输入 `clear` 或 `cls` 即可清屏并重新显示当前提示；命令采用精确匹配，`Clearwater` 等正常值不会被截获。

部署开始前，请先在服务商安全组临时放行向导生成的两个 SSH 高位端口。Reality 角色还需要 TCP 443 和 Xray 救援端口，AnyTLS 角色只额外需要 TCP 443；Shadowsocks 落地端口必须按可信入口地址同时限制 TCP/UDP。

## 安全边界

- 源码目录和 Git 仓库内不保存任何实例信息或秘密。
- 每台实例的计划、状态、日志、SSH 私钥、UUID、Reality 密钥、short-id、AnyTLS 密码、TLS 私钥、ECH 服务端密钥、Komari 配置和客户端片段只写入向导选择的：
  `<VPS 私有归档根目录>\<服务商>\<实例名>\MXH-VPS-Deploy`（默认根目录为 `F:\VPS\VPS-Instances`）。
- 工具不修改 Clash Verge AppData，也不覆盖 `Clash_General.yaml` 或 `sing-box-general.json`；独立设计器只读取权威文件，在单独候选目录生成完整替换候选。
- Komari Token 通过隐藏输入取得，只经 SSH 标准输入传送，不写入命令行和普通日志。
- Cloudflare API Token 从实例私有文件读取，只经 SSH 标准输入传送，并在服务器保存为 root-only 的 Certbot 凭据；Token 值不进入部署计划、普通日志或 Git。
- Windows 私有文件 ACL 默认按“尽力收紧”处理：失败会明确警告但不让个人电脑上的整个流程报废；需要把 ACL 失败视为硬错误时，可先设置 `MXH_VPS_STRICT_LOCAL_ACL=1`。
- 远程配置每次修改前建立带时间戳备份；失败即停止，不连续跨层“盲修”。
- 新部署的 nftables 模块面向干净 VPS；协议生命周期管理只复用本工具已验收并可回滚的规则。第三方 Docker、面板或复杂规则仍必须单独审计，不能强制套用。

详细设计见 [安全模型](docs/SECURITY.md) 和 [模块开发](docs/MODULES.md)。

只检查上游版本而不修改配置：

```powershell
pwsh -File .\scripts\Check-UpstreamVersions.ps1
```

sing-box/Komari 等固定资产升级必须先阅读变更、更新 `config/versions.json` 的版本与下载校验，再跑配置测试和真实握手。Xray 是例外：安装器脚本本身固定到校验过的提交，用户可选择当前固定验证版，或从 XTLS/Xray-core 官方 `releases/latest` 解析一个非草稿、非预发行的精确版本；两种模式都不会使用模糊的 `latest` 写进计划。

## 保守自适应网络调优

向导不会运行测速脚本，也不会把虚拟网卡显示的 10G/25G 当作套餐带宽。入口或落地角色必须填写服务商标称带宽；代表性 RTT 是可选项：入口填写主要使用地到入口的 RTT，落地填写常用入口 VPS 到落地机的 RTT。

脚本结合远端审计得到的实际内存，以两倍带宽时延积（2×BDP）计算 TCP 缓冲区目标，并设置严格内存上限：不超过 512 MiB、1 GiB、2 GiB 和更大内存分别最多使用 4、8、16、32 MiB。它只提高不足的上限，不降低内核或服务商已有值；若现有值已经超过本机保守上限，则原样保留而不覆盖。

所有角色仍保留 fq、可用时的 BBR、TCP Fast Open 和 MTU 探测。脚本按标称带宽分档选择较低的监听/SYN 队列下限，但不会根据一次测速追逐激进参数；只有提供 RTT 才计算缓冲区。监控角色默认只使用基础项。

## 运行模式

```powershell
# 新部署
pwsh -File .\Start-VPSDeploy.ps1 -Mode New

# 使用另一个默认归档根目录；向导中仍会显示并允许修改
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -InstanceRoot 'D:\Private-VPS-Archive'

# 从实例私有归档中的计划继续
pwsh -File .\Start-VPSDeploy.ps1 -Mode Resume `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'

# 导入没有 deployment-plan.json 的现有 VPS
pwsh -File .\Start-VPSDeploy.ps1 -Mode Import

# 管理本工具已完整验收实例的协议（安装、备用、切换、停用、卸载、备份）
pwsh -File .\Start-VPSDeploy.ps1 -Mode Migrate `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'

# 现有 VPS 统一运维中心
pwsh -File .\Start-VPSDeploy.ps1 -Mode Maintain `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'

# 对已纳管 VPS 单独执行网络调优；默认基础模式不需要 RTT
pwsh -File .\Start-VPSDeploy.ps1 -Mode TuneNetwork `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'

# 独立设计 Clash/sing-box 完整候选，不连接 VPS、不覆盖权威文件
pwsh -File .\Start-VPSDeploy.ps1 -Mode ClientConfig

# 只做项目离线自检
pwsh -File .\Start-VPSDeploy.ps1 -Mode ValidateProject

# 预览模块和计划，不连接服务器
pwsh -File .\Start-VPSDeploy.ps1 -Mode New -DryRun
```

`-OnlyModule` 是维护模式，只运行指定模块及其必要检查。不要用它跳过首次部署的 SSH/防火墙安全顺序。

`-Mode Migrate` 保留名称是为了兼容旧命令，现在进入的是协议生命周期管理器，不是任意服务器覆盖器。实例必须由本工具完成部署并保留成功的 SSH、防火墙、最终验收、收口和私有归档状态。可选择：

- 安装新协议并切换使用：新协议完成真实测试后启用；冲突的旧 443 协议保留安装但停用；
- 安装为备用：临时切换完成真实测试，然后恢复变更前状态，新协议保持已安装但停用；
- 切换/启停：不重新安装，只修改已安装服务的 enabled/active 状态并重新验收；
- 卸载：只允许卸载已经停用且未运行的协议，先备份再删除运行时、systemd 单元和服务端配置；
- 清理备份：只处理实例归档中的 `migration-backups` 和 VPS 上本工具的 `protocol-lifecycle`/旧 `protocol-migration` 目录，可保留最近 N 份。

失败时优先立即恢复变更前的全部协议文件、服务状态和防火墙；SSH 不可达时仍由 VPS 端计时器独立恢复。安装 Shadowsocks 还必须提供另一台可信入口计划，完成入口→落地链式实测。

没有计划的现有 VPS 先使用 `-Mode Import`。导入器只支持标准路径和可解析的 VLESS+Reality、AnyTLS、Shadowsocks 配置；已有 OpenSSH 私钥默认直接复用，服务器公钥不轮换。SSH 认证策略默认保持现状，也可在公钥复验后选择 key-only。导入不改代理端口、不重装协议、不覆盖现有防火墙。导入计划使用 `PreserveExisting`，因此可以在既有 Reality 的同一 TCP 443 上补装 AnyTLS 备用；新增 Shadowsocks 高位端口仍必须单独审计现有防火墙。

客户端配置设计器使用 `config/client-layout.default.json` 作为无凭据结构模板；本机个性化默认值保存到被 Git 忽略的 `config/client-layout.local.json`。设计器会扫描新旧两种归档布局中的已纳管计划，也允许手动隐藏输入未纳管的 VLESS Reality、AnyTLS 或 Shadowsocks 节点。它会校验 selector 引用和循环、同步 `dialer-proxy`/`detour`、执行可用的 Mihomo 双核心测试并严格解析 sing-box JSON，但始终只写候选。

## Reality target 与 AnyTLS 的选择

Reality 和 AnyTLS 是两套可并存安装的入口实现，但运行时必须二选一占用 TCP 443：

- Reality + 外部 target：保留经过严格实测的大学、机构或成熟企业站点，不需要自有证书；
- Reality + 本机 target：Certbot 为自有域名签发证书，nginx 只监听 `127.0.0.1/[::1]:8443`，Xray 的未认证回落只到本机；
- AnyTLS + 可信 TLS + ECH：独立低权限 sing-box 服务监听 TCP 443；启用时 Xray 会停止并取消开机启用，但其二进制、配置、凭据和客户端片段可继续保留，二者由显式状态切换和 systemd `Conflicts` 双重保证运行互斥。

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

## 运维中心的关键边界

- 远端修改先保存本地计划/状态/凭据/客户端片段和服务器快照，再启动 VPS 端 20 分钟独立回滚 timer；SSH 密钥/端口变更使用单独的 10 分钟 timer。
- 健康审计只读取服务、监听、有效 SSH、证书、版本和配置 SHA-256，不回传配置正文。严重状态异常不能靠“更新基线”掩盖。
- 凭据轮换先生成候选并做真实协议测试。Reality 为事务化原子切换；AnyTLS 默认轮换用户密码并保留 ECH/证书；Shadowsocks 默认轮换用户密钥并保留服务器主密钥。
- `PreserveExisting` 防火墙默认只能审计；接管为最小 nftables 必须输入确认短语。未知 Docker、面板和第三方规则不会被静默覆盖。
- 客户端合并与退役删除只生成候选，候选通过 Mihomo 双核心和严格 JSON 检查后仍由用户替换权威文件。
- 退役分为预检、可恢复停用、删除受管文件、清除远端恢复点及包含 Controller/Connector 的整机受管组件退役；最后两类需要二次确认，并始终保留 SSH 与基础系统。

## 当前明确不自动处理的内容

- 服务商网页安全组、VNC/救援控制台；
- 不属于本工具完整归档管理的 Docker、3x-ui/s-ui、复杂 nftables 或生产服务主机；
- 服务商专有的附加 IPv6 获取脚本、策略路由或网络命名空间；
- Hysteria 等其他备用协议；
- 同一台 VPS 上同时运行 Xray Reality 与 AnyTLS，或让两者同时占用 TCP 443；
- 直接覆盖权威 Clash/sing-box 配置或 Clash Verge AppData；
- Cloudflare 控制台内创建/撤销 Tunnel Token、服务商实例删除或跨两台 VPS 自动裁决最终连接器。脚本可管理本机 Komari Agent、Controller 数据备份/恢复和已有 cloudflared Token 轮换。

这些功能可以按同一模块接口增加，但不会为了“功能多”牺牲可回滚性。

## Shadowsocks 落地角色

向导会要求填写允许访问落地端口的入口 VPS 公网 IP。sing-box 使用 `2022-blake3-aes-128-gcm` 多用户结构，主用户走普通 IPv4 出口；存在可用 IPv6 时，可增加第二用户并绑定指定 IPv6 地址和可选接口。部署自测会分别验证 TCP HTTPS 出口和经 SS2022 转发的 UDP DNS 响应，避免只凭监听状态判断 UDP 可用。

生成的 Mihomo 节点使用 `dialer-proxy`，sing-box 出站使用 `detour`，都指向向导填写的入口组/tag。工具只生成实例私有片段，不直接修改权威多节点配置。

Shadowsocks 不是伪装协议，不能把落地端口当作受限网络直连入口。服务商安全组也必须按相同来源白名单限制 TCP 和 UDP。
