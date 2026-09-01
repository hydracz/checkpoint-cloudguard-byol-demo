module "checkpoint" {
  # Vendored from CheckPointSW/cloudguard-network-security/azure v1.3.2.
  # See infra/vendor/README.md for commit, license, and update procedure.
  source = "./vendor/checkpoint-cloudguard-network-security/modules/single-gateway"

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret

  resource_group_name = var.resource_group_name
  single_gateway_name = local.gateway_name
  location            = var.location
  extended_zone       = "None"
  tags                = local.checkpoint_tags

  source_image_vhd_uri           = "noCustomUri"
  source_image_id                = trimspace(var.checkpoint_image_id)
  source_image_requires_plan     = local.checkpoint_source_requires_plan
  hyper_v_generation             = "V1"
  authentication_type            = "SSH Public Key"
  admin_SSH_key                  = var.admin_ssh_public_key
  sic_key                        = var.sic_key
  serial_console_password_hash   = var.checkpoint_admin_password_hash
  maintenance_mode_password_hash = ""
  installation_type              = "standalone"
  vm_size                        = var.checkpoint_vm_size
  disk_size                      = "200"
  os_version                     = var.checkpoint_os_version
  vm_os_sku                      = local.checkpoint_plan
  vm_os_offer                    = local.checkpoint_offer
  allow_upload_download          = true
  admin_shell                    = "/bin/bash"
  bootstrap_script               = local.checkpoint_admin_password_bootstrap
  enable_custom_metrics          = true
  zone                           = ""
  smart_1_cloud_token            = ""

  # The upstream first-boot interface accepts one network; post-deploy policy
  # configuration synchronizes the complete management_cidrs list.
  management_GUI_client_network = local.primary_management_cidr

  vnet_name                       = local.hub_vnet_name
  frontend_subnet_name            = "checkpoint-frontend"
  backend_subnet_name             = "checkpoint-backend"
  address_space                   = var.hub_address_space
  subnet_prefixes                 = [var.checkpoint_frontend_subnet_prefix, var.checkpoint_backend_subnet_prefix]
  frontend_private_ip             = local.gateway_frontend_ip
  backend_private_ip              = local.gateway_backend_ip
  enable_ipv6                     = false
  nsg_id                          = ""
  storage_account_deployment_mode = "Managed"
  storage_account_type            = "Standard_LRS"
  add_storage_account_ip_rules    = false
  storage_account_additional_ips  = []
  security_rules                  = local.checkpoint_security_rules
}

resource "azurerm_network_security_rule" "checkpoint_additional_management" {
  for_each = local.checkpoint_additional_management_security_rules_by_name

  name                        = each.key
  priority                    = tonumber(each.value.priority)
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = each.value.source_port_ranges
  destination_port_range      = each.value.destination_port_ranges
  description                 = each.value.description
  source_address_prefix       = each.value.source_address_prefix
  destination_address_prefix  = each.value.destination_address_prefix
  resource_group_name         = module.checkpoint.resource_group_name
  network_security_group_name = reverse(split("/", module.checkpoint.nsg_id))[0]
}
