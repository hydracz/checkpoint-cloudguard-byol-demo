# 数据路径检查矩阵

| ID | 检查项 | 命令或方法 | 应观察到的状态 |
| --- | --- | --- | --- |
| T01 | 主工作负载默认路由 | Azure NIC effective route table | Active `0.0.0.0/0` 的下一跳为 `VirtualAppliance 10.60.1.4`。 |
| T02 | 远端工作负载默认路由 | Azure NIC effective route table | Active `0.0.0.0/0` 的下一跳为 `VirtualAppliance 10.60.1.4`。 |
| T03 | 跨区域东西向 | Primary VM 使用 `curl` 访问 Remote VM TCP/8080 | 返回远端演示页面。 |
| T04 | 允许的 HTTPS 出站 | Primary VM curl `httpbin.org/anything/allowed` | HTTP 200。 |
| T05 | 域名阻断 | Primary VM curl `example.com` | 连接失败或收到非成功阻断响应。 |
| T06 | URL path 阻断 | 对比 httpbin allowed/blocked path | `allowed` 为 200，`blocked` 不是 200。 |
| T07 | TLS 解密 | `openssl s_client` 查看公网网站 issuer | issuer 包含 `company_domain`；关闭 TLS 时记录 `SKIP`。 |
| T08 | 双向 Geo 和 L7 policy | Management API 读取 Access Rulebase | 返回双向 Geo 和 Application Control 规则。 |
| T09 | Check Point Log Exporter | Gateway 执行 `cp_log_export status` | `azure-monitor` 显示 `Running`。 |
| T10 | EU Log Analytics 摄取 | 查询两小时内 `Syslog` | 返回 Check Point 日志；等待摄取时为 `PENDING_INGESTION`。 |
| T11 | 长期留存策略 | Azure Immutability Policy API | 保留天数与 Terraform output 一致；`Locked` 状态需要显式执行锁定。 |
| T12 | EU 资源位置 | 列出资源组中的 `location` | 只出现批准的 EU region 或 `global`。 |
| T13 | 可选南北向入站 | 从批准来源使用 `curl` 访问 Public IP:18080 | 返回主工作负载页面；功能关闭时记录 `SKIP`。 |

运行：

```bash
./scripts/run-tests.sh
```

`summary.json` 原样记录 `SKIP` 和 `PENDING_INGESTION`。Geo 的实际国家判定需要
客户批准、可控且不会造成滥用的测试端点；T08 只检查策略对象，不能替代流量检查。
