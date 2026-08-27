# Changelog

## Unreleased

- 新部署和 Import 的运行产物统一进入 `<实例>\MXH-VPS-Deploy`；旧版实例根目录计划仍保持兼容，不执行强制搬迁。
- 现有 OpenSSH 私钥默认复制为 `ssh\id_vps_management` 并复用同一公钥，原文件与服务商面板关系不变；只有密码引导或人工选择时才生成新 Ed25519。
- Import 的 SSH 认证策略改为显式选择：默认保持现状，可选 key-only；不再把“纳管”与“强制轮换密钥/关闭密码”绑定。
- 网络调优改为标称带宽必填、RTT 可选；基础模式按角色、实际内存和带宽分档选择保守队列，不设置 TCP 缓冲上限。
- 新增独立 `ClientConfig` 模式、可版本控制的基础布局和本机覆盖模板；支持多实例私有片段提取、未纳管节点隐藏输入、地区/落地/业务组排序与默认值、selector 引用/循环检查及 dialer-proxy/detour 同步。
- 客户端合并器对 sing-box 运行配置使用紧凑 JSON，并在 4 MiB 前硬性停止；完整权威回放从约 4.94 MiB 降至约 2.44 MiB，避免桌面端 IPC 导入失败。
- Xray 新部署、协议补充和受控升级同时支持 `FixedVerified` 与官方 `LatestStable` 通道；latest 会解析并固化具体非预发行版本。
- Windows 本地 ACL 默认改为尽力收紧并明确警告；设置 `MXH_VPS_STRICT_LOCAL_ACL=1` 可恢复硬失败策略。远端秘密、回滚和 Git 防泄漏边界不放宽。
- 修复 GitHub Actions：Windows runner 先安装固定 YAML 依赖；Linux ShellCheck 修正 Komari trap 状态变量和恢复脚本递归删除保护。
- 新增统一 `Maintain` 运维中心：手动恢复、健康/漂移审计、协议凭据轮换、SSH/防火墙独立维护、固定资产升级、客户端权威候选合并、Komari 生命周期和分级退役。
- 健康报告只保存脱敏状态和配置 SHA-256；支持建立基线、发现计划外哈希变化，并只在纯哈希变化且人工确认时更新基线。
- 手动恢复中心把本地计划/状态/凭据与远端 `protocol-lifecycle` 快照成对展示；恢复前再次快照，支持仅配置或完整服务/防火墙/sysctl 恢复。
- Reality、AnyTLS 和 Shadowsocks 凭据轮换现在先生成候选、应用回滚保护、导出客户端并完成真实测试；提交后同步私有服务端快照。
- SSH 独立维护支持实例 Ed25519 密钥轮换及受管双端口重设；旧入口/旧公钥在 root/admin 全部验证前保留，并有独立 10 分钟回滚。
- 防火墙独立维护默认保留未知规则；显式接管受管最小 nftables 需要确认短语，支持 Shadowsocks 白名单维护和 check-only 预检。
- 可控版本升级恢复升级前 enabled/active 状态；sing-box/Komari 使用 `versions.json` 固定资产，Xray 额外支持解析并固化官方最新稳定版。
- 新增基于 ruamel.yaml 的 Clash/sing-box 权威配置候选引擎，保留源文件、只生成候选，并支持退役节点删除候选。
- Komari 支持 Agent 安装/修复/Token 轮换/保状态升级/卸载，以及 Controller 状态、备份、恢复、Tunnel Token 轮换和卸载。
- 分级退役会先生成客户端删除候选和下载最终备份；可选择仅停用、删除受管文件、清理远端恢复点或连同本机 Controller/Connector 退役，始终保留 SSH 与系统。
- 旧 DMIT 实机验收修复 Xray 26.3.27 `x25519` 的 `Password (PublicKey)` 字段兼容、无扩展名临时 Xray 配置无法识别格式、历史 ACL 文件阻断校验和，以及 `authorized_keys` 无末尾换行导致新密钥粘连。

- 新部署向导将 VPS 私有归档根目录提升为第一项，显示 `-InstanceRoot` 当前默认值并允许输入其他绝对路径；摘要确认前不创建目录。
- 归档根目录拒绝相对路径和裸磁盘根目录；新计划路径固定为 `<根目录>\<服务商>\<实例>\MXH-VPS-Deploy`，Resume/迁移继续兼容计划内的旧 `Paths.Archive`。
- 将“现有 VPS 协议迁移/维护”升级为协议生命周期管理：Reality、AnyTLS、Shadowsocks 支持安装并启用、安装为停用备用、启用/停用、切换和安全卸载。
- 新增 `ProtocolInventory`，分别记录 installed/enabled/active；Reality 与 AnyTLS 可同时安装但只能一个启用，Shadowsocks 可与入口协议并行运行。
- 变更前在本地备份计划、状态、凭据、服务端快照和客户端片段，并验证计划 SHA-256；VPS 端打包全部受管协议文件，记录三个 systemd 服务状态及 nftables/sysctl。
- 20 分钟独立回滚现在恢复变更前的全部协议文件、服务 enabled/active 状态、防火墙和网络调优，不再只恢复单一源角色。
- 安装为备用仍会临时切换并完成真实测试，然后恢复原状态；Reality/AnyTLS 必须通过 Mihomo 出口测试，新增 Shadowsocks 必须从白名单入口完成 TCP、UDP 和出口链式探测。
- 卸载只允许 disabled/inactive 协议，移除运行时、systemd 单元、服务端配置、当前凭据索引和客户端片段；共享 Certbot/ACME 环境与回滚备份保留。
- 新增受限备份清理：本地、远端或同时清理，支持保留最近 N 份；只匹配本工具协议备份，活动回滚或未完成变更期间拒绝删除。
- 新增 `Import` 模式：没有 `deployment-plan.json` 的既有标准 Reality/AnyTLS/Shadowsocks VPS 可复用现有 OpenSSH 密钥或生成新密钥，自选保持 SSH 认证或 key-only，并解析现有私有配置生成受管计划；代理端口和现有防火墙保持不变。
- 导入实例使用 `PreserveExisting` 防火墙模式；Reality/AnyTLS 可在既有 443 上管理，新增 Shadowsocks 高位端口时拒绝自动覆盖未知规则。
- 新增独立 `TuneNetwork` 模式；协议生命周期操作不再隐式重跑网络调优。默认 `BaselineOnly` 不要求 RTT，只有显式选择 BDP 自适应时才询问带宽和 RTT。
- Reality target 自动审计失败时展示完整结果，允许交互式输入 `ACCEPT-TARGET-RISK` 并记录原因后人工覆写；非交互模式禁止，真实握手/出口验收仍不可跳过。
- 修复主菜单同时显示编号“退出”和 `0. 退出` 的重复项；现在只保留统一的 `0. 退出`。
- 所有普通文本、是非和编号菜单新增精确匹配的 `clear`/`cls` 清屏命令；`Clearwater` 等前缀相同的正常值不受影响。
- 修复最终归档先计算校验和、后写入最新计划/状态导致校验和立即过期的问题。
- 补齐跨层级导航：新部署第一项可返回主菜单，Resume 路径可返回主菜单，Resume 摘要可重选计划，主菜单 `0` 可退出，离线自检完成后回到主菜单。
- 修复第一项把 `b` 当成服务商名称并保存为默认值、Resume 路径无法退出、摘要取消以异常暂停窗口等交互缺陷；带引号的计划路径现在可正常解析。
- 正式远端模块开始前的最后确认也支持安全返回/取消；本地已确认计划会保留供 Resume，远端模块开始后不提供伪回退。
- 新部署向导新增完整的上一步导航：文本/是非输入支持 `b`，编号菜单支持 `0`/`b`，部署摘要支持返回修改或无写入取消。
- 向导改为条件状态机；回退后改变角色、初始认证、Reality target 模式、IPv6 或网络调优选择时，会清理不再适用的分支参数并重新核对摘要。
- 新增交互式 DryRun 回归测试，覆盖文本回退、菜单回退、摘要回退、答案替换以及不写入实例归档。
- 修复外部 Reality target 重新选择后只更新候选名、未同步 `ServerName` 和 `TargetAddress` 的问题。
- 明确 `AuditOnly` 会建立实例专用 SSH 公钥后执行审计，而不是完全零写入。
- 新增面向首次使用者的中文完整手册，覆盖环境准备、角色选择、向导字段、恢复、验收和停用流程。

## 0.4.0

- 新增 `AnyTlsEntry` 角色，使用独立低权限 sing-box 服务部署 AnyTLS、公共 CA 可信 TLS 和 ECH。
- 新增 Cloudflare DNS-01 Certbot 签发、两次每日 systemd 自动续期和证书部署 hook。
- Reality 入口新增外部严格审计 target 与自有域名本机 HTTPS target 两种模式。
- AnyTLS 与 Xray 通过 systemd `Conflicts` 强制互斥，避免同时占用 TCP 443。
- AnyTLS 低权限服务仅授予绑定 443 所需的 `CAP_NET_BIND_SERVICE`，并保留路由订阅所需 `AF_NETLINK`。
- AnyTLS 服务器直连出站不启用接口自动探测，TCP/UDP 功能测试均可在不授予 `CAP_NET_RAW` 的条件下通过；切换失败会恢复原 Xray 状态。
- 新部署为每台实例生成并持久化保守的独立 AnyTLS padding scheme；旧计划显式回退到官方默认，客户端通过协议自动接收而无需重复配置。
- 关闭发行版重复的 `certbot.timer`，只保留带证书部署 hook 的专用续期计时器。
- 新增 sing-box/Mihomo AnyTLS+ECH 客户端片段、TCP/UDP、证书、ECH 和真实出口验证。
- 已在 Debian 13 既有 Xray 主机完成 Certbot DNS-01、模拟续期、本机 HTTPS target、Reality 主/救援入口、AnyTLS TCP/UDP/ECH 与远程客户端集成测试；清理后 SSH、Xray、nftables 配置校验和保持不变。

## 0.3.1

- 将 Shadowsocks 落地自测从“TCP 真实出口 + UDP 监听检查”提升为 TCP、UDP 双协议真实功能测试。
- UDP 自测通过临时本地隧道发送 DNS 报文，经 SS2022 转发后校验响应，不再把端口监听等同于 UDP 可用。
- 部署状态和最终私有归档会分别记录主 IPv4 用户及可选 IPv6 用户的 UDP 验证结果。
- 增加使用固定版本和固定 SHA-256 临时核心的外部入口探针，用于上线前验证真实远程 TCP/UDP，而不在入口 VPS 留下客户端程序或配置。
- 修复 systemd `RestrictAddressFamilies` 缺少 `AF_NETLINK`，导致启用 `auto_detect_interface` 的 sing-box 通过语法检查却无法启动的问题。
- 已在 Debian 13 的既有 Xray 主机上完成一次性集成验证：服务端与远程可信入口的 IPv4/IPv6 用户均通过 TCP、UDP 和出口族检查，卸载后原 SSH、Xray、nftables 配置校验和保持不变。

## 0.3.0

- 新增按部署角色、实际内存、用户填写的标称带宽与代表性 RTT 计算的保守自适应网络调优。
- 使用 2×BDP，并按 512 MiB/1 GiB/2 GiB/更大内存限制在 4/8/16/32 MiB 内。
- 仅提高不足的缓冲区和队列下限；已有值超过保守上限时保留而不覆盖。
- 兼容旧部署计划：交互继续时补充输入，非交互继续时退回基础保守项。
- 在部署状态和最终私有归档中记录输入、计算目标、实际应用结果和回滚目录。

## 0.2.1

- 修复 Windows 端远程脚本参数前导段混入 CRLF，导致 Bash 把 `pipefail\r` 识别为无效选项的问题。
- 固化 Xray 单条路由规则为 JSON 数组，并增加服务端配置往返回归测试。
- 修复 nftables 在 `pipefail` 下使用 `grep -q` 触发 SIGPIPE 后误报端口缺失的问题。
- 修复从 `ValidateProject` 入口运行测试时重复强制导入核心模块、破坏测试作用域的问题。
- 增加远程载荷 LF、Xray 路由数组和 nftables 验证方式的回归断言。

## 0.2.0

- 新增独立 `ShadowsocksLanding` 部署角色。
- 固定 sing-box 1.13.19，部署 SS2022 多用户 TCP+UDP 服务。
- nftables 按可信入口 IPv4/IPv6 限制落地端口来源。
- 支持可选的第二 IPv6 出口用户，并生成 Mihomo/sing-box 链式私有片段。
- 增加服务端回环认证、出口测试和最终配置归档。

## 0.1.1

- 新增 DMIT 等 key-only 模板的现有服务商私钥引导方式。
- 引导成功后统一切换到工具生成的实例专用密钥，保持 SSH 密码登录关闭。

## 0.1.0

- 首个中文交互式模块化版本。
- Reality 入口、双高位 SSH、target 审计、Xray 26.3.27、nftables、BBR/fq、Komari Agent、客户端片段和私有归档。
