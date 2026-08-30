mock_provider "azurerm" {}
mock_provider "random" {}

override_module {
  target = module.checkpoint
  outputs = {
    resource_group_name         = "rg-checkpoint-mock"
    resource_group_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock"
    vnet_name                   = "checkpoint-mock-hub-vnet"
    vnet_id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/virtualNetworks/checkpoint-mock-hub-vnet"
    vm_name                     = "checkpoint-mock-gateway"
    nsg_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/networkSecurityGroups/rg-checkpoint-mock-nsg"
    public_ip_address           = "198.51.100.20"
    frontend_private_ip_address = "10.60.0.4"
    backend_private_ip_address  = "10.60.1.4"
  }
}

run "default_demo_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  assert {
    condition     = local.checkpoint_plan == "mgmt-byol"
    error_message = "Standalone mode must use the mgmt-byol Marketplace plan."
  }

  assert {
    condition     = length(local.checkpoint_security_rules) == 6
    error_message = "The default gateway NSG must contain six least-privilege rules."
  }

  assert {
    condition = (
      length(local.management_cidrs) == 1 &&
      local.management_cidrs[0] == "203.0.113.10/32"
    )
    error_message = "The management CIDR list must drive all administrator access."
  }

  assert {
    condition = alltrue([
      for rule in local.checkpoint_security_rules :
      can(rule.source_address_prefix) &&
      can(rule.source_port_ranges) &&
      can(rule.destination_port_ranges) &&
      can(rule.destination_address_prefix)
    ])
    error_message = "Every rule must use the single-value fields required by the upstream NSG module."
  }

  assert {
    condition     = var.immutable_retention_days == 365
    error_message = "The default immutable retention period must be 365 days."
  }

  assert {
    condition     = var.checkpoint_image_id == ""
    error_message = "Marketplace must remain the default Check Point image source."
  }

  assert {
    condition     = local.checkpoint_source_requires_plan
    error_message = "The default Marketplace source must require its purchase plan."
  }

  assert {
    condition = alltrue([
      azurerm_virtual_network_peering.eu_to_hub.remote_virtual_network_id == module.checkpoint.vnet_id,
      azurerm_virtual_network_peering.remote_to_hub.remote_virtual_network_id == module.checkpoint.vnet_id,
    ])
    error_message = "Spoke-to-hub peerings must depend on the module-created hub VNet ID."
  }
}

run "multiple_management_cidrs" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32", "198.51.100.0/24"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  assert {
    condition = (
      length(local.management_cidrs) == 2 &&
      length(local.checkpoint_primary_management_security_rules) == 4 &&
      length(local.checkpoint_additional_management_security_rules) == 4 &&
      local.checkpoint_additional_management_security_rules[0].name == "AllowRestrictedSSH02" &&
      local.checkpoint_additional_management_security_rules[0].source_address_prefix == "198.51.100.0/24" &&
      local.checkpoint_additional_management_security_rules[3].name == "AllowRestrictedSmartConsole1900902" &&
      azurerm_network_security_rule.checkpoint_additional_management["AllowRestrictedSSH02"].priority == 104
    )
    error_message = "Each management CIDR must receive deterministic rules for all four administrator services."
  }
}

run "invalid_management_cidrs" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["0.0.0.0/00", "203.0.113.10/24"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  expect_failures = [var.management_cidrs]
}

run "custom_image_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r82-byol/versions/1.0.0"
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  assert {
    condition     = var.checkpoint_image_id != ""
    error_message = "A valid custom image ID must override the Marketplace source."
  }

  assert {
    condition     = local.checkpoint_source_requires_plan && local.checkpoint_plan == "mgmt-byol"
    error_message = "Marketplace-derived custom images must retain the mgmt-byol plan."
  }
}

run "custom_image_without_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R81"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r81-planless/versions/1.0.0"
    checkpoint_image_requires_plan = false
    enable_log_data_export         = false
    enable_tls_inspection          = false
  }

  assert {
    condition     = var.checkpoint_os_version == "R81" && var.checkpoint_image_id != "" && !local.checkpoint_source_requires_plan
    error_message = "An explicitly planless custom image must not add Marketplace plan metadata."
  }
}

run "invalid_r82_planless_custom_image" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r82-planless/versions/1.0.0"
    checkpoint_image_requires_plan = false
    enable_log_data_export         = false
  }

  expect_failures = [var.checkpoint_os_version]
}

run "invalid_r81_tls_automation" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R81"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r81-planless/versions/1.0.0"
    checkpoint_image_requires_plan = false
    enable_log_data_export         = false
    enable_tls_inspection          = true
  }

  expect_failures = [var.enable_tls_inspection]
}

run "r81_manual_tls_bootstrap" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R81"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r81-planless/versions/1.0.0"
    checkpoint_image_requires_plan = false
    enable_log_data_export         = false
    enable_tls_inspection          = true
    r81_tls_manually_configured    = true
  }

  assert {
    condition     = var.enable_tls_inspection && var.r81_tls_manually_configured
    error_message = "R81 manual TLS bootstrap must keep T07 enabled after SmartConsole configuration."
  }
}

run "invalid_r81_marketplace_source" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R81"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  expect_failures = [var.checkpoint_os_version]
}

run "invalid_custom_image_id" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = "not-an-azure-resource-id"
    checkpoint_image_requires_plan = true
    enable_log_data_export         = false
  }

  expect_failures = [var.checkpoint_image_id]
}

run "restricted_inbound_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_inbound_demo            = true
    inbound_demo_source_cidr       = "198.51.100.10/32"
    enable_log_data_export         = false
  }

  assert {
    condition     = length(local.checkpoint_security_rules) == 7
    error_message = "Enabling inbound demo must add exactly one source-restricted gateway NSG rule."
  }

  assert {
    condition = contains(
      flatten([
        for rule in azurerm_network_security_group.eu_workload.security_rule :
        rule.source_address_prefixes
      ]),
      "198.51.100.10/32",
    )
    error_message = "The primary workload NSG must admit the preserved DNAT source CIDR."
  }
}

run "audit_export_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidrs               = ["203.0.113.10/32"]
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R82"
    checkpoint_image_id            = ""
    checkpoint_image_requires_plan = true
    enable_log_data_export         = true
  }

  assert {
    condition     = length(azurerm_log_analytics_data_export_rule.syslog) == 1
    error_message = "The post-ingestion plan must create one continuous Syslog export rule."
  }
}
