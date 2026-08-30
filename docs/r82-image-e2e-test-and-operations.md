# R82 有 Plan 镜像端到端测试与操作参考

验证时间：2026-08-28 至 2026-08-29 UTC

本文是私有镜像目录中 R82 操作记录的可提交副本，记录已实际执行的 Azure Compute
Gallery 发布、custom image 部署、自动 HTTPS Inspection、功能测试、R81/R82 并存
规则和清理步骤。文档只使用占位符；VHD、真实订阅 ID、SAS 和凭据不得提交。

## 1. 已验证镜像

| 字段 | 值 |
| --- | --- |
| 源 | Azure Global `checkpoint:check-point-cg-r82:mgmt-byol:8200.900779.2061` |
| 归档 | `cloudguard-r82-mgmt-byol-82009007792061.vhd.tar.gz` |
| SHA-256 | `53288f2427fd7d68e21340e3d23e922d18299439188d88392162fbe55f80c8ab` |
| VHD | fixed、`107374182912` bytes、Hyper-V V1、Linux、Generalized |
| Gallery definition | `cloudguard-r82-mgmt-byol` |
| Gallery version | `82.0.2061` |
| Purchase plan | `checkpoint:check-point-cg-r82:mgmt-byol` |
| 已完成副本 | Southeast Asia、North Europe |
| Guest | Check Point Gaia R82、x86_64 |
| Management API | 2 |

如果本地私有镜像目录存在，先校验：

```bash
cd cloudguard-images
shasum -a 256 -c MANIFEST.sha256
./process/verify-images.sh
cd ..
```

## 2. Plan 是强制条件

该 VHD 来自 Azure Marketplace。以下可见位置即使均显示 `purchasePlan=null`，Azure
Compute 仍通过内部 Marketplace 来源指纹识别它：

- VHD footer、GPT 和 Gaia filesystem
- Page Blob metadata
- 导入后的 Managed Disk
- 无 Plan Gallery definition/version

实测结果：

| 尝试 | 结果 |
| --- | --- |
| R82 VHD → 无 Plan Gallery version → VM | `VMMarketplaceInvalidInput` |
| R82 VHD → Managed Disk Attach → VM | `VMMarketplaceInvalidInput` |
| R82 VHD → 保留原始 Plan 的 Gallery version → VM | 成功 |

不能通过删除 Gallery `purchasePlan`、改成 OS disk attach、修改 VHD footer/UUID 或系统
文件绕过。每个部署订阅仍需接受 Marketplace terms，并满足 Azure Policy、商务市场和
Check Point BYOL 许可要求。

## 3. 发布到 Azure Compute Gallery

仓库脚本会校验归档 SHA、单一 tar member、512-byte alignment、`conectix` footer 和
VHD disk type `Fixed (2)`。R82 必须传入完整且精确的 Plan：

```bash
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"

az vm image terms accept \
  --subscription "$SUBSCRIPTION_ID" \
  --publisher checkpoint \
  --offer check-point-cg-r82 \
  --plan mgmt-byol \
  --only-show-errors \
  -o none

./scripts/publish-vhd-image.sh \
  --archive cloudguard-images/r82-with-plan/cloudguard-r82-mgmt-byol-82009007792061.vhd.tar.gz \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group custom-images \
  --location southeastasia \
  --gallery czgallery \
  --definition cloudguard-r82-mgmt-byol \
  --version 82.0.2061 \
  --checkpoint-release R82 \
  --publisher checkpoint \
  --offer check-point-cg-r82 \
  --sku mgmt-byol \
  --target-region northeurope \
  --plan-publisher checkpoint \
  --plan-product check-point-cg-r82 \
  --plan-name mgmt-byol
```

现有 definition/version 已补齐：

```text
checkpoint-release=R82
marketplace-plan-required=true
source-sha256=53288f2427fd7d68e21340e3d23e922d18299439188d88392162fbe55f80c8ab
```

再次执行同一命令已实测只校验 metadata、SHA 和目标副本，并返回既有 version ID。
若改用 R82.10，必须同时使用 `--checkpoint-release R8210` 和
`--plan-product check-point-cg-r8210`，不能混用 R82 Plan。

## 4. 部署参数

创建 gitignored tfvars：

```hcl
subscription_id     = "<SUBSCRIPTION_ID>"
resource_group_name = "rg-checkpoint-r82-e2e"
prefix              = "cpr82"
company_domain      = "example.org"

management_cidr = "<CURRENT_PUBLIC_IPV4>/32"
location        = "northeurope"
remote_location = "westeurope"

checkpoint_os_version          = "R82"
checkpoint_image_id            = "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/custom-images/providers/Microsoft.Compute/galleries/czgallery/images/cloudguard-r82-mgmt-byol/versions/82.0.2061"
checkpoint_image_requires_plan = true
checkpoint_vm_size             = "Standard_F16s"

workload_vm_size  = "Standard_D4ls_v6"
collector_vm_size = "Standard_D4ls_v6"

enable_tls_inspection = true
```

部署：

```bash
export TERRAFORM="<PATH_TO_TERRAFORM_1_9_OR_NEWER>"
export TF_VAR_admin_ssh_public_key="$(tr -d '\r\n' < ~/.ssh/id_ed25519.pub)"

# Only use this opt-in if an organization policy removes the /32 SSH rule.
export CHECKPOINT_RECONCILE_SSH_RULE=true

./scripts/preflight.sh --var-file "<R82_TFVARS>"
./scripts/deploy.sh --var-file "<R82_TFVARS>"
```

部署脚本接受 `checkpoint:check-point-cg-r82:mgmt-byol` terms，并把相同 Plan 写入 VM。
Preflight 同时检查 definition Plan、Linux/Generalized/x64/Gen1、目标 region 副本和
请求的 VM SKU。

保持 `CHECKPOINT_TRANSPORT=auto`。Gaia first boot 会重启；SSH、Management API 和
`cp_log_export` 均 ready 后才配置 policy。若强制使用 Azure Run Command，extension
恰好跨越 FTW reboot 时可能留下 stale `Updating`。

## 5. R82 自动 HTTPS Inspection

R82/API 2 支持完整 headless 流程：

1. 创建/读取 `CloudGuardDemoOutboundCA`。
2. 从 API 返回 `base64-public-certificate`。
3. 启用 Gateway HTTPS Inspection。
4. 创建明确的 outbound HTTPS layer 和 Inspect rule。
5. Publish 并安装 Access Control policy。
6. 把 public CA 安装到两台 workload trust store。
7. T07 通过实际 TLS connection 检查 leaf issuer。

默认 CA `issued-by` 使用 `company_domain`。生产环境必须替换为企业批准的 CA/PKI
流程，规划 bypass、证书固定应用、QUIC/HTTP3、隐私评审、密钥轮换和终端信任分发。

不需要 R81 的：

```hcl
r81_tls_manually_configured = true
```

也不需要 `CHECKPOINT_TLS_CA_FILE`。这两个入口只用于 R81 SmartConsole hybrid 模式。

## 6. 已执行的 custom image 端到端测试

2026-08-29 使用 generalized R82 Gallery version 在独立 Resource Group 和独立
Terraform state 中部署完整 standalone Demo，观察到：

| 检查项 | 结果 |
| --- | --- |
| VM image reference | 指向指定 Gallery version |
| VM Plan | `checkpoint:check-point-cg-r82:mgmt-byol` |
| Gaia first boot | `config_system` 完成 |
| 新 VM identity | 新 hostname、NIC 地址、SSH host keys 和 SIC key |
| Management API | Ready，policy publish/install 成功 |
| HTTPS Inspection | 自动创建 outbound CA，workload trust 安装成功 |
| Log Exporter | `azure-monitor` Running |
| Log Analytics | 出现本次 Gateway 日志 |
| Continuous Export | 成功写入未锁定 immutable container |
| Terraform convergence | 第二阶段只增加 Syslog data export rule |

当时脚本的 T01-T13 结果：

| ID | 结果 | 说明 |
| --- | --- | --- |
| T01 | PASS | 主 workload 默认路由指向 NVA |
| T02 | PASS | 远端 workload 默认路由指向 NVA |
| T03 | PASS | 跨区域 TCP/8080 |
| T04 | PASS | 允许 HTTPS |
| T05 | PASS | 域名阻断 |
| T06 | PASS | HTTPS URL path 阻断 |
| T07 | PASS | leaf issuer 为演示 CA |
| T08 | PASS | Geo/L7 rulebase |
| T09 | PASS | Log Exporter Running |
| T10 | PASS | Log Analytics 摄取 |
| T11 | PASS | 365 天 Immutability Policy |
| T12 | PASS | 资源只在批准 EU region/global |
| T13 | SKIP | 默认未启用入站 DNAT |

当时结果为 **12 PASS / 1 SKIP**。当前脚本后来增加：

- T14：精确 image reference 和 Plan tuple
- T15：Guest Gaia release
- T16：东西向保留 workload 源 IP

历史 R82 custom-image 记录已经分别观察到与 T14/T15 等价的 image/Plan 和 Gaia 字段；
T16 是之后新增的显式测试，未在同一次历史 R82 custom-image 运行中采集，因此本文不把
它伪记为 PASS。新部署应使用当前脚本重新生成完整 T01-T16 evidence：

```bash
export CHECKPOINT_RECONCILE_SSH_RULE=true
./scripts/run-tests.sh
```

`FAIL` 或 `PENDING_INGESTION` 都返回非零；只有明确未启用的功能记录 `SKIP`。

## 7. 可选 T13 入站 DNAT

只从客户批准来源测试：

```hcl
enable_inbound_demo      = true
inbound_demo_source_cidr = "<APPROVED_PUBLIC_IPV4>/32"
```

重新 apply 和安装 policy：

```bash
./scripts/plan.sh --var-file "<R82_TFVARS>"
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

入站 allow 同时受 Azure NSG 和 Check Point Policy 中相同的 `/32` 限制，只开放
TCP/18080，并作为 Geo Inbound 前的窄例外。测试后把 `enable_inbound_demo=false`，
重新 apply 和安装 policy，移除公网入口。

## 8. R81 与 R82 并存

| 项目 | R81 no Plan | R82 with Plan |
| --- | --- | --- |
| `checkpoint_os_version` | `R81` | `R82` |
| `checkpoint_image_requires_plan` | `false` | `true` |
| VM `plan` | `null` | 原始 Check Point Plan |
| Marketplace terms | 不由脚本接受 | 必须接受 |
| Gallery definition | 单独 definition | 单独 definition |
| HTTPS Inspection | SmartConsole hybrid 或关闭 | API 2 全自动 |
| URL pattern | R81 regex/DNS Domain 兼容路径 | R82 原生路径 |

两个 definition 可以位于同一 Gallery，但必须使用精确 version ID。发布脚本和
Preflight 的 `checkpoint-release`、`marketplace-plan-required` 标签会防止版本/Plan
模式混选。不要使用 definition 的 `latest` 隐式切换版本。

## 9. 清理与保留

Gallery version 验证后，可删除 upload disk 和临时 managed image；保留 Gallery
definition/version 及所需 region replicas。若还保留私有 VHD Blob，应继续禁用公网
data plane 和 shared-key access。

Demo 测试后 deallocate：

```bash
for VM in cpr82-gateway cpr82-eu-workload cpr82-remote-workload cpr82-log-collector; do
  az vm deallocate \
    --subscription "<SUBSCRIPTION_ID>" \
    --resource-group rg-checkpoint-r82-e2e \
    --name "$VM" \
    --no-wait
done
```

若不再需要环境：

```bash
CONFIRM_DESTROY="$(
  terraform -chdir=infra output -raw resource_group_name
)" ./scripts/destroy.sh --var-file "<R82_TFVARS>"
```

WORM policy 默认 `Unlocked`。不要仅为测试执行 `lock-worm.sh --yes`；Locked 后在保留
期内可能阻止 Terraform destroy。

## 10. 官方参考

- Check Point CloudGuard Azure image export：
  <https://sc1.checkpoint.com/documents/IaaS/WebAdminGuides/EN/CP_CloudGuard_Network_for_Azure_HA_Cluster/Content/Topics-Azure-HA/Export_Image.htm>
- Check Point Management API version matrix：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/api_versions.html>
- Check Point API 2 changes：
  <https://sc1.checkpoint.com/documents/latest/APIs/data/v2/dynamic/changes.json>
- Azure Marketplace images and purchase plans：
  <https://learn.microsoft.com/azure/virtual-machines/marketplace-images>
- Azure Compute Gallery：
  <https://learn.microsoft.com/azure/virtual-machines/shared-image-galleries>
