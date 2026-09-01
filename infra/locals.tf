locals {
  checkpoint_offer = {
    R81   = "cgi-mgmt-r81"
    R82   = "check-point-cg-r82"
    R8210 = "check-point-cg-r8210"
  }[var.checkpoint_os_version]

  checkpoint_plan = "mgmt-byol"

  checkpoint_source_requires_plan = trimspace(var.checkpoint_image_id) == "" || var.checkpoint_image_requires_plan
  checkpoint_admin_password_bootstrap = var.checkpoint_admin_password_hash == "" ? "" : join("\n", [
    "clish -c 'set user admin password-hash ${var.checkpoint_admin_password_hash}'",
    "clish -c 'save config'",
  ])

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

  management_cidrs        = distinct(var.management_cidrs)
  primary_management_cidr = try(local.management_cidrs[0], "0.0.0.0/0")
  management_service_ports = [
    { name = "SSH", port = "22" },
    { name = "GaiaPortal", port = "443" },
    { name = "SmartConsole18190", port = "18190" },
    { name = "SmartConsole19009", port = "19009" },
  ]

  checkpoint_management_security_rules = [
    for service_index, service in local.management_service_ports : {
      name                       = "AllowRestricted${service.name}"
      priority                   = tostring(100 + service_index)
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = service.port
      description                = "${service.name} access from configured management CIDRs"
      source_address_prefixes    = local.management_cidrs
      destination_address_prefix = "*"
    }
  ]

  checkpoint_security_rules = concat(local.checkpoint_management_security_rules, [
    {
      name                       = "AllowEUProtectedNetwork"
      priority                   = "500"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_ranges         = "*"
      destination_port_ranges    = "*"
      description                = "Forwarded traffic from the primary EU spoke"
      source_address_prefixes    = [var.eu_spoke_address_space]
      destination_address_prefix = "*"
    },
    {
      name                       = "AllowRemoteProtectedNetwork"
      priority                   = "510"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "*"
      source_port_ranges         = "*"
      destination_port_ranges    = "*"
      description                = "Forwarded traffic from the cross-region spoke"
      source_address_prefixes    = [var.remote_spoke_address_space]
      destination_address_prefix = "*"
    }
    ], var.enable_inbound_demo ? [
    {
      name                       = "AllowRestrictedInboundDemo"
      priority                   = "520"
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_ranges         = "*"
      destination_port_ranges    = "18080"
      description                = "Optional source-restricted north-south DNAT demo"
      source_address_prefixes    = [var.inbound_demo_source_cidr]
      destination_address_prefix = "*"
    }
  ] : [])
}

resource "random_string" "storage_suffix" {
  length  = 7
  special = false
  upper   = false
}
