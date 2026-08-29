# 可选：从本地 tar.gz 发布 Azure Compute Gallery 镜像

本文是独立的可选材料，说明如何把本地已有的 `tar.gz` 解压为 VHD、上传到私有
Azure Page Blob，再发布为 Azure Compute Gallery image version 并复制到多个
region。仓库的默认部署仍使用 Marketplace image；只有需要自定义镜像时才执行本文。

所有命令均使用占位符，不包含真实文件名、路径、订阅或 Azure 资源信息。

## 前提与边界

- 压缩包内只有一个**固定大小、已经 generalized 的 `.vhd`**；VHDX 和动态 VHD
  不能直接使用。
- 必须提前确认 OS 类型、CPU 架构和 Hyper-V generation。不要通过填写 definition
  参数来掩盖源 VHD 不匹配。
- 不要发布从已配置 VM 直接捕获的镜像，否则可能复制 hostname、账户、SSH keys、
  证书、策略、许可证状态和日志。
- Marketplace 派生镜像必须保留原始 purchase plan，部署订阅仍须接受 Marketplace
  条款。跨客户分发前还要取得软件厂商或授权合作伙伴的书面许可。
- 压缩包、VHD、校验文件和 AzCopy 日志应保存在 Git checkout 之外。

需要 Bash、Azure CLI、AzCopy v10、`tar`，以及目标资源组内的 Gallery/Image/
Storage 管理权限。上传身份还需要 Storage Account 上的
`Storage Blob Data Contributor`。

## 1. 设置参数并解压

```bash
SUBSCRIPTION_ID="<SUBSCRIPTION_ID>"
LOCATION="<SOURCE_REGION>"
IMAGE_RG="<IMAGE_RESOURCE_GROUP>"

ARCHIVE_PATH="<PATH_TO_IMAGE_TAR_GZ>"
WORK_DIR="<TEMP_DIRECTORY_OUTSIDE_GIT>"
VHD_NAME="<IMAGE_FILE_NAME>.vhd"
VHD_PATH="${WORK_DIR}/${VHD_NAME}"

STORAGE_ACCOUNT="<GLOBALLY_UNIQUE_STORAGE_ACCOUNT>"
CONTAINER="vhds"
BRIDGE_IMAGE="<TEMPORARY_MANAGED_IMAGE_NAME>"

GALLERY="<GALLERY_NAME>"
IMAGE_DEFINITION="<IMAGE_DEFINITION_NAME>"
IMAGE_VERSION="<MAJOR.MINOR.PATCH>"

OS_TYPE="Linux"
OS_STATE="Generalized"
HYPER_V_GENERATION="<V1_OR_V2>"
ARCHITECTURE="x64"
```

先确认归档只包含预期 VHD，再解压：

```bash
test -f "$ARCHIVE_PATH"
test "$(tar -tzf "$ARCHIVE_PATH")" = "$VHD_NAME"

mkdir -p "$WORK_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"
test -f "$VHD_PATH"

VHD_SIZE_BYTES="$(wc -c < "$VHD_PATH" | tr -d ' ')"
test "$((VHD_SIZE_BYTES % 512))" -eq 0
file "$VHD_PATH"
```

如有随包提供的 `.sha256`，应在解压前先校验。`512` 字节对齐只是必要条件；
还应按镜像厂商要求确认 VHD 是 fixed、generalized 且可在 Azure 启动。

## 2. 创建私有 Blob 并上传 VHD

登录并创建资源：

```bash
az login

az group create \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$IMAGE_RG" \
  --location "$LOCATION"

az storage account create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$STORAGE_ACCOUNT" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

az storage container create \
  --subscription "$SUBSCRIPTION_ID" \
  --account-name "$STORAGE_ACCOUNT" \
  --name "$CONTAINER" \
  --public-access off \
  --auth-mode login
```

如果容器命令返回 `403`，请让管理员给当前上传身份分配
`Storage Blob Data Contributor`，等待 RBAC 传播后重试。生产环境还应使用 Storage
firewall 或 Private Endpoint 限制网络来源。

使用 Entra ID 登录 AzCopy。VHD 必须明确上传为 `PageBlob`：

```bash
TENANT_ID="$(
  az account show \
    --subscription "$SUBSCRIPTION_ID" \
    --query tenantId \
    -o tsv
)"

VHD_URI="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${VHD_NAME}"

azcopy login --tenant-id "$TENANT_ID"
azcopy copy \
  "$VHD_PATH" \
  "$VHD_URI" \
  --from-to LocalBlob \
  --blob-type PageBlob \
  --overwrite=false \
  --check-length=true
```

中断后可使用 `azcopy jobs list`、`azcopy jobs show <JOB_ID>` 和
`azcopy jobs resume <JOB_ID>` 恢复，不必从头上传。

验证类型和长度：

```bash
az storage blob show \
  --subscription "$SUBSCRIPTION_ID" \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "$VHD_NAME" \
  --auth-mode login \
  --query '{
    blobType:properties.blobType,
    contentLength:properties.contentLength
  }'
```

预期 `blobType=PageBlob`，且 `contentLength` 等于 `$VHD_SIZE_BYTES`。

## 3. 从私有 Blob 创建临时 managed image

为 Compute 服务生成短期只读 user-delegation SAS。`SAS_EXPIRY` 使用未来几小时内的
UTC 时间，例如 `YYYY-MM-DDTHH:MMZ`；不要打印、保存或提交生成的 URL。

```bash
SAS_EXPIRY="<SHORT_LIVED_UTC_EXPIRY>"

VHD_READ_URI="$(
  az storage blob generate-sas \
    --subscription "$SUBSCRIPTION_ID" \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$VHD_NAME" \
    --permissions r \
    --expiry "$SAS_EXPIRY" \
    --https-only \
    --as-user \
    --auth-mode login \
    --full-uri \
    -o tsv
)"

az image create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$BRIDGE_IMAGE" \
  --location "$LOCATION" \
  --source "$VHD_READ_URI" \
  --os-type "$OS_TYPE" \
  --hyper-v-generation "$HYPER_V_GENERATION" \
  --storage-sku Standard_LRS
```

检查临时 image，必须看到 `provisioningState=Succeeded`：

```bash
az image show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$BRIDGE_IMAGE" \
  --query '{
    id:id,
    provisioningState:provisioningState,
    osType:storageProfile.osDisk.osType,
    osState:storageProfile.osDisk.osState,
    hyperVGeneration:hyperVGeneration
  }'

BRIDGE_IMAGE_ID="$(
  az image show \
    --subscription "$SUBSCRIPTION_ID" \
    --resource-group "$IMAGE_RG" \
    --name "$BRIDGE_IMAGE" \
    --query id \
    -o tsv
)"
```

## 4. 创建 Gallery image definition

```bash
GALLERY_PUBLISHER="<GALLERY_PUBLISHER_LABEL>"
GALLERY_OFFER="<GALLERY_OFFER_LABEL>"
GALLERY_SKU="<GALLERY_SKU_LABEL>"

az sig create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --location "$LOCATION"
```

如果 VHD 来源于 Marketplace，先从原始 Marketplace image 或 VM 获取以下三个值，
不能猜测：

```bash
PLAN_PUBLISHER="<ORIGINAL_PLAN_PUBLISHER>"
PLAN_PRODUCT="<ORIGINAL_PLAN_PRODUCT>"
PLAN_NAME="<ORIGINAL_PLAN_NAME>"
```

创建 Marketplace 派生 definition：

```bash
az sig image-definition create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --location "$LOCATION" \
  --publisher "$GALLERY_PUBLISHER" \
  --offer "$GALLERY_OFFER" \
  --sku "$GALLERY_SKU" \
  --os-type "$OS_TYPE" \
  --os-state "$OS_STATE" \
  --hyper-v-generation "$HYPER_V_GENERATION" \
  --architecture "$ARCHITECTURE" \
  --plan-publisher "$PLAN_PUBLISHER" \
  --plan-product "$PLAN_PRODUCT" \
  --plan-name "$PLAN_NAME"
```

非 Marketplace 镜像应省略三个 `--plan-*` 参数。Gallery 的
`publisher/offer/sku` 是分类标签；Marketplace 的 `plan publisher/product/name`
是许可和计费元数据，两组字段不能互相替代。

部署 Marketplace 派生镜像的每个订阅仍需接受原始条款：

```bash
az vm image terms accept \
  --subscription "$SUBSCRIPTION_ID" \
  --publisher "$PLAN_PUBLISHER" \
  --offer "$PLAN_PRODUCT" \
  --plan "$PLAN_NAME"
```

## 5. 创建多区域 image version

每个目标项格式为 `region=replica-count=storage-account-type`。数组必须包含源区域：

```bash
TARGET_REGIONS=(
  "${LOCATION}=1=standard_lrs"
  "<SECOND_REGION>=1=standard_lrs"
  "<THIRD_REGION>=1=standard_lrs"
)

az sig image-version create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" \
  --location "$LOCATION" \
  --managed-image "$BRIDGE_IMAGE_ID" \
  --target-regions "${TARGET_REGIONS[@]}" \
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
    replicationStatus:replicationStatus
  }'
```

只有顶层 `provisioningState=Succeeded`，并且所有目标 region 的复制状态均为
`Completed` 后，才交给下游部署。

## 6. 在本仓库中使用

取得精确 version ID：

```bash
az sig image-version show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" \
  --query id \
  -o tsv
```

把结果写入**不提交**的 `configs/demo.tfvars`：

```hcl
checkpoint_image_id = "<GALLERY_IMAGE_VERSION_RESOURCE_ID>"
```

先运行 `./scripts/preflight.sh --var-file configs/demo.tfvars`，再部署。至少在一个目标
region 做非生产启动测试，确认新 VM 生成新的 hostname、网络身份和 host keys，
且不含源环境凭据、证书、策略、许可证状态或日志。

Gallery version 验证完成后，可删除临时 managed image；Page Blob 是否保留由备份
策略决定：

```bash
az image delete \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" \
  --name "$BRIDGE_IMAGE"
```

## 常见错误

| 现象 | 处理 |
| --- | --- |
| AzCopy 或 container 返回 `403` | 检查 Blob data-plane RBAC、RBAC 传播和 Storage firewall。 |
| Blob 是 `BlockBlob` | 删除错误对象，使用 `--blob-type PageBlob` 重新上传。 |
| `InvalidVhd` | 检查 fixed VHD、footer、文件长度和归档内容。 |
| `PurchasePlanMissing` | 保留原始 Marketplace plan，并在部署订阅接受相同条款。 |
| 目标 region 找不到 version | 等待 `ReplicationStatus` 为 `Completed`。 |
| VM SKU 无法使用 | 检查 VHD、definition 和 VM SKU 的 generation/architecture。 |

官方参考：
[AzCopy 上传 Blob](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-blobs-upload)、
[Azure CLI `az image`](https://learn.microsoft.com/cli/azure/image)、
[Azure Compute Gallery](https://learn.microsoft.com/azure/virtual-machines/shared-image-galleries)、
[Marketplace purchase plan](https://learn.microsoft.com/azure/virtual-machines/marketplace-images)。
