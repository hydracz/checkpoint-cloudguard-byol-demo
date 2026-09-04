# 已部署环境的独立自动测试步骤

本文用于 **Terraform/Azure 基础设施已经部署成功、且管理员已在 SmartConsole/Gaia
完成配置以后** 的独立验证。测试阶段不重新创建基础设施；它读取 Terraform outputs，
执行 T01-T17，提取 Firewall rules 和 Accept/Drop 日志，并生成客户可读 HTML 报告。
保留的自动配置模式是显式选项，不属于 `deploy.sh`。

## 1. 第一阶段交接物

部署脚本正常结束时会生成：

```text
.local/latest-deployment-outputs.json
```

该文件是 `terraform output -json` 的结果。正常 wrapper 部署不会把共享的
Check Point/Windows 明文密码写入该文件，但仍包含客户订阅、Resource Group、
VM 名称、IP 和日志资源标识，必须按客户敏感资料保护。

如果部署成功但交接文件不存在，并且原 Terraform state 仍在当前目录，可重新导出：

```bash
terraform -chdir=infra output -json \
  > .local/latest-deployment-outputs.json
chmod 600 .local/latest-deployment-outputs.json
```

不要手工修改该 JSON。测试结果必须对应 Terraform state 中实际部署的资源。

## 2. 测试机前置条件

测试机需要：

- Azure CLI 已登录，且当前身份可以读取目标订阅、VM、NIC、NSG、Log Analytics 和 Storage。
- `jq`、Python 3、OpenSSL 和 Bash。
- 本仓库与部署时的脚本版本兼容。
- 若使用 Gaia SSH，测试机必须位于 management subnet/可信私网并持有部署时的私钥；
  默认路径是 `.local/checkpoint-demo-ssh`。
- 五台 VM 均为 `PowerState/running`；Ubuntu workload/collector 和 Windows 的 Azure VM Agent 为 `Ready`。

先读取交接信息：

```bash
OUTPUTS=.local/latest-deployment-outputs.json

RELEASE="$(jq -r '.checkpoint_os_version.value' "$OUTPUTS")"
SUBSCRIPTION="$(jq -r '.subscription_id.value' "$OUTPUTS")"
RESOURCE_GROUP="$(jq -r '.resource_group_name.value' "$OUTPUTS")"

printf 'release=%s resourceGroup=%s\n' "$RELEASE" "$RESOURCE_GROUP"
az account show \
  --subscription "$SUBSCRIPTION" \
  --query '{subscription:id,tenant:tenantId,state:state}' \
  --output table
```

检查五台 VM：

```bash
for key in \
  checkpoint_vm_name \
  windows_client_vm_name \
  eu_workload_vm_name \
  remote_workload_vm_name \
  collector_vm_name; do
  VM="$(jq -r --arg key "$key" '.[$key].value' "$OUTPUTS")"
  az vm get-instance-view \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM" \
    --query '{
      vm:name,
      power:instanceView.statuses[-1].displayStatus,
      agent:instanceView.vmAgent.statuses[-1].displayStatus
    }' \
    --output table
done
```

如果 VM 已 deallocated，先启动并等待状态变成 `VM running`。不要在 VM Agent 尚未 Ready 时
立即执行 Azure Run Command：

```bash
az vm start \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$RESOURCE_GROUP" \
  --name "<VM_NAME>" \
  --no-wait
```

## 3. 选择第二阶段模式

### 模式 A：手工 policy 已配置，只执行验证

适用于已通过 SmartConsole/Gaia 完成 Check Point objects/rules、Policy Install 和
Log Exporter 配置的环境。验证脚本不会修改 Firewall policy：

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="evidence/${STAMP}-${RELEASE}-post-deploy"

./scripts/validate-existing.sh \
  --outputs-file "$OUTPUTS" \
  --expected-release "$RELEASE" \
  --output-dir "$OUT"
```

### 模式 B：显式使用保留的 R81/R82 自动化后再验证

只适用于已确认允许脚本修改 Gateway、且执行机能访问
`checkpoint_management_private_ip` 的环境。先独立运行保留的自动化，再运行只读验证：

```bash
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="evidence/${STAMP}-${RELEASE}-post-deploy"

CHECKPOINT_SKIP_POLICY_CONFIGURATION=false \
  CHECKPOINT_TRANSPORT=ssh \
  ./scripts/configure-policy.sh \
  --outputs-file "$OUTPUTS"

./scripts/validate-existing.sh \
  --outputs-file "$OUTPUTS" \
  --expected-release "$RELEASE" \
  --output-dir "$OUT"
```

R82/R82.10 可以在该路径中自动配置 outbound HTTPS Inspection CA、Inspect layer/rule 和
workload CA trust。R81 的 HTTPS Inspection 例外见下一节。

### 仅测试订阅：临时恢复被外部策略删除的 SSH rule

只有明确知道订阅策略会删除 Terraform-managed TCP/22 rule 时才设置：

```bash
export CHECKPOINT_RECONCILE_SSH_RULE=true
```

报告会把 T17 标为 `RECONCILED`，而不是普通 PASS；临时 rule 会在测试结束时删除。普通客户
环境不应启用该开关，应修复实际 NSG 或 Azure Policy。

## 4. R81 HTTPS Inspection / T07

R81 GA Management API 1.7 不能通过本仓库完全 headless 地创建 outbound CA 或启用 Gateway
HTTPS Inspection。未完成 SmartConsole bootstrap 时：

```hcl
enable_tls_inspection       = false
r81_tls_manually_configured = false
```

T07 会明确记录 `SKIP`，HTML 报告同时给出完整半自动步骤。若必须验证 R81 TLS：

1. 确认 BYOL 已授权 Firewall、Application Control、URL Filtering 和 HTTPS Inspection。
2. 使用 R81 SmartConsole 打开 **Gateways & Servers**，编辑 standalone Gateway。
3. 在 **HTTPS Inspection** 中 Create/Import outbound CA，并导出只含公钥的 PEM/DER
   certificate；私钥/P12 和密码不得进入仓库或报告。
4. Enable HTTPS Inspection。
5. 在 package 中启用 **Access Control & HTTPS Inspection**。
6. 在 HTTPS Inspection rulebase 中先添加客户批准的 Bypass，再添加 outbound Inspect rule：
   Source=受保护网络、Destination=Internet、Service=HTTPS、Action=Inspect、
   Certificate=Outbound Certificate、Track=Log、Install On=standalone Gateway。
7. Publish 并 Install Access Control policy。
8. 在 R81 tfvars 中设置：

   ```hcl
   enable_tls_inspection       = true
   r81_tls_manually_configured = true
   ```

9. Apply 两个开关并重新导出 outputs：

   ```bash
   ./scripts/plan.sh --var-file "<R81_TFVARS>"
   terraform -chdir=infra apply \
     -input=false \
     -auto-approve \
     "$(pwd)/.local/plan.tfplan"
   terraform -chdir=infra output -json \
     > .local/r81-tls-validation-outputs.json
   ```

10. 安装 public CA trust、保留 SmartConsole 配置并执行 T07：

    ```bash
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    OUT="evidence/${STAMP}-R81-tls-validation"

    CHECKPOINT_SKIP_POLICY_CONFIGURATION=false \
      CHECKPOINT_TRANSPORT=ssh \
      CHECKPOINT_TLS_CA_FILE="<SMARTCONSOLE_EXPORTED_PUBLIC_CA>" \
      ./scripts/configure-policy.sh \
      --outputs-file .local/r81-tls-validation-outputs.json

    ./scripts/validate-existing.sh \
      --outputs-file .local/r81-tls-validation-outputs.json \
      --expected-release R81 \
      --ca-file "<SMARTCONSOLE_EXPORTED_PUBLIC_CA>" \
      --output-dir "$OUT"
    ```

T07 会在实际 workload 上运行：

```bash
openssl s_client \
  -connect www.microsoft.com:443 \
  -servername www.microsoft.com \
  </dev/null |
  openssl x509 -noout -issuer -nameopt RFC2253
```

只有实际 leaf certificate issuer 与 `--ca-file` public certificate 的 subject 匹配时才 PASS。

## 5. 测试内容

第二阶段执行 T01-T17：

- Azure effective routes、CloudGuard image/Plan、NSG 和 EU resource location。
- 主/远端 workload 之间的真实 HTTP 流量。
- 允许 HTTPS、域名阻断、URL path 阻断和可选 TLS Inspection。
- Gateway Access Control rulebase、Gaia version 和 `cp_log_export status`。
- Log Analytics 中真实 `action="Accept"` / `action="Drop"` Firewall 日志。
- Storage immutable retention policy 和可选入站 DNAT。

每个远端流量用例都会记录：

- 实际执行 hostname。
- 实际 `curl`/`openssl`/`journalctl` 命令。
- HTTP status、命令退出码和响应正文摘录。
- PASS/FAIL/SKIP/RECONCILED 状态。

## 6. 报告与验收

命令结束后检查：

```bash
test -s "$OUT/report.html"
test -s "$OUT/summary.json"

jq '{
  overallStatus,
  firewallRuleCount,
  firewallActionLogCount,
  results: [.results[] | {id,status}]
}' "$OUT/summary.json"
```

用浏览器打开：

```bash
open "$OUT/report.html"       # macOS
# xdg-open "$OUT/report.html" # Linux desktop
```

客户报告 `report.html` 应包含：

- 环境和版本配置。
- Firewall 配置执行结果与实际 rulebase。
- 测试结果汇总。
- 每项测试的执行位置、具体命令、期望和实际输出。
- Firewall Accept/Drop 日志的时间、源、目的、service 和命中 rule。
- R81 T07 SKIP 时的 SmartConsole 半自动完成步骤。

验收标准：

- 脚本退出码为 `0`。
- `overallStatus` 为 `PASS` 或经批准的 `PASS_WITH_NOTES`。
- 不存在 `FAIL` 或 `PENDING_INGESTION`。
- `SKIP` 只能对应明确未启用的可选功能。
- `RECONCILED` 只能用于已记录的测试订阅 SSH rule 例外。
- `firewallRuleCount` 和 `firewallActionLogCount` 均大于 `0`。

## 7. 证据文件边界

目录中同时保留：

| 文件 | 用途 |
| --- | --- |
| `report.html` | 面向客户的可读报告 |
| `summary.json` / `configuration.json` | 机器可读结果 |
| `T*.json` / `T*.txt` | 每项测试的原始 Azure/Gaia/流量证据 |
| `firewall-configuration-*` | Firewall 配置回执和日志 |
| `commands.log` / `run-tests.log` | 工程排障，不进入客户 HTML |

`evidence/` 已被 `.gitignore` 排除。报告含客户订阅、IP、资源名、策略和流量日志，**不要提交到
本源码仓库**。应通过客户批准的受控文件渠道交付；如必须使用版本控制，应放入单独的私有、
访问受控仓库，并先完成客户审批和脱敏。

## 8. 常见失败

| 现象 | 处理 |
| --- | --- |
| `OperationNotAllowed: VM must be running` | 启动对应 VM，等待 PowerState running 和 Agent Ready 后重跑 |
| T17 `FAIL` | 检查实际 NSG/Azure Policy；不要用临时恢复掩盖客户环境问题 |
| T17 `RECONCILED` | 测试订阅外部策略删除 SSH rule；报告已明确标注 |
| T10 `PENDING_INGESTION` | 等待 Log Analytics 摄取后重跑；可提高 `LOG_INGEST_WAIT_SECONDS` |
| R81 T07 `SKIP` | 按第 4 节完成 SmartConsole bootstrap，并传入 `--ca-file` |
| Azure Run Command 长时间无结果 | 确认 VM Agent Ready；Gateway 优先使用部署 SSH key |
