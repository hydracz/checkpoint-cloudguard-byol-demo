output "subscription_id" {
  value       = var.subscription_id
  description = "Azure subscription explicitly targeted by Terraform and all helper scripts."
}

output "resource_group_name" {
  value       = module.checkpoint.resource_group_name
  description = "Azure resource group containing the complete demo."
}

output "primary_location" {
  value       = var.location
  description = "Primary EU region."
}

output "remote_location" {
  value       = var.remote_location
  description = "Second EU region."
}

output "checkpoint_offer" {
  value       = local.checkpoint_offer
  description = "Azure Marketplace image offer."
}

output "checkpoint_plan" {
  value       = local.checkpoint_plan
  description = "Azure Marketplace BYOL plan used by standalone mode."
}

output "checkpoint_os_version" {
  value       = var.checkpoint_os_version
  description = "Gaia release selected for first-boot configuration."
}

output "checkpoint_image_id" {
  value       = trimspace(var.checkpoint_image_id) != "" ? trimspace(var.checkpoint_image_id) : null
  description = "Custom managed image or Compute Gallery image ID. Null means the Marketplace image is used."
}

output "checkpoint_image_requires_plan" {
  value       = local.checkpoint_source_requires_plan
  description = "Whether the selected VM image request includes a Marketplace purchase plan."
}

output "checkpoint_vm_name" {
  value       = module.checkpoint.vm_name
  description = "Check Point standalone VM name."
}

output "checkpoint_nsg_id" {
  value       = module.checkpoint.nsg_id
  description = "Gateway frontend/backend data-plane Network Security Group resource ID."
}

output "checkpoint_management_nsg_id" {
  value       = module.checkpoint.management_nsg_id
  description = "Private management NIC Network Security Group resource ID."
}

output "checkpoint_management_nic_id" {
  value       = module.checkpoint.management_nic_id
  description = "Dedicated Check Point eth0 management NIC resource ID."
}

output "checkpoint_gateway_name" {
  value       = local.gateway_name
  description = "Expected standalone gateway object name."
}

output "checkpoint_public_ip" {
  value       = module.checkpoint.public_ip_address
  description = "Frontend eth1 Public IP used for data-plane egress and optional north-south ingress; no management ports are opened."
}

output "checkpoint_management_url" {
  value       = "https://${module.checkpoint.management_private_ip_address}"
  description = "Private Gaia Portal URL reachable from the management subnet."
}

output "checkpoint_admin_username" {
  value       = "admin"
  description = "Built-in Gaia account configured for console and CLI/Portal password login; SSH remains public-key-only."
}

output "checkpoint_frontend_private_ip" {
  value       = module.checkpoint.frontend_private_ip_address
  description = "Gateway eth1 external/frontend private IP."
}

output "checkpoint_management_private_ip" {
  value       = module.checkpoint.management_private_ip_address
  description = "Dedicated eth0 management private IP used by Gaia Portal, SSH, and SmartConsole."
}

output "checkpoint_backend_private_ip" {
  value       = module.checkpoint.backend_private_ip_address
  description = "Gateway eth2 internal/backend NVA next-hop address used by both spokes."
}

output "collector_private_ip" {
  value       = local.collector_ip
  description = "Private target for Check Point Log Exporter."
}

output "collector_vm_name" {
  value       = azurerm_linux_virtual_machine.collector.name
  description = "Syslog collector VM name."
}

output "eu_workload_vm_name" {
  value       = azurerm_linux_virtual_machine.eu_workload.name
  description = "Primary-region test VM."
}

output "remote_workload_vm_name" {
  value       = azurerm_linux_virtual_machine.remote_workload.name
  description = "Cross-region test VM."
}

output "eu_workload_private_ip" {
  value       = local.eu_workload_ip
  description = "Primary-region workload private IP."
}

output "remote_workload_private_ip" {
  value       = local.remote_workload_ip
  description = "Cross-region workload private IP."
}

output "eu_workload_nic_name" {
  value       = azurerm_network_interface.eu_workload.name
  description = "Primary workload NIC used by route validation."
}

output "remote_workload_nic_name" {
  value       = azurerm_network_interface.remote_workload.name
  description = "Cross-region workload NIC used by route validation."
}

output "hub_address_space" {
  value = var.hub_address_space
}

output "eu_spoke_address_space" {
  value = var.eu_spoke_address_space
}

output "remote_spoke_address_space" {
  value = var.remote_spoke_address_space
}

output "policy_package_name" {
  value = var.policy_package_name
}

output "skip_policy_configuration" {
  value       = var.skip_policy_configuration
  description = "Whether Check Point Management API policy/object/rule automation is disabled."
}

output "management_cidrs" {
  value       = local.management_cidrs
  description = "Effective private administrator CIDRs admitted to eth0 SSH, Gaia Portal, and SmartConsole; always includes the management subnet."
}

output "configured_management_cidrs" {
  value       = distinct(var.management_cidrs)
  description = "Additional trusted private/VPN administrator CIDRs configured by the operator."
}

output "management_subnet_id" {
  value       = module.checkpoint.management_subnet_id
  description = "Subnet shared by the Check Point management NIC and Windows management workstation."
}

output "management_workstation_enabled" {
  value       = var.enable_management_workstation
  description = "Whether the private Windows SmartConsole workstation and Azure Bastion are deployed."
}

output "windows_client_vm_name" {
  value       = try(azurerm_windows_virtual_machine.management[0].name, null)
  description = "Private Windows Server workstation intended for future Check Point SmartConsole installation."
}

output "windows_client_private_ip" {
  value       = var.enable_management_workstation ? local.windows_client_ip : null
  description = "Private IP of the Windows management workstation."
}

output "windows_client_admin_username" {
  value       = var.enable_management_workstation ? var.windows_client_admin_username : null
  description = "Local administrator username for the Windows management workstation."
}

output "generated_windows_client_admin_password" {
  value       = try(random_password.windows_client[0].result, null)
  description = "Fallback Windows password generated only when Terraform is used directly without either administrator password. Normal wrapper deployments return null."
  sensitive   = true
}

output "bastion_host_name" {
  value       = try(azurerm_bastion_host.management[0].name, null)
  description = "Azure Bastion host used to reach the private Windows workstation."
}

output "company_domain" {
  value       = var.company_domain
  description = "Domain used as the demo HTTPS Inspection CA issued-by value."
}

output "blocked_countries" {
  value = var.blocked_countries
}

output "blocked_applications" {
  value = var.blocked_applications
}

output "blocked_urls" {
  value = var.blocked_urls
}

output "enable_tls_inspection" {
  value = var.enable_tls_inspection
}

output "r81_tls_manually_configured" {
  value       = var.r81_tls_manually_configured
  description = "Whether R81 HTTPS Inspection was bootstrapped through SmartConsole."
}

output "enable_inbound_demo" {
  value = var.enable_inbound_demo
}

output "inbound_demo_source_cidr" {
  value = var.inbound_demo_source_cidr
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.checkpoint.id
  description = "Resource ID of the EU Log Analytics workspace."
}

output "log_analytics_workspace_customer_id" {
  value       = azurerm_log_analytics_workspace.checkpoint.workspace_id
  description = "Workspace ID used by Azure CLI log queries."
}

output "audit_storage_account_name" {
  value       = local.audit_storage_name
  description = "EU storage account receiving continuous Syslog exports."
}

output "audit_storage_account_id" {
  value       = local.audit_storage_id
  description = "Resource ID of the storage account receiving continuous Syslog exports."
}

output "audit_container_name" {
  value       = "am-syslog"
  description = "Container protected by the WORM retention policy."
}

output "log_analytics_data_export_name" {
  value       = "${var.prefix}-syslog-to-worm"
  description = "Name of the Log Analytics continuous Syslog export."
}

output "immutable_retention_days" {
  value = var.immutable_retention_days
}
