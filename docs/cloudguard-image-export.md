# CloudGuard Marketplace 镜像导出与 Custom Image Runbook

本文记录如何把 Check Point CloudGuard `mgmt-byol` Marketplace image 保存为
VHD，并发布到 Azure Compute Gallery。所有命令都使用占位符；不要把真实
subscription、tenant、用户、SAS URL、SIC key 或完整 image ID 提交到仓库。

## 结论与适用边界

用于重复部署的镜像应从**从未启动的 Marketplace 基础 image**创建。不要捕获已经
配置或运行过的 Gateway：

| 来源 | Azure image state | 适合重复部署 | 状态处理 |
| --- | --- | --- | --- |
| 未启动的 Marketplace 基础 image | `Generalized` | 是 | 每台新 VM 执行首次 provisioning |
| 已配置 VM 或其 OS disk | `Specialized` | 否 | 原机 hostname、账户、keys、证书、SIC、策略、许可证状态和日志会被复制 |
| 对已配置 VM 只运行 `waagent -deprovision+user` | 不足以证明安全 | 否 | Microsoft 明确说明该命令不保证清除全部敏感信息 |

Check Point 的
[VHD 导出文档](https://sc1.checkpoint.com/documents/IaaS/WebAdminGuides/EN/CP_CloudGuard_Network_for_Azure_HA_Cluster/Content/Topics-Azure-HA/Export_Image.htm)
说明如何导出完整 OS disk，但没有声明已初始化 Gaia Gateway 会被 generalized 或
sanitized。已经配置的 VM 只能按包含全部原机状态的备份处理。

## 先决条件

- Azure CLI、AzCopy、Terraform `>= 1.9`、`jq`。
- 对 image resource group、Compute Gallery 和临时磁盘的管理权限。
- 目标订阅已接受 Check Point Marketplace 条款。
- Check Point BYOL entitlement。
- 跨订阅部署时，目标订阅也能接受相同 Marketplace plan。
- 跨客户或跨租户分发前，已取得 Check Point 或授权合作伙伴的书面许可确认。

## 变量

```bash
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"
IMAGE_RG="<IMAGE_RESOURCE_GROUP>"
LOCATION="<SOURCE_REGION>"
REPLICA_REGION="<SECOND_REGION>"

GALLERY="<GALLERY_NAME>"
IMAGE_DEFINITION="<IMAGE_DEFINITION_NAME>"
IMAGE_VERSION="1.0.0"

SOURCE_VERSION="<EXACT_MARKETPLACE_VERSION>"
SOURCE_URN="checkpoint:check-point-cg-r82:mgmt-byol:${SOURCE_VERSION}"
SOURCE_DISK="<TEMP_SOURCE_DISK_NAME>"
BRIDGE_IMAGE="<TEMP_MANAGED_IMAGE_NAME>"

STORAGE_ACCOUNT="<GLOBALLY_UNIQUE_STORAGE_ACCOUNT>"
VHD_CONTAINER="vhds"
VHD_NAME="checkpoint-r82-mgmt-byol-${SOURCE_VERSION}.vhd"
```

固定 `SOURCE_VERSION`，不要在 image pipeline 中使用不可复现的 `latest`。

## 1. 验证 Marketplace image 和条款

```bash
az vm image terms accept \
  --subscription "$SUBSCRIPTION_ID" \
  --publisher checkpoint \
  --offer check-point-cg-r82 \
  --plan mgmt-byol \
  --only-show-errors \
  -o none

az vm image show \
  --subscription "$SUBSCRIPTION_ID" \
  --location "$LOCATION" \
  --urn "$SOURCE_URN" \
  --query '{
    name:name,
    location:location,
    architecture:architecture,
    hyperVGeneration:hyperVGeneration,
    os:osDiskImage.operatingSystem,
    plan:plan
  }'
```

预期值：

```text
architecture      = x64
hyperVGeneration  = V1
os                 = Linux
plan.publisher     = checkpoint
plan.product       = check-point-cg-r82
plan.name          = mgmt-byol
```

## 2. 创建从未启动的基础磁盘

直接从 Marketplace image 创建 managed disk，不创建 VM，也不运行首次启动：

```bash
az disk create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$SOURCE_DISK" \
  --location "$LOCATION" \
  --image-reference "$SOURCE_URN" \
  --sku Standard_LRS \
  --os-type Linux \
  --hyper-v-generation V1 \
  --tags purpose=cloudguard-image-source source=azure-marketplace

SOURCE_DISK_ID="$(
  az disk show \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$SOURCE_DISK" \
    --query id \
    -o tsv
)"
```

该磁盘不能附加到 VM。只要它被启动或作为 OS disk 使用，就不能再假定其中没有
运行时身份和日志。

## 3. 创建 Compute Gallery image definition

如 Gallery 尚不存在：

```bash
az sig create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --location "$LOCATION"
```

创建 definition 时必须保留原始 Marketplace purchase plan：

```bash
az sig image-definition create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --location "$LOCATION" \
  --publisher checkpoint \
  --offer check-point-cg-r82 \
  --sku mgmt-byol \
  --os-type Linux \
  --os-state Generalized \
  --hyper-v-generation V1 \
  --architecture x64 \
  --plan-publisher checkpoint \
  --plan-product check-point-cg-r82 \
  --plan-name mgmt-byol
```

## 4. 发布 image version

当前 Azure CLI 的 Gallery 命令通过 managed image 输入最稳定，因此创建一个临时
bridge image：

```bash
az image create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$BRIDGE_IMAGE" \
  --location "$LOCATION" \
  --source "$SOURCE_DISK_ID" \
  --os-type Linux \
  --hyper-v-generation V1 \
  --storage-sku Standard_LRS \
  --tags purpose=temporary-gallery-source

BRIDGE_IMAGE_ID="$(
  az image show \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$BRIDGE_IMAGE" \
    --query id \
    -o tsv
)"

az sig image-version create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" \
  --location "$LOCATION" \
  --managed-image "$BRIDGE_IMAGE_ID" \
  --target-regions \
    "${LOCATION}=1=standard_lrs" \
    "${REPLICA_REGION}=1=standard_lrs" \
  --replica-count 1 \
  --storage-account-type Standard_LRS
```

检查复制状态：

```bash
az sig image-version show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" \
  --expand ReplicationStatus \
  --query '{
    id:id,
    provisioningState:provisioningState,
    replication:replicationStatus
  }'
```

只有 `provisioningState=Succeeded` 且目标区域复制为 `Completed` 后才能部署。

## 5. 导出 VHD

先创建私有 Blob container。存储账户应禁用 anonymous blob access 和 shared-key
access；如果组织 Policy 禁止 public data plane，使用 Private Endpoint 和具有
`Storage Blob Data Contributor` 的 managed identity。

管理面创建 container 的示例：

```bash
STORAGE_ACCOUNT_ID="$(
  az storage account show \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$STORAGE_ACCOUNT" \
    --query id \
    -o tsv
)"

az rest \
  --method put \
  --url "https://management.azure.com${STORAGE_ACCOUNT_ID}/blobServices/default/containers/${VHD_CONTAINER}?api-version=2023-05-01" \
  --body '{"properties":{"publicAccess":"None"}}'
```

在能访问 Blob endpoint 的 x64 runner 上执行复制。不要打印或保存临时 disk SAS：

```bash
SOURCE_SAS="$(
  az disk grant-access \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$SOURCE_DISK" \
    --access-level Read \
    --duration-in-seconds 14400 \
    --query accessSAS \
    -o tsv
)"

cleanup_sas() {
  az disk revoke-access \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$SOURCE_DISK" \
    --only-show-errors \
    -o none
}
trap cleanup_sas EXIT

azcopy login --identity
azcopy copy \
  "$SOURCE_SAS" \
  "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${VHD_CONTAINER}/${VHD_NAME}" \
  --from-to BlobBlob \
  --overwrite=true \
  --check-length=true

cleanup_sas
trap - EXIT
```

需要在 x64 VM 数据盘上另存一份时：

```bash
install -d -m 700 /data/cloudguard-images

azcopy login --identity
azcopy copy \
  "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${VHD_CONTAINER}/${VHD_NAME}" \
  "/data/cloudguard-images/${VHD_NAME}" \
  --from-to BlobLocal \
  --overwrite=true \
  --check-length=true

chmod 600 "/data/cloudguard-images/${VHD_NAME}"
sha256sum "/data/cloudguard-images/${VHD_NAME}"
```

Apple Silicon Mac 可以保存 VHD，但不能直接启动这个 x64/Gen1 Gaia image。后续启动
测试应在 Azure x64 VM 上进行。

## 6. Terraform 使用方式

默认配置不填写 `checkpoint_image_id`，继续使用 Marketplace：

```hcl
# checkpoint_image_id = ""
```

自定义 Gallery version 示例：

```hcl
checkpoint_image_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r82-byol/versions/1.0.0"
```

代码仍向 VM 传入：

```text
publisher = checkpoint
product   = check-point-cg-r82
name      = mgmt-byol
```

因此 custom image 不能绕过 Marketplace terms、Azure Policy 或商务市场限制。

## 7. 端到端验收

至少检查：

1. Terraform preflight 识别 image 为 `Generalized`、Linux、x64、Gen1，并确认目标区域副本。
2. VM 的 image reference 是指定 Gallery ID，同时 VM plan 仍为 `mgmt-byol`。
3. Gaia 首次 provisioning 完成，使用本次输入的 SSH key 登录 `admin`。
4. hostname、两块 NIC IP 和 SSH host keys 属于新 VM。
5. `notused` 占位用户不存在，`admin` 密码未启用。
6. Management API 可用，Access Policy 可以发布并安装。
7. 两个 workload 的有效路由指向新 Gateway backend IP。
8. 允许、阻断、HTTPS Inspection、Geo-IP 和东西向测试符合预期。
9. Log Exporter、Log Analytics 和未锁定的 Immutability Policy 状态正确。

执行：

```bash
./scripts/preflight.sh --var-file configs/demo.tfvars
./scripts/deploy.sh --var-file configs/demo.tfvars
./scripts/run-tests.sh
```

保持默认 `CHECKPOINT_TRANSPORT=auto`。它会使用自动生成的
`.local/checkpoint-demo-ssh`，并在当前出口位于 `management_cidrs` 首项时优先使用
受限 SSH；不要仅为了 custom image 强制选择 `run-command`。Gaia FTW 会在首次启动中
重启，Azure Run Command extension 如果恰好跨越该窗口，可能无法完成安装。

`PENDING_INGESTION` 不是通过；等待 Log Analytics 完成 ingestion 后重新执行
`run-tests.sh`。

## 8. 删除中间资源

Gallery version 和 VHD 都完成后，可以删除 bridge image 和基础磁盘：

```bash
az image delete \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$BRIDGE_IMAGE"

az disk delete \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$SOURCE_DISK" \
  --yes
```

不要删除需要保留的 Gallery version、Private Blob 或 x64 runner 数据盘副本。

## 9. 共享限制

- 同一 tenant 内可通过 RBAC 向用户、组或 service principal 授予 image/gallery
  `Reader`。
- 跨 subscription 或 tenant 的目标订阅仍需接受原始 Marketplace terms。
- 技术上可共享不代表 Check Point 服务订单或 EULA 授予跨客户分发权。
- 未取得书面确认前，不要把 image 或 VHD 共享给外部客户。

参考：

- [Azure generalized and specialized images](https://learn.microsoft.com/azure/virtual-machines/shared-image-galleries#generalized-and-specialized-images)
- [Azure Marketplace purchase plan](https://learn.microsoft.com/azure/virtual-machines/marketplace-images)
- [Azure VM generalization](https://learn.microsoft.com/azure/virtual-machines/generalize)
