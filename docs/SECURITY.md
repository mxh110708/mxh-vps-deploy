# 安全模型

## 1. 信任边界

源码仓库只包含通用逻辑和占位符。真实 IP、端口、UUID、short-id、Reality PrivateKey、AnyTLS 密码、TLS 私钥、ECH 服务端密钥、客户端密钥、SSH 私钥、密码、Cloudflare/Komari Token 与完整客户端配置都属于实例私有数据。

默认私有归档：

```text
F:\VPS\VPS-Instances\<Provider>\<Instance>
```

私有文件会尝试关闭继承 ACL，只授予当前 Windows 用户和 SYSTEM。ACL 失败时部署会停止，而不是留下权限宽松的私钥继续运行。

## 2. SSH 切换规则

切换顺序固定为：

1. 在服务商初始端口通过密码或现有服务商私钥验证 root 登录；
2. 写入工具新生成的实例专用公钥；
3. 验证 root 公钥；
4. 创建 admin、验证 admin 公钥和 sudo；
5. SSH 同时监听初始、主高位、救援高位端口；
6. 从全新连接验证 root/admin 在两个高位端口均可用；
7. 防火墙暂时同时放行三个 SSH 端口；
8. Xray、时间、网络和可选 Komari 全部验收；
9. 最后移除初始端口，再次验证两个高位端口。

任何一项失败都不得关闭旧入口。

对于 DMIT 等初始即禁用密码的模板，现有服务商私钥只用于步骤 1–2。工具会收紧该文件的 Windows ACL，但不会复制其内容；新公钥验证成功后，后续模块统一使用新生成的实例专用密钥。私钥带口令时由 OpenSSH 直接询问，工具不保存口令。

## 3. 远程秘密传输

秘密不会作为 SSH 命令行参数。核心将参数编码后写入远端 `bash -s` 的标准输入；模块禁止 `set -x`，参数随隔离的子 shell 退出而销毁。Komari Token 不保存到部署计划，恢复运行时需要重新输入。Cloudflare Token 的本地文件路径可以写入计划，但 Token 值本身不会写入计划或普通日志。

Xray 生成的秘密通过捕获的机器可读标记返回核心；普通控制台和普通日志不打印敏感 stdout。保存本地私有文件后立即应用 ACL。

## 4. 防火墙边界

最小 nftables 模板包含 `flush ruleset`，因此只适用于审计确认的干净 VPS。检测到 Docker、容器、代理面板、已有 Xray/sing-box 或非空复杂规则时默认拒绝执行。

加载前必须通过 `nft -c`；过渡规则保留服务商初始 SSH 端口。工具不会修改服务商网页安全组。

## 5. REALITY target

候选必须从目标 VPS 实测，至少满足：TCP/443、证书有效、TLS 1.3、ALPN h2、普通 HTTPS 行为、同地区或邻近、20 次握手中位通常不超过 15 ms、没有明显大型多租户共享 CDN 特征。大学、教育/科研机构、成熟企业或专业机构优先，不选个人站点和教程中被反复复制的热门 target。

自动审计只能筛除明显不合格项，不能证明长期安全。正式使用仍以客户端 Reality Authentication、HTTP 204 和真实出口为最终标准。

### 本机可信 HTTPS target

`LocalOwnedTls` 模式使用自有域名的公共 CA 证书，nginx 只允许监听 `127.0.0.1/[::1]` 的高位端口。安装软件包时先 mask nginx，避免发行版默认 80 站点瞬时启动；写入并检查回环配置后才解除 mask。nftables 不开放 target 端口，nginx 也不得监听公网 80/443。Xray 的 `target/dest` 指向回环地址，客户端 `serverName` 使用证书域名；绝不能配置按任意 Host 反代的 `proxy_pass`。

该模式阻断了通过第三方多租户 CDN target 进行跨域转发的路径，但并不自动提供与大型外部站点完全相同的流量外观。证书、静态内容和域名生命周期由用户负责。

## 6. AnyTLS、ECH 与可信证书

`AnyTlsEntry` 与 `RealityEntry` 是互斥角色。AnyTLS 只监听 TCP 443，隧道内可承载 TCP/UDP；nftables 不需要额外开放公网 UDP 443。systemd 服务以 `sing-box-anytls` 低权限账户运行，仅授予 `CAP_NET_BIND_SERVICE`，不授予 `CAP_NET_ADMIN` 或 `CAP_NET_RAW`。

内部 SNI 与 ECH public name 必须是两个不同的自有域名，证书同时覆盖二者，客户端保持证书校验开启。AnyTLS 密码和 ECH 服务端 key 只进入实例私有归档；ECH client config 本身是公开配置，但仍和节点文件一起管理，避免版本错配。

Padding scheme 不是认证秘密。新计划为每台实例生成一组稳定的保守方案，避免所有部署长期共享同一组示例参数；方案保存在实例计划中，不能在每次重启或 Resume 时轮换。客户端第一次建立会话仍使用协议默认方案，之后由服务端在加密协议内下发实例方案，因此它不能消除所有初始连接或时序特征，也不能视为绝对抗识别保证。

切换前保存 Xray active/enabled 状态。AnyTLS 配置、启动或监听验收失败时，脚本自动停用 AnyTLS 并恢复原 Xray；成功后 Xray 保持停止和禁用。真实验收必须包含受信证书、ECH、HTTP 204、出口 IP 和 UDP DNS 往返。

## 7. 已部署协议迁移边界

协议迁移只接受本工具已经完成 SSH 收口、当前协议部署、防火墙、最终验收和私有归档的实例。源计划路径、归档根目录、模块状态、当前管理端口和实例专用私钥必须彼此一致；任一缺失都拒绝迁移。任意第三方面板、容器或手工复杂防火墙仍不属于自动迁移授权范围。

本地覆盖计划前先在实例目录 `migration-backups` 保存源计划、状态、私有凭据文件、服务端快照和客户端片段，并校验源计划 SHA-256 在向导确认后没有发生变化。远端切换前保存 nftables 和脚本管理的 sysctl 配置，随后启用 20 分钟 systemd 回滚 timer。回滚服务不依赖 Windows 端进程；它会停用目标服务、恢复旧防火墙/网络调优并重新启用源协议。

目标 Reality/AnyTLS 必须完成本机 Mihomo 的真实协议、证书/ECH、HTTP 204 和出口测试。目标 Shadowsocks 除服务器回环自测外，必须从另一台白名单 Reality/AnyTLS 入口执行 TCP、UDP 和出口探测。只有这些检查通过后，`migration-commit` 才停用源服务和取消 timer。旧配置与二进制保留但服务禁用，供以后反向迁移和人工恢复。

## 8. Cloudflare DNS-01 与 Certbot

Token 仅授予目标 Zone 的 `DNS:Edit` 和 `Zone:Read`，不得使用全局 API Key。服务器凭据文件 `/etc/letsencrypt/cloudflare.ini` 为 root:root 0600，本地 Token 文件也必须收紧 ACL。若启用 Token 客户端 IP 白名单，所有续期 VPS 的稳定公网出口都必须在列表中。

Certbot 通过 DNS-01 签发和续期证书，不要求开放 80。工具停用发行版的 `certbot.timer`，只保留 `mxh-certbot-renew.timer`，以确保每次成功续期都执行部署 hook。hook 只识别固定证书名，以临时文件和原子替换更新 `/etc/mxh-tls`，然后检查并重启 AnyTLS 或 reload nginx。

## 9. Shadowsocks 落地边界

纯落地角色使用 sing-box Shadowsocks 2022 多用户结构。服务端主密钥、各用户密钥和拼接后的客户端密码全部属于有效凭据，只写实例私有归档。

落地端口不会加入公网通用放行集合；nftables 仅对填写的可信入口 IPv4/IPv6 放行同一个 TCP+UDP 端口。服务商安全组必须手动保持同样白名单。入口 IP 变化时应先添加新地址并验证链路，再删除旧地址。

可选 IPv6 用户通过 `auth_user` 路由到绑定指定 IPv6 地址的 direct 出站。新机部署模块会在服务器回环地址上实际完成 SS2022 认证和出口测试；协议迁移到 Shadowsocks 时还强制从另一台白名单入口执行公网链式探测。权威客户端配置合并后仍需人工复验长期使用路径。

默认 sing-box 服务不保留 Linux capabilities。只有明确填写 `SecondaryBindInterface` 时，才通过 systemd drop-in 授予 `CAP_NET_RAW`，用于 Linux 的接口绑定；仅填写 IPv6 源地址时不会增加该能力。

## 10. 网络调优边界

基础项只包含 fq、内核可用时的 BBR、TCP Fast Open 与 MTU 探测。自适应部分按角色、实际内存、用户填写的标称带宽和代表性 RTT 计算 2×BDP，并设置 4/8/16/32 MiB 的分级上限。

脚本不运行来源不明的测速或 BBR 一键脚本，不根据虚拟网卡速率猜套餐，不降低当前内核或服务商已有的缓冲区与队列值。现有值超过计算上限时保留原值并记录状态，而不是强制覆盖。

## 11. Git 防泄漏

`.gitignore` 排除运行数据；`scripts/Test-NoSecrets.ps1` 在本地与 CI 中检查私钥块、ECH 服务端 key、UUID、典型 Token 和常见实例凭据文件名。它是最后一道保护，不替代人工检查。
