# Terraform 模块本地副本

本目录保存当前配置使用的 Terraform module 源码。`terraform init` 仍从
Terraform Registry 下载 Provider，但不下载 Check Point module。

## 上游版本

| 组件 | 上游版本 | 精确 commit | 上游地址 | 许可证 |
| --- | --- | --- | --- | --- |
| Check Point CloudGuard Network Security for Azure | `v1.3.2` | `5ab8cec498bfe9e744890af0759e795baf3576ec` | <https://github.com/CheckPointSW/terraform-azure-cloudguard-network-security> | Apache-2.0 |

## 文件范围

目录只包含 Check Point Single Gateway 使用的依赖：

```text
checkpoint-cloudguard-network-security/
├── LICENSE
└── modules/
    ├── single-gateway/
    └── common/
        ├── common/
        ├── custom-image/
        ├── network-security-group/
        ├── storage-account/
        └── vnet/
```

目录不包含未使用的 High Availability、VMSS、MDS、Management、NVA module、
上游 README、example 和测试。

## 本地 patch

本地副本包含以下修改：

- `modules/common/common/main.tf`
  - 移除仅在 `zone != ""` 时使用的 Azure regions module 和 `null_resource` 校验
  - 本演示固定 `zone = ""`，`scripts/preflight.sh` 在目标订阅中检查区域和 VM SKU
  - 不为 `count=0` 的路径下载 AzAPI、modtm 和 null Provider
- `modules/single-gateway/versions.tf`
  - 上游：在子 module 内配置 AzureRM/AzAPI provider，并强制 client secret
  - 本地：只保留 `required_providers`，继承根 module Provider
  - 作用：根 module 可选择 Azure CLI 或完整 Service Principal 认证，并显式使用 `subscription_id`
  - AzureRM 从上游 `~> 4.73.0` 固定为现场使用的 `4.80.0`
- `modules/single-gateway/{variables,locals,main}.tf`
  - 增加已有 managed image 或 Azure Compute Gallery image ID 输入
  - Marketplace 派生镜像继续传入原始 purchase plan
  - 与上游 VHD URI 路径互斥

除 `PATCHES.md` 明确记录的修改外，Check Point module 的资源逻辑、变量和
cloud-init 保持上游实现。

## 依赖边界

- Terraform module 源码来自本目录。
- Terraform Provider（AzureRM、Random）仍由 Terraform Registry 安装，并由 `infra/.terraform.lock.hcl` 固定版本和校验和。
- 默认仍在部署时从 Azure Marketplace 获取运行时产品镜像；也可显式引用保留原始
  purchase plan 的 generalized custom image。

## 更新步骤

1. 阅读 Check Point 上游 release notes 和许可证变化。
2. 在临时目录获取目标 tag，并记录精确 commit。
3. 只替换本目录列出的文件范围。
4. 重新应用 `PATCHES.md` 中记录的本地 patch。
5. 更新本文件、`ATTRIBUTION.md` 和 `vendor-checksums.sha256`。
6. 运行：

   ```bash
   ./scripts/verify-vendor.sh
   terraform -chdir=infra init -backend=false
   terraform -chdir=infra validate
   terraform -chdir=infra test
   ```

项目配置放在 `infra/*.tf` 和 `scripts/`；不要混入本地 module 副本。
