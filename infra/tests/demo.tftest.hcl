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
    public_ip_address           = "198.51.100.20"
    frontend_private_ip_address = "10.60.0.4"
    backend_private_ip_address  = "10.60.1.4"
  }
}

run "default_demo_plan" {
  command = plan

  variables {
    subscription_id      = "00000000-0000-0000-0000-000000000000"
    tenant_id            = "00000000-0000-0000-0000-000000000000"
    client_id            = "00000000-0000-0000-0000-000000000000"
    client_secret        = "validation-only"
    management_cidr      = "203.0.113.10/32"
    admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key              = "validation-only-sic-key"
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
    condition = alltrue([
      azurerm_virtual_network_peering.eu_to_hub.remote_virtual_network_id == module.checkpoint.vnet_id,
      azurerm_virtual_network_peering.remote_to_hub.remote_virtual_network_id == module.checkpoint.vnet_id,
    ])
    error_message = "Spoke-to-hub peerings must depend on the module-created hub VNet ID."
  }
}

run "restricted_inbound_plan" {
  command = plan

  variables {
    subscription_id          = "00000000-0000-0000-0000-000000000000"
    tenant_id                = "00000000-0000-0000-0000-000000000000"
    client_id                = "00000000-0000-0000-0000-000000000000"
    client_secret            = "validation-only"
    management_cidr          = "203.0.113.10/32"
    admin_ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                  = "validation-only-sic-key"
    enable_inbound_demo      = true
    inbound_demo_source_cidr = "198.51.100.10/32"
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
    subscription_id        = "00000000-0000-0000-0000-000000000000"
    tenant_id              = "00000000-0000-0000-0000-000000000000"
    client_id              = "00000000-0000-0000-0000-000000000000"
    client_secret          = "validation-only"
    management_cidr        = "203.0.113.10/32"
    admin_ssh_public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                = "validation-only-sic-key"
    enable_log_data_export = true
  }

  assert {
    condition     = length(azurerm_log_analytics_data_export_rule.syslog) == 1
    error_message = "The post-ingestion plan must create one continuous Syslog export rule."
  }
}
