# Check Point 策略、许可证与日志配置

## BYOL 激活

Terraform 只部署 Marketplace `mgmt-byol` 镜像。许可证 entitlement、contract
和激活信息不写入 `tfvars`、Terraform state 或脚本参数。

若首次策略安装提示 blade 未授权：

1. 从 `management_cidr` 登录 Terraform output 中的 Gaia Portal 或 SmartConsole 地址。
2. 按 Check Point User Center/SmartUpdate 流程激活客户 BYOL。
3. 确认 Firewall、Application Control、URL Filtering 和 HTTPS Inspection entitlement。
4. 重新运行 `./scripts/configure-policy.sh`。

## Access Control 规则顺序

脚本删除并重建名称以 `CloudGuard Demo - ` 开头的规则，不修改其他规则。TCP/8080
使用 Check Point 内置 `HTTP_proxy` Service，避免创建重复端口对象。

1. Allow Gateway Services。
2. Allow Restricted Management SSH。
3. Block Geo Inbound。
4. Block Geo Outbound。
5. Block Domains URLs and Applications。
6. 可选 Restricted North South Inbound。
7. Allow Inspected East West Web。
8. Allow Web and DNS Egress。
9. Cleanup Drop。

`CloudGuard Demo - Allow Restricted Management SSH` 与 Azure NSG 使用同一个
`management_cidr`，目标只包含 Gateway object。Policy 安装后，其他公网来源
不能访问 SSH。

`CloudGuard Demo - Allow Gateway Services` 位于规则库最顶部，允许 Gateway object
自身发起 HTTP、HTTPS、DNS 和 syslog，用于 Azure metadata/agent、
Check Point update 和 Log Exporter。该规则不匹配两个工作负载 source。

所有规则都启用日志。脚本发布 Management API session 后，对 `standalone`
Gateway 执行 `install-policy`。

## Geo 对象

`blocked_countries` 使用 Check Point Updatable Objects Repository 中的英文国家名。
脚本按以下顺序处理：

1. Repository 未初始化时执行 `update-updatable-objects-repository-content`。
2. 用 `show updatable-objects-repository-content filter.text` 搜索最多 500 项。
3. `name-in-updatable-objects-repository` 必须与参数大小写一致。
4. 尚未导入时执行 `add updatable-object`。
5. Access Rule 使用 Management object UID，避免名称解析差异。

搜索不到精确名称时，脚本返回错误；它不会改用静态 CIDR，也不会跳过该国家。

## TLS Inspection

`enable_tls_inspection=true` 时：

- Management API 生成 `CloudGuardDemoOutboundCA`，私钥留在 Management。
- `issued-by` 使用 `company_domain`；未设置时为 IANA 保留域名 `example.org`。
- 创建 outbound HTTPS layer 和 Inspect rule。
- Public CA 通过 Azure Run Command 安装到两台工作负载 VM。
- T07 检查网站叶子证书 issuer，而不是只读取策略对象。

生产设计需要企业 CA 审批、密钥托管、证书轮换、金融/医疗/个人隐私站点
bypass、QUIC/HTTP3 策略、证书固定应用测试和终端信任分发。

## Log Exporter

脚本配置：

```text
name=azure-monitor
target-server=10.60.2.4
target-port=514
protocol=udp
format=generic
read-mode=semi-unified
```

UDP/514 不提供传输加密。生产若要求链路机密性，需要根据当前 Check Point
Log Exporter 支持矩阵改为 TCP/TLS，并配置 CA 和 client certificate。

新 Log Analytics workspace 中可能没有 `Syslog` 表，因此 Data Export 不能
与空 workspace 同时创建。`enable-audit-export.sh` 先通过日志收集 VM 的
`logger` 产生记录，等到表可查询后写入 gitignored
`infra/audit.auto.tfvars.json`，再创建 Export Rule。该文件让后续 plan 保留
Export Rule。

## 重复执行与恢复

- `configure-policy.sh` 可重复执行；只重建 `CloudGuard Demo - ` 规则和
  `CloudGuard-*` 演示对象。
- 修改 Geo/Application/URL 清单后重新 `plan/apply`，再运行 `configure-policy.sh`。
- WORM lock 不可回滚。锁定后，Storage 在保留期结束前会阻止相关资源删除。
- `lock-worm.sh` 检测到 `Locked` 时直接返回。锁定后不要修改 ARM template 中的
  Immutability Policy 状态；Azure 不允许恢复为 `Unlocked`。
