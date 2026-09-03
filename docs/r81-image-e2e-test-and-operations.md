# R81 无 Plan 镜像端到端测试与操作参考

验证时间：2026-08-29 至 2026-08-30 UTC

本文是私有镜像目录中 R81 操作记录的可提交副本，记录已实际执行的 Azure Global
发布、完整 Demo 部署、R81/R82 兼容性处理、T01-T16 测试、清理，以及 R81 HTTPS
Inspection 的支持边界。文档只使用占位符；VHD、真实订阅 ID、SAS 和凭据不得提交。

## 1. 已验证镜像

| 字段 | 值 |
| --- | --- |
| 源 | Azure China `checkpoint-cn:cgi-mgmt-r81:mgmt-byol:81.392.710` |
| 归档 | `cloudguard-cn-r81-mgmt-byol-81.392.710.vhd.tar.gz` |
| SHA-256 | `c808277a2a4f30c94510be212f7a76bedd5b320aef61df92189cb2d738f82aef` |
| VHD | fixed、`107374182912` bytes、Hyper-V V1、Linux、Generalized |
| Azure Global definition | `cloudguard-r81-planless` |
| Gallery version | `81.392.710` |
| Purchase plan | `null` |
| 已完成副本 | Southeast Asia、North Europe |
| Guest | Check Point Gaia R81、OS build 392、64-bit |
| Management API | 1.7 |

如果本地私有镜像目录存在，先校验：

```bash
cd cloudguard-images
shasum -a 256 -c MANIFEST.sha256
./process/verify-images.sh
cd ..
```

## 2. 发布到 Azure Compute Gallery

```bash
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"

./scripts/publish-vhd-image.sh \
  --archive cloudguard-images/r81-no-plan/cloudguard-cn-r81-mgmt-byol-81.392.710.vhd.tar.gz \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group custom-images \
  --location southeastasia \
  --gallery czgallery \
  --definition cloudguard-r81-planless \
  --version 81.392.710 \
  --checkpoint-release R81 \
  --publisher checkpoint-cn \
  --offer cgi-mgmt-r81 \
  --sku mgmt-byol \
  --target-region northeurope
```

脚本验证 SHA-256、单一 tar member、512-byte alignment、`conectix` footer 和 VHD
disk type `Fixed (2)`；然后通过 Managed Disk Direct Upload 创建临时 managed image
和 Gallery version。再次执行同一命令只校验既有 version、源 SHA 和目标副本。

R81 路径禁止 `--plan-*`。R82/R82.10 路径必须传入对应的 Check Point Marketplace
Plan，不能把有 Plan 镜像伪装为无 Plan。

## 3. R81 无 Plan 手动部署步骤

以下步骤从空 Resource Group 开始，先人工检查配置、登录和关键数据路径，再运行完整
自动矩阵。所有命令都在仓库根目录执行。

### 3.1 登录 Azure 并选择 Terraform

```bash
az cloud set --name AzureCloud
az login
az account show --subscription "<SUBSCRIPTION_ID>" --output table

export TERRAFORM="<PATH_TO_TERRAFORM_1_9_OR_NEWER>"
"$TERRAFORM" version
```

脚本对每个 Azure CLI 和 Terraform 操作都使用 tfvars 中的订阅 ID，不依赖当前默认
subscription。

### 3.2 准备 gitignored 配置文件

```bash
cp configs/demo.tfvars.example configs/r81-e2e.tfvars
curl -4fsS https://ifconfig.me/ip
```

编辑 `configs/r81-e2e.tfvars`：

```hcl
subscription_id     = "<SUBSCRIPTION_ID>"
resource_group_name = "rg-checkpoint-r81-e2e"
prefix              = "cpr81"
company_domain      = "example.org"
checkpoint_admin_password = "<STRONG_GAIA_ADMIN_PASSWORD>"

# 可选：management subnet 会自动加入，这里只写额外 VPN/运维私网。
management_cidrs = [
  "<APPROVED_PRIVATE_OR_VPN_CIDR>",
]
management_subnet_prefix = "10.60.3.0/24"

location        = "northeurope"
remote_location = "westeurope"

checkpoint_os_version          = "R81"
checkpoint_image_id            = "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/custom-images/providers/Microsoft.Compute/galleries/czgallery/images/cloudguard-r81-planless/versions/81.392.710"
checkpoint_image_requires_plan = false
checkpoint_vm_size             = "Standard_F16s"

workload_vm_size  = "Standard_D4ls_v6"
collector_vm_size = "Standard_D4ls_v6"

# R81 GA/API 1.7 cannot bootstrap HTTPS Inspection headlessly.
enable_tls_inspection = false
skip_policy_configuration = true

# 完整验证 T13 时使用当前严格限源 /32；不测试入站 DNAT 时保持 false/空字符串。
enable_inbound_demo      = true
inbound_demo_source_cidr = "<CURRENT_PUBLIC_IPV4>/32"
```

当前默认管理来源是 `management_subnet_prefix`；`management_cidrs` 只追加可信
私网/VPN，拒绝 `0.0.0.0/0`。Terraform 在独立 `eth0` management NIC NSG 中为
SSH、Gaia Portal 和 SmartConsole 创建规则。首次启动使用 management subnet；
可选策略脚本随后用
`cp_conf client createlist` 同步完整 GUI Clients，并把同一列表写入
`CloudGuard-SSH-Sources`，避免 Azure 与 Gateway 管理来源不一致。

### 3.3 自动生成仓库专用 SSH key

```bash
unset TF_VAR_admin_ssh_public_key CHECKPOINT_SSH_PRIVATE_KEY
./scripts/preflight.sh --var-file configs/r81-e2e.tfvars

ls -l .local/checkpoint-demo-ssh .local/checkpoint-demo-ssh.pub
ssh-keygen -lf .local/checkpoint-demo-ssh.pub
git check-ignore -v .local/checkpoint-demo-ssh .local/checkpoint-demo-ssh.pub
```

首次执行 `preflight.sh`、`plan.sh` 或 `deploy.sh` 时自动创建无密码 ED25519 密钥：

- `.local/checkpoint-demo-ssh`：私钥，权限 `0600`
- `.local/checkpoint-demo-ssh.pub`：公钥

两者均被 `.gitignore` 排除，私钥不进入 Terraform state。部署、策略配置、自动测试和
下方人工 SSH 命令使用同一私钥。

### 3.4 部署

```bash
./scripts/deploy.sh --var-file configs/r81-e2e.tfvars
```

部署只创建基础设施，不登录 Gaia、不等待 Management API，也不创建 Access Policy。
通过 Bastion/Windows 手工配置，或在第 5.2 节从私有管理网显式运行保留脚本。

### 3.5 查看输出并人工登录

```bash
TF="${TERRAFORM:-terraform}"
SUB="$("$TF" -chdir=infra output -raw subscription_id)"
RG="$("$TF" -chdir=infra output -raw resource_group_name)"
IP="$("$TF" -chdir=infra output -raw checkpoint_management_private_ip)"
NSG_ID="$("$TF" -chdir=infra output -raw checkpoint_management_nsg_id)"
NSG="${NSG_ID##*/}"
KEY="$PWD/.local/checkpoint-demo-ssh"

"$TF" -chdir=infra output
az network nsg rule list \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --query "[?destinationPortRange=='22'].{name:name,priority:priority,sources:sourceAddressPrefixes}" \
  --output table

ssh-keygen -R "$IP" -f .local/known_hosts 2>/dev/null || true
ssh \
  -i "$KEY" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=.local/known_hosts \
  "admin@$IP"
```

Gaia shell 内逐条检查：

```bash
clish -c "show version all"
clish -c "show interfaces"
fw stat
mgmt_cli -r true show packages limit 10 --format json
cp_log_export status
exit
```

首次基础部署后只预期 guest 为 R81；Access Policy 和 `azure-monitor` Log Exporter
需由 SmartConsole/Gaia 手工配置或后续私网脚本完成。
Azure VM metadata 中的 `notused` 不是登录用户，必须使用 `admin`。

部署脚本已用 `checkpoint_admin_password` 配置 `admin` 的 Console 和 Gaia
CLI/Portal 密码；SSH 继续使用仓库私钥。取得 Portal URL：

```bash
"$TF" -chdir=infra output -raw checkpoint_management_url
```

从 `management_cidrs` 中的来源打开该 HTTPS URL，使用用户名 `admin` 和 tfvars
密码登录。TCP/443 对应 `AllowRestrictedGaiaPortal` NSG rule；明文密码位于
gitignored tfvars，salted hash 位于 `.local/deployment-secrets.env` 和 Terraform
首次启动数据。

如果仅测试订阅的组织策略已删除 SSH rule，可在同一 shell 临时恢复、登录并清理：

```bash
export TERRAFORM="<PATH_TO_TERRAFORM_1_9_OR_NEWER>"
# shellcheck disable=SC1091
source scripts/lib.sh
CIDRS="$("$TERRAFORM" -chdir=infra output -json management_cidrs | jq -c .)"
trap remove_temporary_restricted_ssh_nsg_rule EXIT
ensure_restricted_ssh_nsg_rules "$SUB" "$RG" "$NSG_ID" "$CIDRS"

ssh -i "$KEY" -o UserKnownHostsFile=.local/known_hosts "admin@$IP"
remove_temporary_restricted_ssh_nsg_rule
trap - EXIT
```

## 4. R81 兼容性处理

| R81 差异 | 当前处理 |
| --- | --- |
| VM 不携带 Azure Plan | `checkpoint_image_requires_plan=false`，VM `plan=null` |
| 模块原本不接受 `R81`/`cgi-mgmt-r81` | vendored module 只为无 Plan R81 扩展校验 |
| 不支持 `nat-hide-internal-interfaces` | 显式东西向 No-NAT + 公网 Hide NAT |
| NAT rulebase 不稳定返回 rule name | 用已知 rule name 做 show/delete |
| Gaia 内置旧 `jq` | 转换类型后匹配，不使用其不支持的输出格式 |
| custom URL 普通 pattern 行为不同 | R81 使用转义 regex；纯域名增加 DNS Domain Drop |
| API 1.7 无 Outbound CA/Gateway HTTPS 写接口 | 默认关闭 TLS，或使用第 7 节 SmartConsole 混合模式 |

## 5. 完整测试结果

### 5.1 先手动逐项验证

重新载入输出，避免复制错误资源名：

```bash
TF="${TERRAFORM:-terraform}"
SUB="$("$TF" -chdir=infra output -raw subscription_id)"
RG="$("$TF" -chdir=infra output -raw resource_group_name)"
EU_VM="$("$TF" -chdir=infra output -raw eu_workload_vm_name)"
REMOTE_VM="$("$TF" -chdir=infra output -raw remote_workload_vm_name)"
EU_NIC="$("$TF" -chdir=infra output -raw eu_workload_nic_name)"
REMOTE_NIC="$("$TF" -chdir=infra output -raw remote_workload_nic_name)"
EU_IP="$("$TF" -chdir=infra output -raw eu_workload_private_ip)"
REMOTE_IP="$("$TF" -chdir=infra output -raw remote_workload_private_ip)"
NEXT_HOP="$("$TF" -chdir=infra output -raw checkpoint_backend_private_ip)"
MANAGEMENT_IP="$("$TF" -chdir=infra output -raw checkpoint_management_private_ip)"
PUBLIC_IP="$("$TF" -chdir=infra output -raw checkpoint_public_ip)"
GATEWAY_VM="$("$TF" -chdir=infra output -raw checkpoint_vm_name)"
PACKAGE="$("$TF" -chdir=infra output -raw policy_package_name)"
WORKSPACE="$("$TF" -chdir=infra output -raw log_analytics_workspace_customer_id)"
ACCOUNT="$("$TF" -chdir=infra output -raw audit_storage_account_name)"
CONTAINER="$("$TF" -chdir=infra output -raw audit_container_name)"
```

T01/T02，分别确认 Active 默认路由下一跳为 `VirtualAppliance $NEXT_HOP`：

```bash
az network nic show-effective-route-table \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_NIC" \
  --query "value[?contains(addressPrefix, '0.0.0.0/0')].{prefix:addressPrefix,nextHop:nextHopType,nextHopIp:nextHopIpAddress,state:state}" \
  --output table

az network nic show-effective-route-table \
  --subscription "$SUB" --resource-group "$RG" --name "$REMOTE_NIC" \
  --query "value[?contains(addressPrefix, '0.0.0.0/0')].{prefix:addressPrefix,nextHop:nextHopType,nextHopIp:nextHopIpAddress,state:state}" \
  --output table
```

T03-T07，逐个在主 workload 执行流量命令，而不是一次性跑整个矩阵：

```bash
# T03：跨区域 TCP/8080，应输出 __DEMO_RESULT=T03:PASS。
az vm run-command invoke \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_VM" \
  --command-id RunShellScript --scripts @scripts/vm-case.sh \
  --parameters "arg1=T03" "arg2=$REMOTE_IP" "arg3=false" "arg4=unused" \
  --query "value[].message" --output tsv

# T04：允许 HTTPS。
az vm run-command invoke \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_VM" \
  --command-id RunShellScript --scripts @scripts/vm-case.sh \
  --parameters "arg1=T04" "arg2=-" "arg3=false" "arg4=unused" \
  --query "value[].message" --output tsv

# T05：阻断 example.com。
az vm run-command invoke \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_VM" \
  --command-id RunShellScript --scripts @scripts/vm-case.sh \
  --parameters "arg1=T05" "arg2=-" "arg3=false" "arg4=unused" \
  --query "value[].message" --output tsv

# T06：R81 在 HTTP 上验证 allowed/blocked path。
az vm run-command invoke \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_VM" \
  --command-id RunShellScript --scripts @scripts/vm-case.sh \
  --parameters "arg1=T06" "arg2=-" "arg3=false" "arg4=unused" \
  --query "value[].message" --output tsv

# T07：当前 R81 配置关闭 TLS Inspection，应明确输出 SKIP，不得记作 PASS。
az vm run-command invoke \
  --subscription "$SUB" --resource-group "$RG" --name "$EU_VM" \
  --command-id RunShellScript --scripts @scripts/vm-case.sh \
  --parameters "arg1=T07" "arg2=-" "arg3=false" "arg4=unused" \
  --query "value[].message" --output tsv
```

T08/T09/T15，通过仓库私钥检查 rulebase、Log Exporter 和 guest release：

```bash
ssh \
  -i .local/checkpoint-demo-ssh \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=.local/known_hosts \
  "admin@$MANAGEMENT_IP" \
  bash -s -- "$PACKAGE" R81 \
  <scripts/inspect-checkpoint.sh
```

输出中应同时出现 `CloudGuard Demo - Block Geo Outbound`、`CloudGuard Demo - Block Geo
Inbound`、`azure-monitor` 和 `Product version Check Point Gaia R81`。

T10-T12，检查日志摄取、WORM policy 和 EU 资源位置：

```bash
az monitor log-analytics query \
  --subscription "$SUB" \
  --workspace "$WORKSPACE" \
  --analytics-query "Syslog | where TimeGenerated > ago(2h) | where SyslogMessage has_any ('Check Point', 'action', 'product') | take 20" \
  --output table

az storage container immutability-policy show \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --account-name "$ACCOUNT" \
  --container-name "$CONTAINER" \
  --output json

az resource list \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --query "[].{name:name,type:type,location:location}" \
  --output table
```

T13 启用严格限源 DNAT 时，从 tfvars 批准的来源执行：

```bash
curl -fsS --connect-timeout 10 --max-time 30 "http://${PUBLIC_IP}:18080/"
```

应返回主 workload 页面。T14 确认精确 Gallery image 且 `plan=null`：

```bash
az vm show \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --name "$GATEWAY_VM" \
  --query "{imageId:storageProfile.imageReference.id,plan:plan}" \
  --output json
```

T16 在 T03 后确认远端 workload 看到原始 `$EU_IP`，而非 Gateway Hide NAT 地址：

```bash
az vm run-command invoke \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --name "$REMOTE_VM" \
  --command-id RunShellScript \
  --scripts "journalctl -u demo-web.service --since '10 minutes ago' --no-pager | grep -F '$EU_IP'" \
  --query "value[].message" \
  --output tsv
```

### 5.2 再运行完整自动矩阵

当前流程可拆成两个独立阶段。第一阶段部署结束后保留
`.local/latest-deployment-outputs.json`。第二阶段不依赖原 Terraform state，但仍需要：

- 该 outputs 文件和可访问客户订阅的 Azure CLI 身份。
- 部署时的 `.local/checkpoint-demo-ssh` 私钥。
- 执行机位于 management subnet，或能通过获批 VPN/私网路由访问
  `checkpoint_management_private_ip`。

基础部署已完成、但尚未创建 Check Point policy 时，在完成 BYOL 激活后，从 management
私网先运行保留自动化，再独立执行验证：

```bash
CHECKPOINT_SKIP_POLICY_CONFIGURATION=false \
  CHECKPOINT_TRANSPORT=ssh \
  ./scripts/configure-policy.sh \
  --outputs-file .local/latest-deployment-outputs.json

./scripts/validate-existing.sh \
  --outputs-file .local/latest-deployment-outputs.json \
  --expected-release R81
```

如果 policy 已由人工流程配置，直接运行 `validate-existing.sh`。
仅在测试订阅会删除 TCP/22 rule 时，额外设置
`CHECKPOINT_RECONCILE_SSH_RULE=true`。生成目录中的 `report.html` 包含部署配置、
Firewall rules、结果表、每项测试的执行机器、具体命令、实际观察和 Firewall 日志；
脚本 trace 不进入客户报告。`summary.json` 与
`configuration.json` 便于机器归档。任何 `FAIL` 或 `PENDING_INGESTION` 都必须处理后重跑；
只有未启用功能可记录 `SKIP`。T17 额外验证 `eth0` 管理 NSG 的 4 条 Allow rule、
显式 Deny、management NIC 绑定，以及数据平面 NSG 没有公网管理入口。
如果 R81 已通过 SmartConsole bootstrap 启用 TLS，第二阶段还必须传入
`--ca-file <SMARTCONSOLE_EXPORTED_PUBLIC_CA>`；测试订阅临时恢复 SSH rule 时，T17 明确记录
`RECONCILED`，不会把随后删除的 rule 伪记为普通 PASS。

### 5.3 2026-08-30 复测结果

使用本节步骤从空 state 部署 R81 无 Plan Gallery version，并先人工逐条执行 T01-T16：

```text
evidence/20260830T134155Z-manual-r81/manual-summary.json
```

人工结果为 **15 PASS / 1 SKIP**，并额外确认 `management_cidrs` 同时匹配 Azure NSG 与
R81 GUI Clients。随后运行完整自动矩阵：

```text
evidence/20260830T135622Z/summary.json
```

自动结果同样为 **15 PASS / 1 SKIP**。唯一 SKIP 是未启用 SmartConsole HTTPS
Inspection bootstrap 的 T07。最后 Terraform 销毁 57 个资源，并永久清除 Log
Analytics soft-delete 副本；`cleanup-summary.json` 记录 Resource Group 不存在、
Terraform state 为 0、soft-delete workspace 为 0。

### 5.4 历史验证结果

最终自动矩阵证据目录：

```text
evidence/20260829T211512Z/
```

| ID | 结果 | 说明 |
| --- | --- | --- |
| T01 | PASS | 主 workload 默认路由指向 NVA |
| T02 | PASS | 远端 workload 默认路由指向 NVA |
| T03 | PASS | 跨区域 TCP/8080 |
| T04 | PASS | 允许 HTTPS |
| T05 | PASS | 域名阻断 |
| T06 | PASS | R81 HTTP URL path 阻断 |
| T07 | SKIP | R81 GA/API 1.7 未完成 SmartConsole TLS bootstrap |
| T08 | PASS | Geo/L7 rulebase |
| T09 | PASS | Log Exporter Running |
| T10 | PASS | Log Analytics 摄取 |
| T11 | PASS | 365 天 Immutability Policy |
| T12 | PASS | 资源只在批准 EU region/global |
| T13 | PASS | 严格限源 TCP/18080 DNAT |
| T14 | PASS | 精确 image version、VM `plan=null` |
| T15 | PASS | Guest 为 Gaia R81 |
| T16 | PASS | 东西向保留原 workload 源 IP |

结果为 **15 PASS / 1 SKIP**。T07 没有伪装成 PASS。

运行：

```bash
export CHECKPOINT_RECONCILE_SSH_RULE=true
./scripts/run-tests.sh
```

## 6. T13 入站 DNAT

只从当前批准出口测试：

```hcl
enable_inbound_demo      = true
inbound_demo_source_cidr = "<CURRENT_PUBLIC_IPV4>/32"
```

重新 apply 和安装 policy：

```bash
./scripts/plan.sh --var-file "<R81_TFVARS>"
terraform -chdir=infra apply \
  -input=false -auto-approve \
  "$(pwd)/.local/plan.tfplan"

CHECKPOINT_RECONCILE_SSH_RULE=true ./scripts/configure-policy.sh
./scripts/run-tests.sh
```

直接复查：

```bash
curl -fsS "http://<GATEWAY_PUBLIC_IP>:18080/"
```

预期返回主 workload 页面。可选入站 allow 是 Geo Inbound 前的窄例外，必须同时命中
Azure NSG 和 Check Point Policy 中相同的 `/32`，且只开放 TCP/18080。其他来自
`blocked_countries` 的入站流量继续被 Geo rule 拒绝。

测试后把 `enable_inbound_demo=false`，重新 apply 和安装 policy，移除公网入口。

## 7. R81 HTTPS Inspection：支持的非 API 路径

### 结论

R81 GA 映射到 Management API 1.7。现场 schema 不包含：

- `add/import/show/set-outbound-inspection-certificate`
- Gateway `enable-https-inspection`

R81 Jumbo 只把 API 提升到 1.7.1，不能补齐这些接口。厂商支持的 R81 GA 路径是
**SmartConsole 人工 bootstrap**；没有验证到受支持的纯 headless CLI 路径。

不要使用猜测的 `dbedit` 字段、`set generic-object`、私有 SmartConsole endpoint、
直接修改 `objects_5_0.C` 或 UI automation。这些方式不应作为成功测试证据。

### SmartConsole bootstrap

使用与 R81 匹配的 SmartConsole，并从 `management_cidrs` 中任一来源连接 standalone Management：

1. **Gateways & Servers** → 编辑 standalone Gateway → **HTTPS Inspection**。
2. Step 1 选择：
   - **Create**：填写 Issued by (DN)、私钥密码、有效期；或
   - **Import**：导入包含私钥的客户 CA/P12 并输入密码。
3. 使用 **Export certificate** 导出只含公钥的客户端 trust certificate。
4. Step 3 选择 **Enable HTTPS Inspection**。
5. **Menu → Manage policies and layers**，编辑 package，启用
   **Access Control & HTTPS Inspection**。
6. 在 HTTPS Inspection rulebase 中先添加必要 Bypass，再添加 outbound Inspect rule：
   - Source：受保护网络
   - Destination：Internet
   - Service：HTTPS
   - Action：Inspect
   - Certificate：Outbound Certificate
   - Track：Log
   - Install On：standalone Gateway
7. Publish 并 Install Access Control policy。

### 让仓库继续安装 CA trust 并执行 T07

完成 SmartConsole 配置后，把 tfvars 改为：

```hcl
enable_tls_inspection       = true
r81_tls_manually_configured = true
```

然后：

```bash
export CHECKPOINT_TLS_CA_FILE="<SMARTCONSOLE_EXPORTED_PUBLIC_CA>"
export CHECKPOINT_RECONCILE_SSH_RULE=true

./scripts/plan.sh --var-file "<R81_TFVARS>"
terraform -chdir=infra apply \
  -input=false -auto-approve \
  "$(pwd)/.local/plan.tfplan"
./scripts/configure-policy.sh
./scripts/run-tests.sh
```

`configure-policy.sh` 接受 PEM 或 DER X.509 公钥证书，安装到两台 workload；R81 policy
脚本保留 SmartConsole 管理的 CA、Gateway HTTPS setting、layer 和 Inspect rule。
T07 从该 CA 的 RFC2253 subject 推导期望 issuer，必须与实际被拦截连接的 leaf
certificate issuer 匹配才算 PASS；导入企业 CA 时不强制其 subject 等于
`company_domain`。

R81 的 `$FWDIR/bin/export_https_cert -local -f <file>` 是 Management Server 之间迁移
加密 CA/private-key package 的命令，不是客户端 public trust export，不能代替
SmartConsole 的 **Export certificate**。

### 可自动化升级选项

- R81.20/API 1.9：支持导入外部 P12、启用 Gateway HTTPS Inspection 和 generic HTTPS
  layer；自动化必须另外保留/分发该 P12 的 public certificate。
- R82/API 2：支持完整 outbound CA API、显式 inbound/outbound layers 和
  `base64-public-certificate`，是完整 headless 流程的首选。

R81 → R81.20 是支持的 standalone 直接升级路径，但升级前必须完成 backup、
Pre-Upgrade Verifier、磁盘空间检查、关闭 SmartConsole sessions，并按 CPUSE 官方流程
执行；不要把升级混入镜像发布脚本。

## 8. 清理与保留

测试结束后销毁本次 Terraform 部署的全部 Demo 资源：

```bash
TF="${TERRAFORM:-terraform}"
RG="$("$TF" -chdir=infra output -raw resource_group_name)"
SUB="$("$TF" -chdir=infra output -raw subscription_id)"
COLLECTOR="$("$TF" -chdir=infra output -raw collector_vm_name)"
WORKSPACE_ID="$("$TF" -chdir=infra output -raw log_analytics_workspace_id)"
WORKSPACE="${WORKSPACE_ID##*/}"

# Azure 不允许从 deallocated VM 删除 Terraform 管理的 Monitor Agent extension。
if [[ "$(az vm get-instance-view \
  --subscription "$SUB" \
  --resource-group "$RG" \
  --name "$COLLECTOR" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" \
  --output tsv)" != "PowerState/running" ]]; then
  az vm start \
    --subscription "$SUB" \
    --resource-group "$RG" \
    --name "$COLLECTOR"
fi

CONFIRM_DESTROY="$RG" \
  ./scripts/destroy.sh --var-file configs/r81-e2e.tfvars

# 必须输出 false；state list 和 soft-delete 查询必须为空。
az group exists --subscription "$SUB" --name "$RG"
"$TF" -chdir=infra state list
az monitor log-analytics workspace list-deleted-workspaces \
  --subscription "$SUB" \
  --query "[?name=='$WORKSPACE' && resourceGroup=='$RG']"
```

不要执行 `lock-worm.sh --yes`；WORM policy 保持 `Unlocked` 才能正常销毁。上述命令删除
本次 Demo Resource Group 内的 Gateway、workload、日志、网络和存储资源，但不会删除
预先存在、作为镜像源使用的 `custom-images` Gallery definition/version。
AzureRM 会在 Resource Group 仍存在时永久删除 Log Analytics workspace，不保留默认
14 天 soft-delete 副本；该数据删除不可逆。

## 9. 官方参考

- R81 HTTPS Inspection：
  <https://sc1.checkpoint.com/documents/R81/WebAdminGuides/EN/CP_R81_SecurityManagement_AdminGuide/Topics-SECMG/HTTPS-Inspection.htm>
- Management API version matrix：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/api_versions.html>
- API 1.9 changes：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v1.9/dynamic/changes.json>
- API 2 changes：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/dynamic/changes.json>
- R81 `dbedit` warning：
  <https://sc1.checkpoint.com/documents/R81/WebAdminGuides/EN/CP_R81_SecurityManagement_AdminGuide/Topics-SECMG/CLI/dbedit.htm>
- R81.20 supported upgrade paths：
  <https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_RN/Content/Topics-RN/Supported-Upgrade-Paths.htm>
- R81.20 CPUSE upgrade：
  <https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_Installation_and_Upgrade_Guide/Content/Topics-IUG/Upgrading-Mmgt-Server-or-Log-Server-from-R80_20-and-higher-with-CPUSE.htm>
