# Check Point module 本地 patch

上游版本：Check Point CloudGuard Network Security for Azure `v1.3.2`

上游 `commit`：`5ab8cec498bfe9e744890af0759e795baf3576ec`

## Patch 1：移除未使用的可用区校验

涉及文件：

- `modules/common/common/main.tf`
- `modules/common/common/outputs.tf`

上游只在 `is_zonal=true` 时创建 `regions` module 和 `null_resource`。本演示固定
`zone=""`，因此这条路径的 `count` 始终为 0。本地副本移除该 module、校验资源
和 `regions` output。

`scripts/preflight.sh` 在显式指定的订阅中检查两个区域和 VM SKU。移除未使用路径后，
`terraform init` 不需要下载 AzAPI、modtm 和 null Provider。

## Patch 2：继承根 module 的 Provider 认证

涉及文件：`modules/single-gateway/versions.tf`

```diff
-provider "azapi" {
-  subscription_id = var.subscription_id
-  client_id       = var.client_id
-  client_secret   = var.client_secret
-  tenant_id       = var.tenant_id
-}
-
-provider "azurerm" {
-  subscription_id = var.subscription_id
-  client_id       = var.client_id
-  client_secret   = var.client_secret
-  tenant_id       = var.tenant_id
-  features {}
-}
```

Provider 配置由根 module 管理。交互部署可以复用 Azure CLI 登录，CI 可以传入完整
Service Principal；两种方式都使用显式 `subscription_id`。根 module 只需要
AzureRM 和 Random Provider。Single Gateway 路径不使用 AzAPI。

AzureRM 版本从上游 `~> 4.73.0` 固定为现场使用的 `4.80.0`。

## Patch 3：保留 Azure Policy 添加的 Public IP tag

涉及文件：`modules/single-gateway/main.tf`

Gateway Public IP 增加：

```hcl
lifecycle {
  ignore_changes = [ip_tags]
}
```

部分订阅会通过 Azure Policy 在资源创建后添加 IP tag。AzureRM 把删除这些 tag
视为替换 Public IP，但已绑定 Gateway NIC 的 Public IP 不能直接删除。
`ignore_changes` 只忽略 Azure Policy 管理的 `ip_tags`，不忽略静态 IP、SKU、
资源组或网络配置。

## Patch 4：透传 Virtual Network ID

涉及文件：`modules/single-gateway/outputs.tf`

Single Gateway module 增加 `vnet_id` output，透传下层 VNet module 的资源 ID。
根 module 使用该 ID 创建 spoke-to-hub peering，使 Terraform 直接依赖实际 hub VNet，
避免手工拼接 ID 只依赖先创建完成的 Resource Group 而引发竞态。

## Patch 5：支持已有 custom image resource ID

涉及文件：

- `modules/single-gateway/variables.tf`
- `modules/single-gateway/locals.tf`
- `modules/single-gateway/main.tf`

上游只接受 Marketplace image 或 VHD URI，并在 VHD 路径内部创建 legacy managed
image。本地增加可选 `source_image_id`，允许根 module 直接传入 generalized managed
image、Azure Compute Gallery image definition 或 image version ID。

`source_image_requires_plan` 明确区分普通开发镜像与 Marketplace 派生镜像。后者部署
VM 时继续传入原始 Publisher、Offer 和 Plan，不能借 custom image 绕过 Marketplace
条款。`source_image_id` 与 `source_image_vhd_uri` 互斥。

## Patch 6：允许 R81 无 Plan custom image 参数

涉及文件：`modules/common/common/variables.tf`

上游 Global Marketplace 列表从 R81.10 开始，不接受 Azure China 的
`R81`/`cgi-mgmt-r81` 参数。根 module 只在显式选择无 Plan custom image 时允许
R81；本地校验同步接受这两个值，使相同的 `cloud-init` 首次配置参数能传给 R81
镜像。该 patch 不新增 R81 Global Marketplace 部署路径。
