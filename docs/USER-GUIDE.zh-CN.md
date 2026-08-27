# MXH VPS Deploy 中文完整使用手册

本文面向第一次使用 VPS 自动部署脚本的用户。按照“准备清单 → 项目自检 → 运行向导 → 验收 → 归档”的顺序操作，不需要事先理解 PowerShell、Xray、sing-box 或 nftables 的内部实现。

文中的域名、IP、端口、目录名均为示例占位符。不要把示例值直接用于正式部署，也不要把真实密码、Token、UUID、私钥或完整节点配置粘贴到聊天、Issue、公开 Git 仓库或通用文档。

## 0. 十分钟快速上手

如果你只想先完成一台最常见的 Reality 外部 target 新机，可以按这张短清单操作，再回到后文了解细节：

1. 在服务商面板安装干净 Debian 13，确认 root 可以通过密码或服务商私钥登录，并保留 VNC/KVM/Console。
2. 记录 VPS IPv4、可选 IPv6、当前 SSH 端口、套餐带宽和常用地点到 VPS 的 RTT。
3. 准备一个已经从该 VPS 实测、符合 TLS 1.3/h2/证书/地区/非共享 CDN 要求的 Reality target。
4. 在 PowerShell 7 运行项目自检：

   ```powershell
   Set-Location 'F:\VPS\MXH-VPS-Deploy'
   pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
   ```

5. 双击 `Start-VPSDeploy.cmd`，选择“新部署”→“Reality 入口节点”→“外部大学/机构/企业 target”；端口和 admin 用户先接受默认值。
6. 摘要出现后，在服务商安全组保留当前 SSH，并放行脚本显示的 SSH 主/救援端口、TCP 443 和 Xray 救援端口，然后回到终端确认继续。
7. 不关闭窗口、不重启 VPS。按提示输入 root 密码或私钥口令、可选 Komari Token，并在最终 SSH 收口前再次确认。
8. 完成后保存整个实例目录，用主/救援测试 YAML 验证 HTTP 204 和出口 IP，再从服务商安全组删除初始 SSH 规则。

最快路径不需要 Cloudflare、证书域名或 AnyTLS。需要这些能力时先阅读第 6 节，不要边运行向导边临时创建 Token。

## 1. 这个工具能做什么

工具在 Windows 上运行中文向导，通过 SSH 配置一台以 `apt` 和 systemd 为基础的 Debian/Ubuntu VPS。主要能力包括：

- 从服务商初始 root 密码生成管理密钥，或复用服务商现有 OpenSSH 私钥；
- 创建日常使用的 `admin` 用户并验证 sudo；
- 把 SSH 迁移到主、救援两个随机高位端口，关闭 SSH 密码登录；
- 部署以下角色之一：
  - Xray VLESS + TCP + Reality + Vision 入口；
  - sing-box AnyTLS + 公共可信 TLS + ECH 入口；
  - sing-box Shadowsocks 2022 纯落地节点；
  - 仅 SSH、防火墙、网络基础项和可选 Komari；
  - 建立或复用管理公钥后只做系统审计；
- 应用面向干净 VPS 的最小 nftables；
- 按内存、角色、标称带宽和参考 RTT 做保守网络调优；
- 可选安装低权限 Komari Agent；
- 生成 Mihomo 测试 YAML、sing-box 出站片段、服务器配置快照和私有归档；
- 在关闭服务商初始 SSH 入口前，验证 root/admin、主/救援端口、sudo、服务状态和真实代理出口；
- 对已纳管实例执行恢复、健康/漂移审计、凭据轮换、SSH/防火墙维护、固定版本升级、客户端候选合并、Komari 生命周期和分级退役。

工具不会自动完成以下操作：

- 不操作服务商网页安全组、VNC 或救援控制台；
- 不修改 Cloudflare 网页中的 DNS 记录或 API Token；
- 不在 Cloudflare 控制台自动创建/撤销 Tunnel；脚本可以备份/恢复本机 Komari Controller 数据和轮换已有 Connector Token，但最终跨主机切换仍需用户确认外部状态；
- 不修改 Clash Verge AppData profile；
- 不覆盖权威 `Clash_General.yaml`、`sing-box-general.json` 或 AppData；只生成完整候选供人工替换；
- 不适合直接覆盖已有 Docker、3x-ui/s-ui、复杂 nftables 或生产服务的主机；
- 不在同一台机器上同时运行 Xray Reality 和 AnyTLS 占用 TCP 443。

## 2. 先选择正确的部署角色

如果不确定，先看下面的选择表。

| 你的目标 | 向导中选择 | 说明 |
|---|---|---|
| 新建常用代理入口，暂时不想管理域名证书 | Reality 入口节点 | 默认推荐；使用经过严格审计的外部 target |
| 新建 Reality，但希望未认证回落只到本机 | Reality 入口节点 + 本机 HTTPS target | 需要 Cloudflare DNS、Token 和自有域名 |
| 新建 AnyTLS 主入口，使用可信 TLS 和 ECH | AnyTLS 入口节点 | 需要两个不同子域名、Cloudflare Token；固定 TCP 443 |
| VPS 只作为链式最终出口 | Shadowsocks 2022 纯落地节点 | 端口只能对白名单入口 VPS 开放，不能作为用户直连入口 |
| 已有 Reality/AnyTLS/SS VPS，但没有 deployment-plan | 导入/纳管现有 VPS | 识别标准路径配置，建立私有计划；不重装协议、不改端口、不覆盖现有防火墙 |
| 给已部署 VPS 增加备用协议、切换、停用或卸载 | 现有 VPS 协议管理 | Reality/AnyTLS 可同时安装但只启用一个；Shadowsocks 可独立并行；不重做 SSH/账号基础层 |
| 只想调整一台已纳管 VPS 的网络参数 | 现有 VPS 独立网络调优 | 默认基础保守模式不需要 RTT；不会顺带重装协议或改防火墙 |
| 只要 SSH 加固、防火墙和 Komari | 仅 SSH/防火墙/Komari 监控 | 仍会修改 SSH、nftables 和基础网络参数，不是只安装探针 |
| 先查看系统情况，不部署服务 | 建立/复用管理 SSH 公钥后执行审计 | 初始密码时添加新公钥；现有私钥默认不改服务器公钥；除此之外只写本地审计归档 |

### 2.1 Reality 外部 target

适合希望保持常见 Reality 架构的用户。候选必须是 VPS 能稳定访问的普通 HTTPS 网站，并满足：

- TCP 443、有效证书、TLS 1.3、ALPN h2；
- 与 VPS 同地区或邻近，握手中位通常不超过 15 ms；
- 预期长期运营的大学、科研机构、成熟企业或专业机构网站；
- 不使用个人小站、Apple/iCloud 目标、明显大型多租户共享 CDN 入口；
- 不把一次端口可达或一次 TLS ping 当作最终结论。

脚本会从 VPS 侧采样并显示 TLS、h2、证书、HTTP、跳转、CNAME/CDN、成功率及中位/P95/最大时延。候选失败时默认输入另一个域名重新测试，新候选会同步更新服务端 target 和客户端 SNI。

如果你有脚本无法建模的现场依据，也可以选择人工接受。必须输入 `ACCEPT-TARGET-RISK` 并填写原因，结果和原因只写私有审计记录；非交互模式不允许覆写。人工接受只跳过自动门槛，不能跳过后续 Reality Authentication、HTTP 204 和真实出口测试，握手失败仍会停止并回滚。

### 2.2 Reality 本机 HTTPS target

适合希望控制 Reality 未认证回落流量的用户。脚本将：

- 用 Certbot + Cloudflare DNS-01 为自有域名申请公共 CA 证书；
- 安装 nginx，但只监听 `127.0.0.1/[::1]:8443`；
- 不在 nftables 或服务商安全组开放 8443；
- 让 Xray 的 target 指向回环 HTTPS 服务；
- 验证 TLS 1.3、h2、证书和公网 443 回落。

该模式便于控制回落，但不等于具备大型网站完全相同的流量外观。

### 2.3 AnyTLS + 可信 TLS + ECH

适合准备把 AnyTLS 作为主入口协议的用户。脚本将：

- 在 TCP 443 运行独立低权限 sing-box 服务；
- 使用公共 CA 证书并保持客户端证书校验；
- 生成 ECH 服务端密钥和客户端配置；
- 为每台实例生成一次独立的保守 padding scheme，写入计划后不随重启轮换；
- 真实测试 HTTPS 204、出口 IP、UDP DNS 和 ECH；
- 如果 AnyTLS 切换失败，恢复切换前的 Xray active/enabled 状态。

AnyTLS 与 Reality 可以同时安装并保存各自配置，但它们共用 TCP 443，因此只允许一个处于 systemd enabled/active 状态。脚本切换时会显式停用另一个服务，并由 `Conflicts=xray.service` 再做一层运行时保护。

### 2.4 Shadowsocks 2022 纯落地

落地节点只接受入口 VPS 发起的链式连接：

```text
客户端 → 入口节点 → Shadowsocks 落地 → 外网
```

向导中填写的是“入口 VPS 的公网 IP”，不是家宽 IP。服务端和服务商安全组都必须只允许这些来源访问落地 TCP/UDP 端口。

主用户走普通 IPv4 出口。如果 VPS 有一个确实可用的独立 IPv6 地址，可以增加第二用户并绑定该 IPv6 出口。一般不要填写网卡名；只有多网卡或明确需要 `SO_BINDTODEVICE` 时才填写接口。

### 2.5 已部署 VPS 的协议生命周期管理

不要用“新部署”覆盖正在使用的 VPS。主菜单中的“现有 VPS 协议管理”只接受本工具已经完整验收、仍保留私有计划/状态/凭据和实例专用 SSH 密钥的实例。它把两个概念分开记录：

- **已安装**：运行时、systemd 单元、服务端配置和本地私有凭据仍存在；
- **已启用/运行中**：服务设置为开机启用并正在运行。

支持的操作包括：

- 安装新协议并切换使用；
- 安装并真实验证，但最终保留为停用备用；
- 在已安装的 Reality 与 AnyTLS 之间快速切换；
- 独立启用或停用 Shadowsocks；
- 停用协议但保留安装；
- 卸载已经停用的协议；
- 清理本地和远端协议变更备份。

Reality 与 AnyTLS 可同时安装但不能同时启用；Shadowsocks 使用独立高位端口，可以和任一入口协议同时运行。管理器复用现有双高位 SSH、admin、Komari 和私有归档，不接受手工拼装计划，也不自动覆盖面板、Docker 或第三方复杂防火墙。

### 2.6 导入没有 deployment-plan 的现有 VPS

“导入/纳管”用于已经配置好代理、但此前不是由本工具创建计划的 VPS。它支持识别标准路径中的兼容配置：

- Xray：`/usr/local/etc/xray/config.json` 中的 VLESS + Reality + Vision；
- AnyTLS：`/etc/sing-box-anytls/config.json` 及标准 ECH/证书路径；
- Shadowsocks：`/etc/sing-box/config.json` 中本工具兼容的 SS2022 多用户布局。

导入流程会：

1. 用现有 root 密码或私钥连接；
2. 如果已经使用 OpenSSH 私钥，默认复制到 `MXH-VPS-Deploy\ssh\id_vps_management` 并继续使用同一把密钥；原文件和服务器公钥不变；
3. 只有初始密码登录或人工选择“生成新管理密钥”时，才创建 Ed25519 密钥并把新公钥加入服务器；
4. 默认保持服务器现有 SSH 认证策略；如明确选择 key-only，才写入可回退的最小加固配置并复验；
5. 只读检查系统、SSH、现有防火墙和三个协议服务；
6. 从标准配置提取当前协议参数与凭据，直接写入本地私有归档，不在控制台打印；
7. 在实例目录下新建 `MXH-VPS-Deploy` 子目录，保存计划、状态、私有凭据和客户端片段。

导入不会重装现有协议、改变代理端口或覆盖防火墙。计划标记为 `PreserveExisting`：以后 Reality/AnyTLS 在已有 TCP 443 上切换时保留原防火墙；新增 Shadowsocks 高位端口则拒绝自动操作，必须先单独审计并人工配置现有防火墙。

导入不是任意面板转换器。配置路径、协议布局、多个 Reality inbound 的凭据/target 不一致，或存在部分安装时会拒绝。只有一个 SSH 端口时可以纳管，但会明确提示它不等同于新部署的双 SSH 救援设计。

## 3. 使用前的安全前提

### 3.1 必须是干净 VPS

正式部署角色要求初始审计满足：

- 没有 Docker、代理面板、已有 Xray/sing-box 或其他生产服务；
- 没有非空复杂 nftables 规则；
- 443 和计划使用的高位端口没有被占用；
- 能使用 root 通过当前 SSH 入口登录；
- 系统为带 systemd/apt 的 Debian 或 Ubuntu。

最小 nftables 模板包含 `flush ruleset`。如果机器已经有业务，脚本会主动停止，不要通过删除检测逻辑强行继续。更安全的做法是重装干净系统，或针对现有服务单独设计迁移方案。

当前完整现场测试主要基于 Debian 13 x86_64。项目也包含 Debian/Ubuntu、amd64/arm64 路径，但 Ubuntu、ARM64 和所有异常组合并没有同等级的长期生产覆盖。

### 3.2 必须保留救援手段

开始前确认至少有一种带外恢复方式：

- 服务商 VNC/KVM/Console；
- 服务商救援系统；
- 可以重装系统并重新取得 root 凭据。

部署期间不要删除服务商初始 SSH 规则。脚本只会在最后一次 root/admin 双端口验证通过后收口初始 SSH。

### 3.3 本地私有归档不能公开

默认实例目录：

```text
F:\VPS\VPS-Instances\服务商\实例名
```

脚本新建的所有运行产物集中在其下的 `MXH-VPS-Deploy` 子目录；服务商原始密钥、账单和用户已有说明文件不会被搬动。

该目录最终可能包含：

- SSH 私钥；
- admin sudo 密码；
- UUID、Reality PrivateKey、short-id；
- AnyTLS 密码、TLS 私钥、ECH 服务端密钥；
- Shadowsocks 服务端和用户密钥；
- Komari 配置；
- Cloudflare Token 文件路径以及完整客户端节点片段。

工具会尝试移除私有文件的继承 ACL，只授权当前 Windows 用户和 SYSTEM。默认模式下 ACL 收紧失败会警告但不中止，适合个人电脑和非标准磁盘权限；需要严格模式时，在启动前设置 `$env:MXH_VPS_STRICT_LOCAL_ACL='1'`。

工具生成的 Ed25519 私钥没有口令，便于自动验证；安全性依赖严格 ACL。复制到移动硬盘、NAS 或云盘时，应额外使用 BitLocker、加密容器或加密备份。

## 4. Windows 端准备

### 4.1 系统与程序要求

- Windows 10/11；
- PowerShell 7，命令名为 `pwsh.exe`；
- Windows OpenSSH Client：`ssh.exe`、`scp.exe`、`ssh-keygen.exe`；
- 可访问目标 VPS；
- Clash Verge/Mihomo 可选，但安装在默认路径时可以自动完成双核心语法和真实出口测试。

在 PowerShell 7 中检查：

```powershell
$PSVersionTable.PSVersion
Get-Command pwsh.exe, ssh.exe, scp.exe, ssh-keygen.exe
```

如果没有 PowerShell 7，Microsoft 推荐在 Windows 客户端使用 WinGet：

```powershell
winget install --id Microsoft.PowerShell --source winget
```

官方说明：[在 Windows 安装 PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)。

如果缺少 OpenSSH Client，以管理员身份打开 PowerShell 后执行：

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

官方说明：[安装 Windows OpenSSH 组件](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse)。只需要 Client，不需要在本机安装 OpenSSH Server。

### 4.2 放置脚本

推荐直接使用：

```text
F:\VPS\MXH-VPS-Deploy
```

不要把实例私钥、Token 或运行归档复制进脚本源码目录。源码目录可以进入 Git；实例目录不可以。

### 4.3 先运行项目自检

打开 PowerShell 7：

```powershell
Set-Location 'F:\VPS\MXH-VPS-Deploy'
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
```

正常结尾类似：

```text
Secret scan passed
All tests passed
```

项目自检不会连接 VPS，不会生成真实凭据，也不会修改代理配置。

## 5. VPS 和服务商面板准备

运行向导前记录以下信息：

| 信息 | 示例 | 从哪里获取 |
|---|---|---|
| 服务商名称 | `ExampleProvider` | 自己用于目录分类的名称 |
| 实例名称 | `LAX.Entry.Small` | 套餐/实例名称 |
| 节点名称 | `ExampleProvider-LAX.Entry.Small` | 客户端显示名称，只用字母、数字、点、下划线、连字符 |
| IPv4 | `192.0.2.10` | 服务商面板 |
| IPv6 | `2001:db8::10` 或留空 | 服务商面板和系统实际配置 |
| 当前 SSH 端口 | `22` | 服务商说明或现有登录命令 |
| root 登录方式 | 密码或现有私钥 | 服务商提供 |
| 标称带宽 | `1000 Mbps` | 套餐页面，不是虚拟网卡显示速率 |
| 参考 RTT | `160 ms` | 实际常用地点到入口，或入口到落地的代表性测量 |

### 5.1 服务商安全组需要开放什么

向导生成端口后会显示部署摘要，并在 SSH 迁移前暂停确认。此时打开服务商面板配置：

| 角色 | 部署期间需要的入站规则 |
|---|---|
| 所有正式角色 | 当前 SSH 端口 + SSH 主高位端口 + SSH 救援高位端口，均为 TCP |
| Reality | 再开放 TCP 443 和 Xray 高位救援端口 |
| AnyTLS | 再开放 TCP 443 |
| Shadowsocks 落地 | 再开放落地 TCP+UDP 端口，但来源仅限入口 VPS IP |
| MonitorOnly | 只需要三个 SSH TCP 端口；Komari Agent 不需要公网入站 |
| AuditOnly | 只需要当前 SSH 端口；生成的高位端口不会应用 |

本机 Reality target 的 8443 不开放。Komari Agent 只建立出站连接，也不开放新端口。

如果服务商没有安全组功能，只需确认它没有额外拦截；服务器内的 nftables 仍由脚本配置。

## 6. Cloudflare 与可信 TLS 准备

只有以下两种方案需要本节：

- Reality 本机 HTTPS target；
- AnyTLS + 可信 TLS + ECH。

Reality 外部 target、Shadowsocks、MonitorOnly 和 AuditOnly 不需要 Cloudflare Token。

### 6.1 DNS 记录

所有记录保持“仅 DNS/灰云”和 TTL 自动。

AnyTLS 准备两个不同域名：

| 示例域名 | 用途 |
|---|---|
| `edge-region-a.example.com` | 证书域名和内部 SNI |
| `www-region-a.example.com` | ECH public name |

Reality 本机 target 准备一个域名：

| 示例域名 | 用途 |
|---|---|
| `portal-region-a.example.com` | 本机 HTTPS target 的证书域名/SNI |

A/AAAA 应指向实际部署 VPS。AnyTLS 是直达 VPS 的 TCP/TLS 服务，普通 Cloudflare 橙云 HTTP 代理不适用。Cloudflare 对 DNS-only 与 Proxied 的说明见：[Proxy status](https://developers.cloudflare.com/dns/proxy-status/)。

不需要手工创建 `_acme-challenge` TXT。Certbot 会临时创建并在验证后清理。当前客户端使用静态 ECH config，也不要求手工创建 HTTPS/SVCB ECH 记录。

### 6.2 创建最小权限 API Token

在 Cloudflare 创建自定义 Token：

- `Zone / DNS / Edit`；
- `Zone / Zone / Read`；
- Zone Resources 只包含实际根域名；
- 不使用 Global API Key 或 Origin CA Key；
- 若启用 Client IP Address Filtering，加入运行 Certbot 的 VPS 实际 IPv4 和 IPv6 出口；
- 用于长期自动续期时不要设置短期 TTL。

官方参考：[创建 Cloudflare API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)。

### 6.3 保存 Token 文件

先创建目标实例目录，再用记事本保存：

```text
F:\VPS\VPS-Instances\ExampleProvider\ExampleInstance\cloudflare-certbot-token.private.txt
```

文件只能包含一行 Token：

- 不加引号；
- 不写 `dns_cloudflare_api_token =`；
- 不在前后添加空格或说明；
- 不提交 Git，不发送聊天。

向导会收紧该文件 ACL。正式部署后，本地文件仍应保留用于重装和恢复；服务器上的 `/etc/letsencrypt/cloudflare.ini` 也必须保留给自动续期使用。

如果 VPS IP 变化，应先在 Token 白名单加入新地址并验证续期，再删除旧地址。多台 VPS 长期使用时，按 VPS 分别创建 Token 可以缩小泄漏影响范围。

## 7. Komari 准备

如果需要纳管监控：

1. 登录 Komari 管理后台；
2. 新建节点；
3. 复制该节点 Token；
4. 记录 Komari HTTPS 站点根地址；
5. 等待向导出现隐藏输入提示后再粘贴 Token。

Token 不需要预先写入本地文件，也不会保存在部署计划。部署中断并在 Komari 模块前恢复时，需要重新输入。

脚本部署的 Agent：

- 使用低权限用户；
- 配置文件 0600；
- 不新增公网监听；
- 关闭 Web SSH、远程命令和自动更新；
- 固定版本和下载 SHA-256。

## 8. 第一次运行：推荐流程

### 8.1 双击运行

最简单的方式是双击：

```text
F:\VPS\MXH-VPS-Deploy\Start-VPSDeploy.cmd
```

脚本会打开 PowerShell 7 并显示：

```text
1. 新部署
2. 继续未完成部署
3. 导入/纳管没有 deployment-plan 的现有 VPS
4. 现有 VPS 协议管理（安装/切换/停用/卸载/备份）
5. 现有 VPS 运维中心（恢复/审计/轮换/SSH/防火墙/升级/客户端/Komari/退役）
6. 现有 VPS 独立网络调优（RTT 可选）
7. 项目离线自检
0. 退出
```

第一次选择 `1`。

### 8.2 命令行运行

```powershell
Set-Location 'F:\VPS\MXH-VPS-Deploy'
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode New
```

没有 `deployment-plan.json` 的现有 VPS 使用：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Import
```

已纳管实例进入统一运维中心：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Maintain `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'
```

输入规则：

- 提示后有 `[默认值]` 时，直接按 Enter 接受默认值；
- `Y/n` 表示默认“是”，直接 Enter 即可；
- `y/N` 表示默认“否”，直接 Enter 即可；
- 普通文本和是/否提示输入 `b`，返回上一个当前有效的输入项；
- 编号菜单输入 `0` 或 `b`，返回上一个当前有效的输入项；
- 部署摘要选择“返回修改上一项”，或输入 `0`/`b`，可继续修改；
- 只有整项输入去除首尾空格后恰好等于小写或大写 `b` 才是返回命令；`BreadCloud`、`BandwagonHost` 等以 b 开头的名称仍是正常值；
- 所有普通文本、是/否和编号菜单中，整项输入 `clear` 或 `cls` 会清除当前屏幕并重新显示当前提示；只有精确匹配才触发，`Clearwater` 等名称不受影响；
- SSH 密码和 Komari Token 输入时屏幕不显示字符，这是正常行为。

“当前有效”表示向导会自动跳过与角色无关的字段。例如选择 MonitorOnly 后，从 Komari 项返回会回到端口选择，而不会进入 Reality 或 AnyTLS 字段。回退并改变角色、初始认证方式、Reality target 模式、IPv6 或网络调优开关时，向导会清除新分支不应继承的旧值。

层级导航规则：

- 主菜单输入 `0` 或 `b`：退出脚本；
- 新部署的“VPS 私有归档根目录”输入 `b`：返回主菜单；
- “服务商名称”输入 `b`：返回归档根目录，不会把 `b` 保存为名称；
- “继续未完成部署”的计划路径输入 `b`：返回主菜单；
- Resume 计划摘要输入 `0`/`b`：返回计划路径选择；选择“取消”才返回主菜单；
- 协议管理中的实例、操作或目标协议处输入 `b`/`0`：逐层返回实例选择或主菜单；
- 从命令行直接使用 `-Mode New`、`-Mode Resume` 或 `-Mode Migrate` 时，在最外层返回会正常结束命令，不显示内部异常标记。

## 9. 向导每一项怎么填写

### 9.1 通用信息

#### VPS 私有归档根目录

新部署第一项会显示当前 `-InstanceRoot` 默认值。双击 CMD 或不传参数时为：

```text
F:\VPS\VPS-Instances
```

可以直接 Enter 接受，也可以填写另一个完整绝对路径，例如：

```text
D:\Private-VPS-Archive
```

不允许相对路径，也不允许直接使用 `C:\`、`D:\` 等裸磁盘根目录。显示和填写这一步不会立即创建目录；只有确认部署摘要后才会写入。最终实例目录为：

```text
<归档根目录>\<服务商名称>\<实例名称>
```

命令行传入的 `-InstanceRoot` 只是本次向导的默认值，仍会显示并允许修改。Resume 与协议管理不重新猜测根目录，而是使用所选计划中的 `Paths.Archive`。

#### 服务商名称

用于创建目录，不一定必须等于公司全称，例如：

```text
ExampleProvider
```

不要包含 `\ / : * ? " < > |`。

#### 实例名称

用于实例子目录，例如：

```text
LAX.Entry.Small
```

如果该目录已经有 `deployment-plan.json`，脚本会要求使用 Resume，防止覆盖。

#### 客户端节点名称

显示在 Mihomo/sing-box 中。建议包含服务商、地区、套餐，例如：

```text
ExampleProvider-US.LAX.Entry.Small
```

只允许字母、数字、点、下划线和连字符。

#### IPv4 / IPv6

IPv4 必填。没有确认可用的 IPv6 就留空，不要填写网关、网段或链路本地 `fe80::` 地址。

#### 服务商当前 SSH 端口

填写现在确实可以登录 root 的端口。新装系统通常是 22，但不要凭习惯填写。

#### 初始 root 登录方式

- 选“密码登录”：稍后由 Windows `ssh.exe` 直接询问服务商 root 密码；工具不保存该密码。
- 选“现有私钥登录”：填写私钥文件本身的完整路径，不要填目录或 `.pub` 文件。

私钥带口令时，OpenSSH 会直接询问。脚本不会保存口令。

#### 日常管理用户

通常接受默认 `admin`。不能填写 root。脚本会生成一个随机 sudo 密码，保存到私有归档，但关闭 SSH 密码登录。

### 9.2 端口

新手建议对“是否手动指定高位端口”选择 `n`，让脚本在 20000–59999 中生成不重复端口。

手动填写时必须保证：

- SSH 主、SSH 救援互不相同；
- 不等于当前 SSH 端口；
- Reality 救援端口不等于 443；
- Shadowsocks 落地端口不与 SSH/443 冲突。

端口会先写入计划并显示在摘要中。看到摘要后再打开服务商面板放行即可。

### 9.3 Reality 外部 target

输入纯域名，不带协议和端口：

```text
target.example.com
```

上面只是格式示例，不是正式推荐候选。脚本会从 VPS 执行 TLS 1.3、h2、证书、HTTP、跳转、CDN 特征和 20 次延迟审计。

如果失败：

1. 阅读失败项；
2. 选择立即输入另一个候选；
3. 输入新域名；
4. 脚本重新审计并同步更新 target/SNI。

“强制代理网站流量从 VPS IPv4 出口”通常选择 `y`。只有确认需要双栈自由出口时才选择 `n`。

### 9.4 Reality 本机 target

输入已经准备好的自有域名，例如：

```text
portal-region-a.example.com
```

随后填写：

- Cloudflare Zone 根域名，例如 `example.com`；
- ACME/Let’s Encrypt 联系邮箱；
- 本地 Token 文件完整路径。

不要把 `https://`、路径或端口写入域名字段。

### 9.5 AnyTLS

依次填写两个不同域名：

```text
内部 SNI：edge-region-a.example.com
ECH public name：www-region-a.example.com
```

随后填写 Zone、邮箱和 Token 文件。

Padding 不需要手工输入。脚本创建计划时生成 `PerInstanceConservativeV1`，以后 Resume、重启和更新服务都使用同一方案。客户端会从服务器自动接收，不要在节点中另外复制 padding 数组。

### 9.6 Shadowsocks 落地

“允许连接落地端口的入口 VPS 公网 IP”支持逗号、空格或分号分隔：

```text
192.0.2.20, 192.0.2.21, 2001:db8::20
```

这些必须是入口 VPS 地址，不是客户端当前公网地址。

“客户端链式连接使用的入口组/tag”必须与权威配置中的入口选择组完全相同，例如：

```text
US-West Entry
```

如果名称不一致，生成的 `dialer-proxy`/`detour` 无法找到入口组。

有 IPv6 时会询问是否增加独立 IPv6 出口：

- 只有确认该 IPv6 已配置在服务器且可以出站时选择 `y`；
- IPv6 源地址填写完整单地址；
- 出口接口通常留空；
- 服务商需要专有脚本、策略路由或网络命名空间时，不要用通用模块硬套。

### 9.7 网络调优

套餐标称带宽是必填项，填写服务商套餐页给出的 Mbps；参考 RTT **不是必填项**。没有可靠 RTT 时选择基础保守模式，不需要测速，也不会调整 TCP 缓冲区上限。

只有已经掌握稳定参考值时才选择 BDP 自适应：入口角色的 RTT 是主要使用地到入口 VPS 的典型 RTT；落地角色是常用入口到落地 VPS 的典型 RTT。

落地角色的参考 RTT：常用入口 VPS 到落地 VPS 的典型 RTT。

标称带宽填写套餐值，不填写 `ip link` 显示的虚拟 10G/25G，也不根据一次测速峰值填写。

不要用网卡协商速率或一次测速峰值代替套餐带宽。RTT 不确定时直接接受默认“否”；脚本仍按角色、实际内存和标称带宽分档应用 fq、可用时的 BBR、TCP Fast Open、MTU 探测和保守队列下限。

自适应模式使用 2×BDP，并按实际内存把 TCP 缓冲目标限制在 4/8/16/32 MiB。它不会降低服务器已有的更高值，也不保证改善服务商线路本身。

### 9.8 Komari

需要监控就选择 `y`，确认站点地址正确。模块执行时才会提示输入新节点 Token，粘贴后按 Enter，屏幕不会显示内容。

不需要监控就选择 `n`。

## 10. 确认摘要与正式执行

向导字段填写完成后会先显示部署摘要：

- 实例和角色；
- 当前 SSH → 主/救援 SSH；
- 代理端口、target/SNI 或 AnyTLS 域名；
- 网络调优模式；
- Komari 状态；
- 私有归档路径；

摘要下方可以选择：

1. “确认方案并继续”：接受方案，然后才允许脚本建立实例目录和 `deployment-plan.json`；
2. “返回修改上一项”：回到最后一个当前有效字段，继续使用 `b`/`0` 可逐项向前；
3. “取消本次向导”：直接退出，且不创建部署计划、实例目录或凭据。

先检查：

1. IP、当前 SSH 端口是否正确；
2. 主/救援端口是否互不冲突；
3. 角色是否选对；
4. Reality target 或自有域名是否拼写正确；
5. 私有归档目录是否是目标实例；
6. 服务商安全组是否已准备对应规则。

确认摘要后，脚本会建立可恢复的私有部署计划并列出本次模块顺序。再次回答“确认按以上顺序开始”才会连接 VPS。此处输入 `b` 或选择否会安全返回主菜单（命令行直接模式则结束命令）；已经确认的计划会保留，可稍后使用 Resume 继续。如果想在不留下计划的情况下退出，应在前一个摘要页面选择“取消本次向导”。

回退只覆盖“尚未开始新的远端模块”的规划和最终确认阶段。模块一旦开始，SSH、软件包、防火墙、证书或代理服务可能已经发生有序变更，脚本不会把这些操作伪装成可撤销的上一步。此后的安全确认使用 `y/n`；选择否会停止并保存状态，应按 Resume 流程继续或依据归档回滚。

### 10.1 现有 VPS 协议管理

从主菜单选择 `3`，或运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Migrate `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'
```

`-Mode Migrate` 是为兼容旧命令保留的名称，实际打开“协议生命周期管理器”。实例必须同时满足：

- 已由本工具完成 SSH、防火墙、最终验收、SSH 收口和私有归档；
- 每个记录为已安装的协议都保留成功模块状态；
- `deployment-plan.json`、`deployment-state.json`、`deployment-secrets.private.json` 和实例专用 SSH 私钥仍在原归档；
- 当前管理端口仍是计划中的 SSH 主端口或救援端口；
- 远端实际安装、enabled、active 状态与向导确认时一致；如果有人在确认后手工切换服务，前置审计会拒绝继续。

选中实例后会先只读查询三种协议的真实状态，并显示“已安装 / 已启用 / 运行中”。随后可选择以下操作。

#### 10.1.1 安装新协议并切换使用

只显示尚未安装的协议。目标字段与新部署一致：

- Reality：填写 Xray 救援端口、外部/本机 target、IPv4 出口和必要的可信 TLS 信息；
- AnyTLS：填写内部 SNI、ECH public name、Cloudflare Zone、邮箱和 Token 文件；
- Shadowsocks：填写高位 TCP/UDP 端口、可信入口白名单、客户端入口组和可选 IPv6 出口。

脚本安装目标、临时启用并完成真实测试。最终启用目标；如果目标是 Reality/AnyTLS，另一个 443 入口只会被停止并取消开机启用，二进制、配置、凭据和客户端片段仍保留。安装 Shadowsocks 时，现有入口继续运行，两者可并行。

#### 10.1.2 安装为停用备用

部署和测试过程与上一项相同，但提交时恢复变更前运行状态，新协议保留为完整安装但 disabled/inactive。以后切换不再下载核心、重新签发证书或重新生成凭据。

由于测试阶段必须真正启动目标，服务商安全组仍需临时允许目标端口：Reality 加 TCP 443 和救援端口；AnyTLS 加 TCP 443；Shadowsocks 只对白名单入口加高位 TCP+UDP。测试完成后，脚本会收口 VPS nftables；服务商安全组不会自动修改，应由用户决定是否保留备用端口规则。

#### 10.1.3 切换或启停已安装协议

- 启用 Reality：停用 AnyTLS，启用并启动 Xray；
- 启用 AnyTLS：停用 Xray，启用并启动 `sing-box-anytls`；
- 启用/停用 Shadowsocks：只影响独立高位端口，不改变入口；
- 停用当前 Reality/AnyTLS：允许 TCP 443 暂时没有代理监听，SSH 不受影响。

此操作不重新安装软件，也不轮换 UUID、Reality 密钥、AnyTLS 密码、ECH 或 Shadowsocks 凭据。它仍会重新检查配置、监听、防火墙和可用时的真实客户端出口。

#### 10.1.4 卸载已停用协议

卸载列表只包含同时满足“已安装、未启用、未运行”的协议。活动协议不会出现，远端脚本也会再次拒绝。卸载前必须输入完整的 `UNINSTALL`。

卸载删除该协议的运行时、systemd 单元和服务端配置；当前私有凭据索引及对应客户端片段会移出当前状态，防止继续误用。变更前的凭据和文件仍保存在本次 `migration-backups` 与 VPS 回滚快照中。Certbot/ACME 环境、证书续期框架和历史备份可能被其他已安装协议共享，因此不会随单个协议卸载自动删除。

#### 10.1.5 清理协议变更备份

可以选择仅本地、仅 VPS 或两者，并填写“保留最近 N 份”；`0` 表示删除全部匹配备份。执行前必须输入 `DELETE-BACKUPS`。

- 本地范围严格限制为实例私有归档下的 `migration-backups`，并只匹配本工具的时间戳+操作名目录；手工创建的其他目录不会被删除；
- 远端只匹配 `/root/vps-deploy-backups/<时间戳>/protocol-lifecycle` 和旧版 `protocol-migration` 子目录；
- 不会顺带删除 Xray、证书、SSH、nftables 等其他部署模块的备份；
- 存在未完成协议变更，或 VPS 上回滚 timer 仍 active 时，任何清理都会拒绝；
- 远端保留数设为 `0` 时，会同时移除已经停用且失去备份目标的旧 rollback service/timer/helper；下一次协议变更会重新创建；
- 备份清理本身不可回滚，建议至少保留最近 1–3 份。

#### 10.1.6 Shadowsocks 外部链式测试

新安装 Shadowsocks 时必须选择另一台 Reality/AnyTLS 入口的 `deployment-plan.json`。该入口 IPv4 必须在白名单中，且不能就是当前 VPS。防火墙应用后，脚本会通过该入口运行临时客户端，验证：

```text
可信入口 → 新 Shadowsocks 落地 → HTTPS 出口 + UDP DNS
```

安装、切换、停用或卸载的通用安全顺序：

1. 只读核对本地计划与远端三种协议的 installed/enabled/active 状态；
2. 复验 root/admin 的 SSH 主、救援入口；
3. 在实例 `migration-backups` 保存计划、状态、私有凭据、服务端快照和客户端片段；
4. VPS 端打包全部受管协议文件，记录三个 systemd 服务状态，并备份 nftables/sysctl；
5. 启用独立 `mxh-protocol-migration-rollback.timer`，默认 20 分钟；
6. 执行安装、状态切换或卸载；安装目标时完成 target/证书、TCP/UDP、客户端出口等测试；
7. 先应用测试阶段防火墙并验收，再收口到最终服务组合所需端口；
8. 按最终状态启停服务、撤销回滚 timer，重建包含全部仍安装协议的私有归档与校验和。

任一已武装回滚之后的模块失败时，Windows 端会立即恢复变更前的协议文件、三个服务的 enabled/active 状态、nftables 和网络调优。即使 SSH 暂时不可达，VPS 端计时器仍会独立执行。失败计划记录 `RolledBack` 或 `RollbackPending`；不要创建第二个变更，确认服务恢复后使用“继续未完成部署”重试。

如果状态为 `RollbackPending` 但你仍能通过 SSH 或服务商控制台进入 VPS，可以手动提前触发同一回滚服务：

```bash
sudo systemctl start mxh-protocol-migration-rollback.service
```

不要直接删除 rollback service/timer 文件，也不要在变更前状态尚未恢复时重启或继续下一次操作。

安装或启用 Reality/AnyTLS 时，如果本机找不到可用 Mihomo 核心或真实出口测试未通过，脚本拒绝提交并回滚。新安装 Shadowsocks 时，如果可信入口无法完成链式探测，同样拒绝提交。

### 10.2 独立网络调优

从主菜单选择“现有 VPS 独立网络调优”，或运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode TuneNetwork `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'
```

该流程会读取已纳管实例的实际内存和协议清单。如果入口与 Shadowsocks 同时安装，可选择按哪个主要角色计算队列下限。随后二选一：

- 基础保守：默认，记录套餐标称带宽但不要求 RTT，不调整 TCP 缓冲区上限；
- 已知带宽/RTT 自适应：只有明确掌握两个值时使用 2×BDP，并受内存分级上限约束。

独立调优只运行前置审计、回滚快照、`network-tuning`、服务验收和私有归档，不运行协议安装，也不调用 nftables 应用模块。协议安装/切换本身保持已有网络参数；需要调优时由此入口单独执行。

### 10.3 现有 VPS 统一运维中心

先选择实例的 `deployment-plan.json`。没有计划时必须先用 Import 纳管；纳管不会重装协议或覆盖现有防火墙。运维中心包含九类操作。

#### 10.3.1 手动恢复中心

恢复中心只展示可以成对验证的恢复点：本地必须有当时的计划、状态和私有凭据，远端必须有对应的 `protocol-lifecycle` 快照。选择恢复点后可选：

- 仅配置：恢复 Xray/sing-box/ECH/本机 target 配置，保持当前服务和防火墙状态；
- 完整恢复：同时恢复协议文件、systemd enabled/active、nftables 和脚本管理的 sysctl。

恢复本身也是事务：先备份“现在”，再恢复“过去”；验证失败或选择不保留时恢复到操作前。不要手工填写任意远端路径。

#### 10.3.2 只读健康审计与配置漂移

审计检查有效 SSH、计划内双端口、代理服务 installed/enabled/active、监听、nftables 语法、证书剩余时间、续期/回滚 timer、固定组件版本和受管文件 SHA-256。报告不含配置正文或凭据。

第一次结果为 Healthy 时可建立基线。以后 `CONFIG_HASH_DRIFT` 表示内容发生变化；只有没有严重状态异常、且所有告警都是哈希变化时，才会询问是否把已确认维护结果设为新基线。

#### 10.3.3 凭据轮换

- Reality：生成 UUID、Reality 密钥和 short-id 候选，原子应用后生成客户端并做 Mihomo 真实握手、HTTP 204 和出口测试；
- AnyTLS：默认轮换用户密码，保留证书和 ECH；
- Shadowsocks：默认轮换用户密钥，保留服务器主密钥。

当前只允许轮换正在运行的协议，避免为了改备用凭据意外切换 TCP 443 所有者。旧值只保留在受保护恢复点中，不写普通日志。

#### 10.3.4 SSH 独立维护

可只读审计、轮换实例 Ed25519 密钥，或在受管最小防火墙实例上同时重设双 SSH 端口。候选密钥先加入 root/admin，旧密钥和旧端口暂时保留；所有账号/端口登录成功后才提交。失败立即触发 SSH 专用回滚，VPS 端另有 10 分钟 timer。

#### 10.3.5 防火墙独立维护

`ManagedNftables` 可按当前协议清单重建最小规则，或维护 Shadowsocks TCP/UDP 来源白名单。`PreserveExisting` 默认只审计；如果确定现有规则可以被完整替换，必须输入 `ADOPT-MANAGED-NFT` 才会接管。Docker、面板和第三方复杂规则不要接管。

#### 10.3.6 可控版本升级

sing-box、Komari 等组件只使用 `config/versions.json` 里固定的版本、资产名和 SHA-256。Xray 可选择计划当前版本、当前固定验证版，或从 XTLS/Xray-core 官方 `releases/latest` 解析的最新稳定版；解析结果会固化为精确版本，不会把模糊 `latest` 写进计划。所有分支都先备份，再安装、配置检查、恢复升级前 enabled/active 组合并做健康审计。

#### 10.3.7 客户端权威配置候选

这是为当前实例快速补充节点的兼容入口。填写两份权威文件路径，选择当前实例的已安装协议和地区入口组后生成候选。需要跨多台实例规划地区、落地和业务组时，应从主菜单进入独立设计器。

第一次使用前安装保留注释/顺序的 YAML 依赖：`python -m pip install -r .\requirements-client-merge.txt`。

```text
client-candidates\<时间>\Clash_General.candidate.yaml
client-candidates\<时间>\sing-box-general.candidate.json
client-candidates\<时间>\candidate-manifest.json
```

Clash 候选运行 Mihomo 稳定/Alpha 双核心，sing-box 候选严格解析 JSON。源文件和 AppData 不修改。Shadowsocks 落地的 `dialer-proxy`/`detour` 必须在替换前确认入口组存在。

### 10.4 独立 Clash/sing-box 权威配置候选设计器

从主菜单选择“Clash/sing-box 客户端权威配置候选设计器”，或运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ClientConfig
```

它不连接 VPS，按以下顺序工作：

1. 读取 `config/client-layout.local.json`；不存在时使用受版本控制的 `config/client-layout.default.json`；
2. 选择默认地区入口组，也可新增、重命名或重排地区；
3. 扫描 `-InstanceRoot` 下新旧两种布局的 `deployment-plan.json`，按实例、协议选择需要提取的私有客户端片段；
4. 权威文件里已经存在但没有受管计划的节点可直接按名称复用，无需重新输入凭据；
5. 对尚未存在于权威文件的未纳管 VPS，可手动添加 VLESS Reality、AnyTLS/ECH 或 Shadowsocks 节点；UUID、PublicKey、short-id、密码和 ECH 配置均为隐藏输入；
6. 对每个地区入口组选择实际成员和排序，第一项是首次默认；
7. 选择各个落地节点共用的地区入口，自动同步 Clash `dialer-proxy` 与 sing-box `detour`；
8. 调整 `Default Exit` 以及每个业务组的完整顺序，第一项同样是首次默认；
9. 可把本次地区列表和业务组默认项保存为被 Git 忽略的本机模板；
10. 生成完整候选，拒绝未知 selector 引用、循环引用和无效 detour；运行可用的 Mihomo 双核心并严格解析 sing-box JSON；运行配置使用紧凑 JSON 并硬性拒绝达到 4 MiB 的候选。

候选输出默认位于：

```text
F:\VPS\Client-Authority-Candidates\<时间>\
├─ Clash_General.candidate.yaml
├─ sing-box-general.candidate.json
├─ client-layout-spec.private.json
└─ candidate-manifest.json
```

`client-layout-spec.private.json` 可能含完整节点凭据，只能留在本地私有目录。设计器不会直接写入两份权威文件，也不会修改 Clash Verge AppData。

#### 10.3.8 Komari 完整生命周期

可审计服务，安装/修复 Agent、隐藏输入新 Token、保留原 Token 做固定版本升级、卸载 Agent；Controller 支持私有备份下载、从备份恢复并验证回环监听、按 `versions.json` 固定资产保数据/保启停状态升级、轮换已有 cloudflared Token，以及卸载本机 Controller/Connector。

恢复 Controller 时默认验证后停用，只有明确选择才保持启用；不会自动启动 Tunnel。跨主机迁移仍遵循“新主控恢复并验证 → 用户确认 Cloudflare 外部状态 → 轮换 Connector → 停旧主控”。

#### 10.3.9 完整退役

退役先生成两份“删除本节点”的客户端候选并语法测试，再下载最终受管文件备份。级别依次为：只预检、可恢复停用、删除受管代理/Agent 文件、清除远端恢复点、再包含本机 Controller/Connector。脚本始终保留 SSH 和基础系统，也不会删除服务商实例或云端 Token。

`PreserveExisting` 防火墙不会因退役自动改写；服务停止后应另行检查不再需要的开放端口。永久删除和清理恢复点不可由自动回滚恢复，必须保留本地最终备份。

## 11. 部署过程中会发生什么

### 11.1 建立或复用管理公钥

初始使用服务商 OpenSSH 私钥时，默认不轮换服务器公钥。脚本把同一把私钥复制到规范路径，并从私钥重新推导 `.pub`：

```text
实例目录\MXH-VPS-Deploy\ssh\id_vps_management
实例目录\MXH-VPS-Deploy\ssh\id_vps_management.pub
```

原始私钥不改名、不删除，服务商面板提供的密钥与服务器实际授权关系保持一致。支持 Ed25519、RSA 和常用 ECDSA OpenSSH 私钥；带口令私钥不适合后续无交互维护，应选择生成新管理密钥或自行配置 `ssh-agent`。

初始只有密码，或人工选择生成新密钥时，脚本创建：

```text
实例目录\MXH-VPS-Deploy\ssh\id_ed25519
实例目录\MXH-VPS-Deploy\ssh\id_ed25519.pub
```

新公钥先加入 root，完成登录复验后才用于后续模块；原有公钥不会因引导过程被删除。

### 11.2 初始审计

记录系统、架构、内核、内存、磁盘、监听、SSH 生效值、既有服务和 nftables。

检测到不干净环境时，正式角色会停止。不要为了继续而删除审计结果或状态文件。

### 11.3 创建 admin

安装基础工具、配置时间同步，创建 admin、公钥和 sudo。脚本验证：

- root 公钥登录；
- admin 公钥登录；
- admin sudo。

### 11.4 SSH 过渡

脚本暂停并提示确认服务商安全组。确认后，sshd 同时监听：

- 服务商初始端口；
- SSH 主高位端口；
- SSH 救援高位端口。

两个新端口都会从全新连接验证 root、admin 和 sudo。初始端口仍保留。

### 11.5 角色服务

- Reality 外部 target：审计 target，安装所选的固定验证版或官方最新稳定版 Xray，生成凭据，部署主/救援入口；
- Reality 本机 target：签发证书，部署回环 nginx，再部署 Xray；
- AnyTLS：签发证书、生成 ECH 和 padding，部署低权限 sing-box；
- Shadowsocks：生成 SS2022 服务端/用户密钥，部署 TCP+UDP 落地并自测；
- MonitorOnly：跳过代理协议；
- AuditOnly：在审计后结束。

### 11.6 nftables、Komari 和客户端导出

服务器 nftables 先保留三个 SSH 端口。Shadowsocks 端口按入口 IP 白名单限制 TCP/UDP。

Komari 启用时安装低权限 Agent。随后生成角色对应的客户端私有片段。

### 11.7 最终验证和 SSH 收口

脚本验证服务、监听、配置、SSH、sudo、防火墙和协议功能。若本机存在默认路径中的 Mihomo，还会启动临时本地核心检查 HTTP 204 和出口 IP。

最终收口前会再次询问。远端先创建 5 分钟 SSH 自动回滚，然后临时移除初始 SSH 端口：

1. 验证主、救援端口的 root/admin/sudo；
2. 成功后取消自动回滚；
3. 再从 nftables 移除初始端口；
4. 最后重新验证两个高位端口。

收口期间不要重启 VPS。重启可能使临时 5 分钟回滚任务失效。如果新连接验证失败，保持服务商控制台可用并等待自动恢复。

## 12. 部署成功后会生成哪些文件

典型目录：

```text
F:\VPS\VPS-Instances\ExampleProvider\ExampleInstance\
├─ 服务商原始资料、账单或 Token 文件       # 用户已有文件，工具不整理或覆盖
└─ MXH-VPS-Deploy\
   ├─ deployment-plan.json
   ├─ deployment-state.json
   ├─ deployment-secrets.private.json
   ├─ deployment.log
   ├─ initial-audit.json
   ├─ target-audit.json                # 仅外部 Reality target
   ├─ NODE-final-archive.txt           # AuditOnly 不生成
   ├─ SHA256SUMS-private.txt
   ├─ ssh\
   │  ├─ id_vps_management 或 id_ed25519
   │  └─ 对应 .pub
   ├─ client-exports\
   └─ server-configs\
```

旧版本直接把 `deployment-plan.json` 放在实例根目录的布局仍可读取和维护；脚本不会强制搬迁旧归档。新部署和新纳管统一使用上面的子目录，避免和服务商原始文件混在一起。

主要文件作用：

| 文件 | 作用 | 是否敏感 |
|---|---|---|
| `deployment-plan.json` | 输入、角色、端口、域名、Token 文件路径 | 私有基础设施信息 |
| `deployment-state.json` | 模块成功/失败、当前管理端口、验证结果 | 私有 |
| `deployment-secrets.private.json` | admin 密码、协议密钥 | 高度敏感 |
| `deployment.log` | 已脱敏模块日志 | 仍按私有文件处理 |
| `initial-audit.json` | 初始系统审计 | 私有 |
| `target-audit.json` | target 实测结果 | 私有 |
| `*-final-archive.txt` | 登录、服务、凭据、回滚目录总表 | 高度敏感 |
| `client-exports` | Mihomo 测试 YAML、sing-box 出站片段 | 高度敏感 |
| `server-configs` | 下载的服务器配置和证书快照 | 高度敏感 |
| `SHA256SUMS-private.txt` | 归档文件校验和快照 | 私有；不能替代加密和离线备份 |

不要只备份 `final-archive.txt` 而丢掉密钥目录、计划和状态。推荐加密备份整个实例目录。

## 13. 客户端文件怎么用

### 13.1 Reality

`client-exports` 中包含：

- `mihomo-test-primary.yaml`：正式 443；
- `mihomo-test-backup.yaml`：Xray 高位救援端口；
- `sing-box-outbounds.private.json`：仅出站片段，不是完整 profile。

可以先单独导入 Mihomo 测试 YAML 验证。救援节点不需要长期放进主配置，只在 443 局部受限时临时使用。

### 13.2 AnyTLS

包含：

- `mihomo-anytls-test.yaml`；
- `sing-box-anytls-outbounds.private.json`；
- `ech-client-config.pem`；
- 私有说明文件。

Mihomo 使用 `ech-opts.config`，sing-box 使用 `tls.ech.config`。证书验证保持开启，padding 由服务端自动下发。

### 13.3 Shadowsocks 落地

包含：

- `mihomo-shadowsocks-test.yaml`；
- `sing-box-shadowsocks-outbounds.private.json`；
- 链式关系说明。

Mihomo 使用 `dialer-proxy`，sing-box 使用 `detour`。它们引用的入口组/tag 必须存在于权威主配置中。

### 13.4 权威配置规则

工具只生成实例片段：

- 不修改 Clash Verge AppData；
- 不自动修改 `F:\VPS\Clash YAML\Clash_General.yaml`；
- 不自动修改 `F:\VPS\Sing-box Config\sing-box-general.json`。

合并到多节点主配置前，应审计名称、组关系、首命中规则和链式出口，并重新跑双 Mihomo 核心或 sing-box 核心检查。

Clash/MXH Route/sing-box 可以同时安装，但不要让两个程序同时控制系统代理或 TUN。

## 14. 部署后人工验收清单

### 14.1 SSH

根据私有归档设置变量：

```powershell
$vpsIp = '192.0.2.10'
$sshPrimary = 30001
$sshRescue = 30002
$keyPath = 'F:\VPS\VPS-Instances\ExampleProvider\ExampleInstance\MXH-VPS-Deploy\ssh\id_ed25519'

ssh -i $keyPath -p $sshPrimary "admin@$vpsIp"
ssh -i $keyPath -p $sshRescue "admin@$vpsIp"
```

登录后执行：

```bash
sudo -v
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '
sudo systemctl is-active ssh nftables systemd-timesyncd
```

不要删除救援 SSH 端口。

### 14.2 Reality

```bash
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager
sudo ss -lntp
```

客户端分别测试主、救援端口：

- Reality Authentication 成功；
- HTTP 204；
- 出口 IP 正确；
- IPv6 节点只在客户端具有可用 IPv6 网络时测试。

### 14.3 AnyTLS

```bash
sudo /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json
sudo systemctl status sing-box-anytls --no-pager
sudo systemctl status mxh-certbot-renew.timer --no-pager
sudo certbot certificates
```

客户端验证：

- 证书验证开启；
- ECH 节点可连接；
- HTTP 204 和出口 IP；
- TCP 与 UDP 功能；
- Xray 没有同时运行。

### 14.4 Reality 本机 target

```bash
sudo systemctl status xray nginx mxh-certbot-renew.timer --no-pager
sudo ss -lntp
```

确认 nginx 只监听回环 8443，不监听公网 80/443；公网 443 应由 Xray 监听。

### 14.5 Shadowsocks 落地

```bash
sudo /usr/local/bin/sing-box check -c /etc/sing-box/config.json
sudo systemctl status sing-box --no-pager
sudo nft list ruleset
```

除了服务器本机自测，还必须从入口节点测试完整链路。普通客户端或家宽 IP 不能直接访问落地端口。

### 14.6 Komari

在 Komari 首页确认：

- 节点在线；
- CPU、内存、磁盘和流量正常；
- 没有开放新的 Agent 公网端口；
- Web SSH/远程命令保持关闭。

## 15. 部署失败后如何继续

脚本每个模块都会记录 `Running`、`Success` 或 `Failed`。失败后停止后续模块，不会自动连续修改其他层。

### 15.1 最简单的恢复方式

再次双击 `Start-VPSDeploy.cmd`，选择“继续未完成部署”，粘贴：

```text
F:\VPS\VPS-Instances\服务商\实例名\MXH-VPS-Deploy\deployment-plan.json
```

或运行：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Resume `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例名\MXH-VPS-Deploy\deployment-plan.json'
```

Resume 会跳过状态为 `Success` 的模块，从失败或未完成模块继续。凭据、端口、ECH 和 padding 不会无故轮换。

不要：

- 对同一实例重新选择“新部署”；
- 删除 `deployment-state.json` 试图强制重来；
- 在部署中途移动或重命名实例目录；
- 手工编辑 `deployment-secrets.private.json`；
- 因为某一步失败就立即关闭旧 SSH 或重启 VPS。

### 15.2 常见错误

#### 找不到 `pwsh.exe`

安装 PowerShell 7。Windows PowerShell 5.1 的 `powershell.exe` 不满足要求。

#### 找不到 `ssh.exe`、`scp.exe` 或 `ssh-keygen.exe`

安装 Windows OpenSSH Client，然后重新打开终端。

#### 私钥 `Access is denied`

确认当前 Windows 登录用户就是创建归档的用户。不要为方便把整个实例目录开放给 `Everyone`。

#### `REMOTE HOST IDENTIFICATION HAS CHANGED`

可能是 VPS 重装、IP 被重新分配，也可能是中间人风险。先在服务商控制台核实实例确实重装，再只删除对应 IP/端口的旧 known_hosts 记录，不要全量清空 known_hosts。

#### 初始密码输入后失败

检查：

- 账号是否必须为 root；
- 当前 SSH 端口是否正确；
- 服务商是否禁用密码登录；
- 是否应该选择“现有私钥登录”；
- 服务商安全组是否允许当前来源访问初始端口。

#### 新 SSH 高位端口连接失败

不要关闭初始端口。检查服务商安全组是否放行两个 TCP 高位端口，然后 Resume。

#### 审计提示已有服务或 nftables

这是安全停止，不是脚本故障。不要强行继续；重装干净系统或单独设计迁移。

#### Reality target 不合格

先阅读屏幕和 `target-audit.json` 中的 TLS、h2、证书、跳转、CDN、失败次数及延迟结果，默认换一个大学、机构或企业候选。确有现场依据时可以输入 `ACCEPT-TARGET-RISK` 并记录原因；这不会跳过真实 Reality 握手和出口测试。

#### Cloudflare Token/Certbot 失败

检查：

- Token 文件是否只有一行；
- Zone 是否正确；
- 是否同时具有 `DNS:Edit` 和 `Zone:Read`；
- Token 是否只授权了另一个 Zone；
- Client IP 白名单是否包含 VPS 当前 IPv4/IPv6 出口；
- DNS 名称是否属于该 Zone；
- 是否频繁重复签发触发 CA 速率限制。

修正后 Resume，不要在错误未定位时反复删除 `/etc/letsencrypt`。

#### BBR 未启用

如果只有“内核未提供 BBR”警告，部署不会因此失败。脚本仍保留 fq 和其他基础参数。

#### 未找到 Mihomo 核心

客户端片段仍会生成，但自动语法/出口测试会跳过。安装 Clash Verge 默认路径后手工测试，或使用对应核心检查。

#### 最终 SSH 收口失败

不要重启。等待最多 5 分钟让远端恢复初始 sshd 配置，然后用原入口或服务商控制台检查。成功恢复后再 Resume。

## 16. 维护模式与高级参数

新手不要使用 `-OnlyModule`。它只运行你明确列出的模块，不会自动补跑依赖，也不会检查所有前置状态。

格式：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Resume `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json' `
  -OnlyModule 'final-validation'
```

使用前必须确认模块依赖、当前服务、管理端口和备份。特别注意：

- 单独运行 target audit 不会自动部署 Xray；
- 单独运行客户端导出要求服务器凭据和前置状态已经存在；
- 单独运行 final validation 要求服务、防火墙和客户端导出均完成；
- 单独运行 SSH cutover 风险最高，不应作为跳过前序步骤的捷径。

### 16.1 DryRun

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode New -DryRun
```

DryRun 仍会询问计划字段，并检查填写的 Token 文件是否存在，但不会连接 VPS、创建实例目录、生成真实凭据或改文件。

预览现有实例的协议生命周期操作：

```powershell
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode Migrate -DryRun `
  -PlanPath 'F:\VPS\VPS-Instances\服务商\实例\MXH-VPS-Deploy\deployment-plan.json'
```

协议管理 DryRun 会使用本地计划/状态推导协议清单，验证目标字段并显示专用模块列表，但不会连接 VPS、创建变更备份或覆盖当前计划。备份清理的 DryRun 只计算本地候选数量，不删除本地或远端目录。

### 16.2 NonInteractive

`-NonInteractive` 主要用于已有完整计划的受控自动化：

- 不会代替你回答新部署向导；
- 初始密码无法非交互输入；
- 带口令的服务商私钥无法询问口令；
- Komari Token 必须交互输入，因此启用 Komari 时会停止；
- 会跳过部分人工确认，不适合第一次部署。

## 17. 更新脚本

sing-box、Komari 继续使用 `versions.json` 固定资产和 SHA-256，不会因为上游发布新版本自动升级服务器。Xray 新部署和受控升级可在两种通道中选择：

- `FixedVerified`：项目当前固定验证版，默认且更稳妥；
- `LatestStable`：实时读取 XTLS/Xray-core 官方 `releases/latest`，拒绝草稿和预发行标签，并把解析出的精确版本写入计划。

两种 Xray 通道都使用项目锁定并校验 SHA-256 的官方安装脚本提交；“最新稳定版”不是每次运行都漂移的模糊值。离线或 GitHub 不可达时应返回选择固定验证版。

只检查上游版本：

```powershell
pwsh -NoProfile -File .\scripts\Check-UpstreamVersions.ps1
```

更新 Git 仓库前：

```powershell
Set-Location 'F:\VPS\MXH-VPS-Deploy'
git status --short
```

如果输出有本地修改，先停止，不要直接覆盖。工作树干净时：

```powershell
git pull --ff-only
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
```

不要在某台 VPS 正处于中断部署时随意升级脚本。先备份实例目录，并阅读 `CHANGELOG.md` 是否改变计划结构、服务配置或维护流程。

## 18. 卸载、迁移和停用 VPS

统一运维中心已经提供分级退役，但它不会替代云端和服务商操作。退役前仍应：

1. 从权威 Clash/sing-box 配置移除节点；
2. 如果是落地机，从入口组和防火墙白名单移除关系；
3. 如果使用自有域名，把 A/AAAA 更新到新主机或删除，不能留下指向已释放 IP 的悬空记录；
4. 如果使用 Certbot Token IP 白名单，先让新机签发/续期成功，再删除旧机地址；
5. 迁移 Komari 后确认新主控、Agent、数据库和 Tunnel，再停旧机；
6. 保存需要的私有归档和服务端备份；
7. 在服务商面板销毁实例前，确认没有唯一副本仍留在服务器。

Token 未泄漏且仍用于其他证书时无需轮换；不再使用时应在 Cloudflare 删除或吊销。

## 19. 已知测试边界

已经完成的主要验证包括：

- Debian 13 x86_64、服务商现有私钥的完整 Reality 新机部署；
- 双高位 SSH、admin/sudo、nftables、网络调优、Komari、归档和最终收口；
- Shadowsocks 2022 TCP/UDP、IPv4/IPv6 用户和外部入口测试；
- Certbot DNS-01、模拟续期、Reality 本机 target；
- AnyTLS 可信 TLS、ECH、TCP/UDP、远程客户端出口；
- 每实例 padding 与 Mihomo 稳定版/Alpha 运行兼容；
- Reality、AnyTLS、Shadowsocks 的六个安装方向，以及安装为备用、启停切换、活动协议拒绝卸载、并行入口+落地防火墙和备份清理边界的离线测试；
- `clear`/`cls`、跨层返回、摘要取消和协议管理向导的真实交互 DryRun；
- 旧 DMIT 实机完成健康基线、凭据轮换后的哈希漂移识别、成对完整恢复、Reality 真实握手、Xray/Komari 固定版本重装、root/admin 双端口 SSH 密钥轮换、权威候选双核心验证、Controller 备份/恢复和可恢复退役；
- 现有 OpenSSH 私钥复用的本地实测：私钥内容与 SHA-256 不变，原文件不改名，规范副本可推导相同公钥；
- 独立客户端设计器的受管片段、手动落地、地区/业务组顺序、selector default、dialer-proxy/detour 同步、未知引用和循环拒绝测试；
- Xray 固定验证版和可注入官方 latest 精确版本解析分支；
- 项目离线断言、秘密扫描、固定核心解析和 ShellCheck。

尚未覆盖所有系统和故障排列组合，包括：

- root 初始密码方式的完整长期生产部署；
- Ubuntu/ARM64 的同等级现场覆盖；
- 真实生产 VPS 上首次使用官方最新稳定版 Xray 的完整握手回归（代码与安装路径已覆盖，仍需在非关键实例先验收）；
- MonitorOnly/AuditOnly 的所有服务商组合；
- 等待证书自然到期后的真实定时续期；
- 所有故意破坏后的自动回滚分支。
- 新增的安装为备用、所有启停组合、三个卸载方向和备份清理尚未全部在真实生产 VPS 上逐一执行；当前远端脚本已通过 Bash 语法、状态规划、防火墙生成和回滚结构测试，首次实机使用仍必须保留控制台并观察回滚计时器。
- AnyTLS/SS 凭据轮换、SSH 端口变更、`PreserveExisting` 到受管 nftables 的实际加载、Cloudflare Tunnel Token 轮换，以及清除远端恢复点的永久退役分支尚未在旧 DMIT 实机执行；防火墙候选已在 VPS 端 `nft -c` check-only 通过，破坏性分支只做离线测试。

因此脚本仍应按分阶段、保留旧入口、保持服务商控制台可用的方式使用，不能把“自动化”理解为“无需验收”。详细变更和现场证据见项目根目录 `CHANGELOG.md`。

## 20. 一页快速清单

### 部署前

- [ ] 干净 Debian/Ubuntu VPS；
- [ ] root 当前入口可以登录；
- [ ] 记录 IPv4/IPv6、当前 SSH 端口和认证方式；
- [ ] 服务商控制台/VNC 可用；
- [ ] PowerShell 7 和 OpenSSH Client 可用；
- [ ] 项目 `ValidateProject` 通过；
- [ ] 选择正确角色；
- [ ] Reality 外部 target 已准备，或 Cloudflare DNS/Token 已准备；
- [ ] Shadowsocks 已收集所有入口 VPS IP；
- [ ] Komari 新节点 Token 已准备；
- [ ] 确认本地实例目录不会进入公开 Git。

### 部署中

- [ ] 检查摘要中的 IP、端口、域名和归档目录；
- [ ] 在服务商安全组放行主/救援 SSH 和角色端口；
- [ ] 不关闭初始 SSH；
- [ ] 不关闭终端或随意重启 VPS；
- [ ] target、证书、ECH、TCP/UDP 和出口验证无错误；
- [ ] 最终收口前确认两个 SSH 高位端口都能新建连接。

### 部署后

- [ ] root/admin 在主、救援 SSH 均可用；
- [ ] admin sudo 正常；
- [ ] 服务与 nftables active；
- [ ] 客户端 HTTP 204 和出口 IP 正确；
- [ ] Komari 节点在线；
- [ ] Certbot timer active（如适用）；
- [ ] 服务商安全组删除初始 SSH 规则；
- [ ] 整个实例目录完成加密备份；
- [ ] 权威客户端配置经过独立审计后再合并。

## 21. 进一步阅读

- [项目 README](../README.md)
- [安全模型](SECURITY.md)
- [模块设计与维护](MODULES.md)
- [版本与变更记录](../CHANGELOG.md)
- [PowerShell 7 Windows 安装说明](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows)
- [Windows OpenSSH 安装说明](https://learn.microsoft.com/windows-server/administration/openssh/openssh_install_firstuse)
- [Cloudflare API Token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Cloudflare DNS Proxy Status](https://developers.cloudflare.com/dns/proxy-status/)
- [sing-box AnyTLS 入站文档](https://sing-box.sagernet.org/configuration/inbound/anytls/)
