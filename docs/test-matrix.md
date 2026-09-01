# 数据路径检查矩阵

| ID | 检查项 | 命令或方法 | 应观察到的状态 |
| --- | --- | --- | --- |
| T01 | 主工作负载默认路由 | Azure NIC effective route table | Active `0.0.0.0/0` 的下一跳为 `VirtualAppliance 10.60.1.4`。 |
| T02 | 远端工作负载默认路由 | Azure NIC effective route table | Active `0.0.0.0/0` 的下一跳为 `VirtualAppliance 10.60.1.4`。 |
| T03 | 跨区域东西向 | Primary VM 使用 `curl` 访问 Remote VM TCP/8080 | 返回远端演示页面。 |
| T04 | 允许的 HTTPS 出站 | Primary VM curl `httpbin.org/anything/allowed` | HTTP 200。 |
| T05 | 域名阻断 | Primary VM curl `example.com` | 连接失败或收到非成功阻断响应。 |
| T06 | URL path 阻断 | 对比 httpbin allowed/blocked path；TLS 开启时使用 HTTPS，关闭时使用 HTTP | `allowed` 为 200，`blocked` 不是 200。 |
| T07 | TLS 解密 | `openssl s_client` 查看公网网站 issuer | issuer 包含 `company_domain`；关闭 TLS 时记录 `SKIP`。 |
| T08 | 双向 Geo 和 L7 policy | Management API 读取 Access Rulebase | 返回双向 Geo 和 Application Control 规则。 |
| T09 | Check Point Log Exporter | Gateway 执行 `cp_log_export status` | `azure-monitor` 显示 `Running`。 |
| T10 | EU Log Analytics 摄取 | 查询两小时内 `Syslog` | 返回 Check Point 日志；等待摄取时为 `PENDING_INGESTION`。 |
| T11 | 长期留存策略 | Azure Immutability Policy API | 保留天数与 Terraform output 一致；`Locked` 状态需要显式执行锁定。 |
| T12 | EU 资源位置 | 列出资源组中的 `location` | 只出现批准的 EU region 或 `global`。 |
| T13 | 可选南北向入站 | 从批准来源使用 `curl` 访问 Public IP:18080 | 返回主工作负载页面；功能关闭时记录 `SKIP`。 |
| T14 | 镜像与 Plan 模式 | Azure VM image reference 和 `plan` | 精确匹配 custom image ID；有 Plan 模式字段完整，无 Plan 模式为 `null`。 |
| T15 | Guest Gaia 版本 | Gateway `clish -c "show version all"` | 与 `checkpoint_os_version` 对应。 |
| T16 | 东西向源地址保留 | 远端 workload 的 `demo-web` journal | 请求源为主 workload IP，不是 Gateway Hide NAT 地址。 |
| T17 | 管理 NSG rules | Azure NSG rule list | 4 条管理端口规则均为 Allow，且 source prefixes 与 `management_cidrs` 完全一致。 |

运行：

```bash
./scripts/run-tests.sh
```

已有部署推荐运行 `scripts/validate-existing.sh`；它可以读取第一阶段保存的
`.local/latest-deployment-outputs.json`，同时生成 `report.md`、`summary.json`、
逐项原始证据和完整 Bash 命令 trace。

`summary.json` 原样记录 `SKIP`、`RECONCILED` 和 `PENDING_INGESTION`。`RECONCILED`
表示测试期间临时恢复了随后删除的 SSH rule，不会伪记为普通 PASS。脚本默认等待日志摄取最多
30 分钟；任何 `FAIL` 或 `PENDING_INGESTION` 都返回非零。R81 尚未完成 SmartConsole TLS
bootstrap 时 T07 为预期 `SKIP`；设置 `r81_tls_manually_configured=true` 并通过
`--ca-file` 或 `CHECKPOINT_TLS_CA_FILE` 提供该部署的 public CA 后，T07 仍须
以实际 issuer 通过。Geo 的实际国家判定需要客户批准、可控且不会造成滥用的测试端点；
T08 只检查策略对象，不能替代流量检查。
