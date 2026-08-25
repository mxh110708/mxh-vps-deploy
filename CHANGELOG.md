# Changelog

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
