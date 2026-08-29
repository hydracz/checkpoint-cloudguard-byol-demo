locals {
  checkpoint_offer = {
    R81   = "cgi-mgmt-r81"
    R82   = "check-point-cg-r82"
    R8210 = "check-point-cg-r8210"
  }[var.checkpoint_os_version]

  checkpoint_plan = "mgmt-byol"

  checkpoint_source_requires_plan = trimspace(var.checkpoint_image_id) == "" || var.checkpoint_image_requires_plan

  gateway_frontend_ip = cidrhost(var.checkpoint_frontend_subnet_prefix, 4)
  gateway_backend_ip  = cidrhost(var.checkpoint_backend_subnet_prefix, 4)
  collector_ip        = cidrhost(var.collector_subnet_prefix, 4)
  eu_workload_ip      = cidrhost(var.eu_workload_subnet_prefix, 4)
  remote_workload_ip  = cidrhost(var.remote_workload_subnet_prefix, 4)

  gateway_name           = "${var.prefix}-gateway"
  hub_vnet_name          = "${var.prefix}-hub-vnet"
  eu_spoke_vnet_name     = "${var.prefix}-eu-spoke-vnet"
  remote_spoke_vnet_name = "${var.prefix}-remote-spoke-vnet"

  base_tags = merge({
    workload   = "checkpoint-cloudguard-byol-demo"
    managed-by = "terraform"
    purpose    = "non-production-demo"
    data-zone  = "eu"
  }, var.tags)

  checkpoint_tags = {
    all = local.base_tags
  }

  checkpoint_security_rules = concat([
    {
      name                       = "AllowRestrictedSSH"
      priority                   = "100"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "22"
      description                = "Restricted SSH access"
      source_address_prefix      = var.management_cidr
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowRestrictedGaiaPortal"
      priority                   = "110"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "443"
      description                = "Restricted Gaia Portal access"
      source_address_prefix      = var.management_cidr
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowRestrictedSmartConsole18190"
      priority                   = "120"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "18190"
      description                = "Restricted SmartConsole access"
      source_address_prefix      = var.management_cidr
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowRestrictedSmartConsole19009"
      priority                   = "130"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "19009"
      description                = "Restricted SmartConsole access"
      source_address_prefix      = var.management_cidr
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowEUProtectedNetwork"
      priority                   = "200"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_ranges         = "*"
      destination_port_ranges    = "*"
      description                = "Forwarded traffic from the primary EU spoke"
      source_address_prefix      = var.eu_spoke_address_space
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowRemoteProtectedNetwork"
      priority                   = "210"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_ranges         = "*"
      destination_port_ranges    = "*"
      description                = "Forwarded traffic from the cross-region spoke"
      source_address_prefix      = var.remote_spoke_address_space
      destination_address_prefix = "*"
    }
    ], var.enable_inbound_demo ? [
    {
      name                       = "AllowRestrictedInboundDemo"
      priority                   = "220"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "18080"
      description                = "Optional source-restricted north-south DNAT demo"
      source_address_prefix      = var.inbound_demo_source_cidr
      destination_address_prefix = "*"
    }
  ] : [])
}

resource "random_string" "storage_suffix" {
  length  = 7
  special = false
  upper   = false
}
