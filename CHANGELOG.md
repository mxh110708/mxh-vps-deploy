# Changelog

## Unreleased

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
