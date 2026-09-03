# Check Point 策略、许可证与日志配置

## 默认行为

`deploy.sh` 默认只创建 Azure 基础设施，不调用 `configure-policy.sh`。管理员通过
Azure Bastion 登录 Windows 管理工作站，在 Gaia Portal / SmartConsole 手工完成路由、
对象、规则、TLS 和 Log Exporter。

仓库保留 R81/R82 自动化。只有从 `management_subnet_prefix` 或额外可信私网中
显式运行时，才在 tfvars 设置：

```hcl
skip_policy_configuration = false
```

## BYOL 激活

Terraform 默认部署 Marketplace `mgmt-byol` 镜像，也可显式选择 R82/R82.10 有 Plan
custom image 或已获授权的 R81 无 Plan custom image。许可证 entitlement、contract
和激活信息不写入 `tfvars`、Terraform state 或脚本参数。

若首次策略安装提示 blade 未授权：

1. 使用 tfvars 中的 `checkpoint_admin_password` 登录 `admin`；部署脚本已配置
   Console 和 Gaia CLI/Portal 密码，SSH 仍使用 `.local/checkpoint-demo-ssh`。
2. 通过 Bastion 登录 Windows，从 `10.60.3.10` 连接 Terraform output 中的
   `checkpoint_management_private_ip`；Gateway Public IP 不开放管理端口。
3. 按 Check Point User Center/SmartUpdate 流程激活客户 BYOL。
4. 确认 Firewall、Application Control、URL Filtering 和 HTTPS Inspection entitlement。
5. 在 SmartConsole 手工配置；或确认允许自动修改后，从管理私网显式运行
   `CHECKPOINT_TRANSPORT=ssh ./scripts/configure-policy.sh`。

## Access Control 规则顺序

脚本删除并重建名称以 `CloudGuard Demo - ` 开头的规则，不修改其他规则。TCP/8080
使用 Check Point 内置 `HTTP_proxy` Service，避免创建重复端口对象。

1. Allow Gateway Services。
2. Allow Restricted Management SSH。
3. 可选 Restricted North South Inbound。
4. Block Geo Inbound。
5. Block Geo Outbound。
6. Block DNS Domains。
7. Block Domains URLs and Applications。
8. Allow Inspected East West Web。
9. Allow Web and DNS Egress。
10. Cleanup Drop。

脚本先用 `CloudGuard Demo - No NAT Protected Networks` 保留 Spoke 间的 workload
源地址，再用 `CloudGuard Demo - Hide Protected Networks` manual NAT rule 实现公网
出站 Hide NAT。不依赖 R82 才支持的 `nat-hide-internal-interfaces` Management API
参数，因此 R81/R82 使用相同策略路径；T16 检查远端 Web journal 中的真实来源地址。

有效管理来源始终包含 `management_subnet_prefix`，`management_cidrs` 只追加
私网/VPN 前缀且拒绝 `0.0.0.0/0`。Terraform 在独立 management NIC NSG 中为
SSH、Gaia Portal 和 SmartConsole 创建规则；frontend/backend 数据平面 NSG 不允许
任何 Internet/Public CIDR 访问这些管理端口。
可选脚本用 `cp_conf client createlist` 同步 GUI Clients；仅在
`skip_policy_configuration=false` 时为来源创建 policy objects。

可选入站规则是 Geo Inbound 前的窄例外：它同时要求 Azure NSG 和 Check Point
Policy 命中同一个 `inbound_demo_source_cidr`，且只开放 TCP/18080。这样获批测试
来源即使位于 `blocked_countries` 也能执行 T13，其他该国家/地区流量仍由 Geo rule
阻断。

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

显式运行自动化且 `skip_policy_configuration=false`、`enable_tls_inspection=true` 时：

- Management API 生成 `CloudGuardDemoOutboundCA`，私钥留在 Management。
- `issued-by` 使用 `company_domain`；未设置时为 IANA 保留域名 `example.org`。
- 创建 outbound HTTPS layer 和 Inspect rule。
- Public CA 通过 Azure Run Command 安装到两台工作负载 VM。
- T07 检查网站叶子证书 issuer，而不是只读取策略对象。

R81 GA 的 Management API 1.7 不公开 `add-outbound-inspection-certificate`，也不公开
R82 使用的 Gateway HTTPS Inspection 设置参数。默认
`enable_tls_inspection=false`：T06 改用明文 HTTP path 验证 URL Filtering，T07
记录 `SKIP`。R81 Jumbo 只提升到 API 1.7.1，仍不补齐这些接口。

厂商支持的 R81 非 API 路径是 SmartConsole：

1. 编辑 Gateway → HTTPS Inspection，Create/Import outbound CA，并 Export public CA。
2. 启用 Gateway HTTPS Inspection。
3. 在 package 启用 Access Control & HTTPS Inspection，添加 Bypass/Inspect rules。
4. Publish 并 Install policy。

完成后设置：

```hcl
enable_tls_inspection       = true
r81_tls_manually_configured = true
```

再执行：

```bash
export CHECKPOINT_TLS_CA_FILE="<SMARTCONSOLE_EXPORTED_PUBLIC_CA>"
./scripts/plan.sh --var-file configs/demo.tfvars
terraform -chdir=infra apply \
  -input=false -auto-approve \
  "$(pwd)/.local/plan.tfplan"
CHECKPOINT_TRANSPORT=ssh ./scripts/configure-policy.sh
./scripts/run-tests.sh
```

脚本支持 PEM/DER 公钥证书，安装 workload trust，并保留 SmartConsole 管理的 R81 CA、
Gateway setting 和 HTTPS rules。T07 从该 public CA 的 RFC2253 subject 推导期望
issuer，仍必须验证实际流量。脚本不会使用未支持的
`dbedit`、`set generic-object`、私有 endpoint 或直接数据库修改。

R81.20/API 1.9 可导入外部 P12 并启用 Gateway，但 public CA 仍应由企业 PKI 另行保留；
R82/API 2 才是当前完整的 headless create/export 路径。

R81 对 custom Application/Site 的普通 URL pattern 匹配与 R82 不一致，脚本会把
R81 pattern 转义为正则表达式。对于 `blocked_urls` 中不含 path 的纯域名，还会创建
DNS Domain object 和独立 Drop rule，确保未启用 TLS 解密时仍可按域名阻断 HTTPS。

生产设计需要企业 CA 审批、密钥托管、证书轮换、金融/医疗/个人隐私站点
bypass、QUIC/HTTP3 策略、证书固定应用测试和终端信任分发。

## Log Exporter

显式运行 `configure-policy.sh` 时，无论是否启用策略自动化，脚本都配置：

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
Export Rule。脚本使用 `Syslog | ... | count` 的 TSV 数值，不把 Azure CLI 文本错误
传给 `jq`。默认最多等待 1800 秒、每 30 秒重试；可通过
`SYSLOG_TABLE_WAIT_SECONDS`、`SYSLOG_TABLE_RETRY_SECONDS` 调整。失败时最后一次
Azure 查询错误保存在 `.local/azure-query-error.log`。

## 重复执行与恢复

- `CHECKPOINT_TRANSPORT=ssh` 是默认值，只通过私网 `checkpoint_management_private_ip`
  运行自动化。`auto` / `run-command` 仅作为显式 break-glass 选项，不属于正常流程。可用
  `CHECKPOINT_SSH_WAIT_SECONDS` 和 `CHECKPOINT_SSH_RETRY_SECONDS` 调整。
- 若测试订阅自动删除 Terraform-managed SSH rules，在确认允许恢复后设置
  `CHECKPOINT_RECONCILE_SSH_RULE=true`。脚本按 `management_cidrs` output 临时恢复一条
  包含全部 source prefixes 的 TCP/22 rule，并在操作结束时删除它；默认 `false`，不会自动对抗
  组织 Policy。省略 `management_cidrs` 时来源只有 management subnet。
- `configure-policy.sh` 可重复执行；默认只协调 Gaia/Log Exporter。设置
  `skip_policy_configuration=false` 后才重建 `CloudGuard Demo - ` 规则、NAT 规则和
  `CloudGuard-*` 演示对象。
- 修改 Geo/Application/URL 清单后重新 `plan/apply`，再运行 `configure-policy.sh`。
- WORM lock 不可回滚。锁定后，Storage 在保留期结束前会阻止相关资源删除。
- `lock-worm.sh` 检测到 `Locked` 时直接返回。锁定后不要修改 ARM template 中的
  Immutability Policy 状态；Azure 不允许恢复为 `Unlocked`。
