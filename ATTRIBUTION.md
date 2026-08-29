# 第三方代码、许可证与官方资料

本项目原创代码使用根目录 [MIT License](LICENSE)。

项目把使用的 Terraform module 源码放在 `infra/vendor/`：

- Check Point `terraform-azure-cloudguard-network-security` `v1.3.2`
  - `commit`：`5ab8cec498bfe9e744890af0759e795baf3576ec`
  - 上游：<https://github.com/CheckPointSW/terraform-azure-cloudguard-network-security>
  - 许可证：Apache License 2.0
完整许可证文本、复制范围和本地 patch 见
[Terraform 模块本地副本](infra/vendor/README.md)。

## 官方资料

访问日期：2026-08-30。

- Azure Marketplace Check Point offer：<https://marketplace.microsoft.com/en-us/product/checkpoint.vsec>
- Check Point 官方 Terraform 模块：<https://registry.terraform.io/modules/CheckPointSW/cloudguard-network-security/azure/1.3.2>
- Check Point R82 Updatable Objects：<https://sc1.checkpoint.com/documents/R82/WebAdminGuides/EN/CP_R82_SecurityManagement_AdminGuide/Content/Topics-SECMG/Updatable-Objects.htm>
- Check Point `cp_log_export`：<https://sc1.checkpoint.com/documents/R82/WebAdminGuides/EN/CP_R82_CLI_ReferenceGuide/Content/Topics-CLIG/SECMG/cp_log_export.htm>
- Check Point R81 HTTPS Inspection：<https://sc1.checkpoint.com/documents/R81/WebAdminGuides/EN/CP_R81_SecurityManagement_AdminGuide/Topics-SECMG/HTTPS-Inspection.htm>
- Azure Monitor Log Analytics data export：<https://learn.microsoft.com/azure/azure-monitor/logs/logs-data-export>
- Azure Log Analytics data export FAQ：<https://learn.microsoft.com/troubleshoot/azure/azure-monitor/log-analytics/workspaces/workspace-data-export-faq>
- Azure Blob container immutability：<https://learn.microsoft.com/azure/storage/blobs/immutable-policy-configure-container-scope>

Check Point、CloudGuard、Microsoft Azure 及相关商标归各自权利人所有。
