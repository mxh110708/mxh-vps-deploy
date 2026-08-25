# 模块开发

`modules/*.ps1` 每个文件返回一个模块定义 Hashtable：

```powershell
@{
    Id          = 'example'
    Name        = '示例模块'
    Order       = 500
    Roles       = @('RealityEntry', 'MonitorOnly')
    Requires    = @('audit')
    IsEnabled   = { param($Context) $true }
    Invoke      = { param($Context) }
}
```

核心按 `Order` 排序，并验证 `Id` 唯一、依赖存在且位于之前。删除模块文件即可移除功能；新增模块不需要修改入口脚本。

当前角色：

- `RealityEntry`：Xray VLESS + REALITY + Vision；
- `AnyTlsEntry`：sing-box AnyTLS + 公共 CA 可信 TLS + ECH，固定监听 TCP 443；
- `ShadowsocksLanding`：sing-box Shadowsocks 2022 多用户落地；
- `MonitorOnly`：只配置管理入口、防火墙和可选 Komari；
- `AuditOnly`：只建立临时管理访问并审计。

供应商专有 IPv6 获取、策略路由或网络命名空间应作为单独模块加入，不应修改通用 `sing-box-shadowsocks` 模块。

`network-tuning` 使用计划中的 `NetworkTuning.Mode/BandwidthMbps/ReferenceRttMs` 和初始审计的实际内存计算参数。标称带宽与代表性 RTT 属于用户输入，禁止通过公网测速或虚拟网卡显示速率自动猜测。

`shadowsocks-self-test.sh` 是落地模块的规范功能测试：TCP 通过 HTTPS 检查真实出口，UDP 通过临时 direct inbound 转发 DNS 查询并校验响应。`shadowsocks-external-probe.sh` 供维护验收使用，会下载并校验固定版本临时核心、复用同一套 TCP/UDP 测试，结束后不保留客户端文件。

可信 TLS 相关模块按顺序拆分：

- `certbot-dns`：验证 Cloudflare Zone Token，签发证书，执行模拟续期并安装唯一的续期计时器和部署 hook；
- `local-https-target`：仅在 Reality 的 `LocalOwnedTls` 模式启用，部署回环 nginx 静态站；
- `sing-box-anytls`：安装固定版本低权限核心、生成 AnyTLS 密码与 ECH 密钥、切换 443 并执行 TCP/UDP/ECH 自测；
- `anytls-client-export`：生成 Mihomo 测试 YAML、sing-box 出站和 ECH client config 私有片段。

`anytls-apply-config.sh` 在停止既有 Xray 前记录 active/enabled 状态。AnyTLS 启动或监听验证失败时，会停用失败服务并恢复原 Xray 状态；成功后才解除回滚。服务端配置不启用 `auto_detect_interface`，避免为了普通直连出站给低权限服务额外授予 `CAP_NET_RAW`。

`New-MxhAnyTlsPaddingScheme` 在创建计划时生成 `PerInstanceConservativeV1`：保持协议默认方案的前八包结构，但在受控范围内改变各段长度，单段 TLS plaintext 上限不超过 1100 字节。结果写入部署计划并在继续运行时保持不变。服务端通过 AnyTLS 协议下发 padding scheme，客户端配置不需要也不应复制该数组；缺少字段的旧计划由 `Get-MxhAnyTlsPaddingScheme` 回退到官方默认值。

`anytls-self-test.sh` 会以真实 AnyTLS+ECH 客户端完成 HTTPS 204、出口 IP 和 UDP DNS 往返。语法通过、443 可达或证书可读都不能替代这组功能测试。现场验收还应从另一台主机执行同样的外部探测。

协议迁移不是重新运行新机模块。计划中的 `Migration.ModuleIds` 对模块集合做白名单筛选，只保留目标协议需要的步骤：

- `migration-preflight`：复验源服务、双 SSH、源配置和当前 nftables；
- 目标协议的 target/证书前置模块；
- `migration-arm-rollback`：备份 nftables/sysctl 并部署 VPS 端独立回滚计时器；
- 目标协议服务、角色网络调优、目标 nftables 和客户端导出；
- Shadowsocks 目标额外运行 `migration-shadowsocks-probe`，从另一台白名单入口执行真实 TCP/UDP 探测；
- `final-validation` 与 `migration-commit`：目标真实出口通过后停用源服务并撤销计时器；
- `private-archive`：记录迁移状态并重新生成最终校验和。

迁移失败时核心调用 `Invoke-MxhProtocolMigrationRollback` 立即触发回滚服务；若 SSH 已被错误防火墙暂时阻断，systemd timer 仍独立执行。回滚后只重置切换阶段及其后模块，证书/target 等安全前置结果可以按模块状态决定是否复用。

## 约定

- 远端 Bash 放在 `assets/remote`，必须通过 `bash -n`；
- 远端脚本从 `VPS_PARAM_*` 环境变量读取参数，不从 argv 读取秘密；
- 禁止 `set -x`、打印环境变量或把秘密写入临时日志；
- 修改配置前建立时间戳备份；应用前执行语法检查；
- 模块失败时抛出错误，由核心停止后续模块；
- 幂等优先：重复运行不得无故轮换凭据、端口或覆盖已完成状态；
- 需要特殊供应商脚本的功能，应做成显式模块，不能塞进通用基础模块。
- `-OnlyModule` 不会自动补跑依赖；维护可信 TLS 时必须按证书、服务、客户端导出和最终验收的实际依赖顺序显式执行。

## 状态

每完成一个模块，核心更新实例私有目录中的 `deployment-state.json`。继续模式默认跳过已成功模块。维护模式可用 `-OnlyModule` 显式重跑，但会显示风险确认。
