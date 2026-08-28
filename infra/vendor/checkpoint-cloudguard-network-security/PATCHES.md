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
