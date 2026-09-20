mock_provider "azurerm" {}
mock_provider "random" {}

override_module {
  target = module.checkpoint
  outputs = {
    resource_group_name           = "rg-checkpoint-mock"
    resource_group_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock"
    vnet_name                     = "checkpoint-mock-hub-vnet"
    vnet_id                       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/virtualNetworks/checkpoint-mock-hub-vnet"
    vm_name                       = "checkpoint-mock-gateway"
    nsg_id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/networkSecurityGroups/gateway-data"
    management_nsg_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/networkSecurityGroups/gateway-management"
    management_subnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/virtualNetworks/checkpoint-mock-hub-vnet/subnets/management"
    management_nic_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-checkpoint-mock/providers/Microsoft.Network/networkInterfaces/gateway-management"
    public_ip_address             = "198.51.100.20"
    management_private_ip_address = "10.60.3.4"
    frontend_private_ip_address   = "10.60.0.4"
    backend_private_ip_address    = "10.60.1.4"
  }
}

variables {
  subscription_id      = "00000000-0000-0000-0000-000000000000"
  tenant_id            = "00000000-0000-0000-0000-000000000000"
  client_id            = "00000000-0000-0000-0000-000000000000"
  client_secret        = "validation-only"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
  sic_key              = "validation-only-sic-key"
}

run "default_primary_bastion_exception" {
  command = plan

  assert {
    condition = (
      length(azurerm_route_table.eu_workload.route) == 12 &&
      toset([for route in azurerm_route_table.eu_workload.route : route.address_prefix]) == toset([
        "0.0.0.0/0", "10.62.0.0/16",
        "10.60.0.0/22", "10.60.4.64/26", "10.60.4.128/25",
        "10.60.5.0/24", "10.60.6.0/23", "10.60.8.0/21",
        "10.60.16.0/20", "10.60.32.0/19", "10.60.64.0/18", "10.60.128.0/17",
      ]) &&
      alltrue([
        for route in azurerm_route_table.eu_workload.route :
        route.next_hop_type == "VirtualAppliance" &&
        route.next_hop_in_ip_address == "10.60.1.4"
      ])
    )
    error_message = "The primary table must exclude only the Bastion /26 while preserving every other Hub address and both business routes."
  }

  assert {
    condition = alltrue([
      for route in azurerm_route_table.eu_workload.route :
      route.name == (
        route.address_prefix == "0.0.0.0/0" ? "default-via-checkpoint" :
        route.address_prefix == "10.62.0.0/16" ? "remote-spoke-via-checkpoint" :
        "hub-inspect-${replace(replace(route.address_prefix, ".", "-"), "/", "-")}"
      )
    ])
    error_message = "Route names must match the approved Portal migration without restoring hub-via-checkpoint."
  }

  assert {
    condition = (
      length(azurerm_route_table.remote_workload.route) == 3 &&
      toset([for route in azurerm_route_table.remote_workload.route : route.address_prefix]) ==
      toset(["0.0.0.0/0", "10.61.0.0/16", "10.60.0.0/16"]) &&
      alltrue([
        for route in azurerm_route_table.remote_workload.route :
        route.next_hop_type == "VirtualAppliance" &&
        route.next_hop_in_ip_address == "10.60.1.4"
      ])
    )
    error_message = "The primary Bastion exception must not change the remote Spoke routing policy."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.eu_workload.disable_password_authentication &&
      azurerm_network_interface.eu_workload.ip_configuration[0].public_ip_address_id == null &&
      length(azurerm_network_security_group.eu_workload.security_rule) == 1 &&
      !azurerm_route_table.eu_workload.bgp_route_propagation_enabled
    )
    error_message = "The route fix must not enable passwords, add a public IP, expand SSH NSG rules, or enable BGP propagation."
  }
}

run "management_disabled_keeps_hub_route" {
  command = plan

  variables {
    enable_management_workstation = false
    bastion_subnet_prefix         = "10.90.4.0/26"
  }

  assert {
    condition = (
      length(azurerm_bastion_host.management) == 0 &&
      length(azurerm_route_table.eu_workload.route) == 3 &&
      toset([for route in azurerm_route_table.eu_workload.route : route.address_prefix]) ==
      toset(["0.0.0.0/0", "10.62.0.0/16", "10.60.0.0/16"]) &&
      length([
        for route in azurerm_route_table.eu_workload.route : route
        if route.name == "hub-via-checkpoint" &&
        route.address_prefix == "10.60.0.0/16" &&
        route.next_hop_in_ip_address == "10.60.1.4"
      ]) == 1
    )
    error_message = "Without a deployed Bastion, the primary table must retain its original Hub route, even with an unused out-of-Hub Bastion prefix."
  }
}

run "custom_hub_and_bastion_prefixes" {
  command = plan

  variables {
    hub_address_space                 = "172.20.128.0/17"
    checkpoint_frontend_subnet_prefix = "172.20.128.0/24"
    checkpoint_backend_subnet_prefix  = "172.20.129.0/24"
    collector_subnet_prefix           = "172.20.130.0/24"
    management_subnet_prefix          = "172.20.131.0/24"
    bastion_subnet_prefix             = "172.20.132.64/26"
  }

  assert {
    condition = (
      length(azurerm_route_table.eu_workload.route) == 11 &&
      toset([for route in azurerm_route_table.eu_workload.route : route.address_prefix]) == toset([
        "0.0.0.0/0", "10.62.0.0/16",
        "172.20.128.0/22", "172.20.132.0/26", "172.20.132.128/25",
        "172.20.133.0/24", "172.20.134.0/23", "172.20.136.0/21",
        "172.20.144.0/20", "172.20.160.0/19", "172.20.192.0/18",
      ]) &&
      alltrue([
        for route in azurerm_route_table.eu_workload.route :
        route.next_hop_in_ip_address == "172.20.129.4"
      ])
    )
    error_message = "The complement and NVA address must derive from configured CIDRs, not the default IP plan."
  }
}

run "bastion_at_start_of_hub" {
  command = plan

  variables {
    checkpoint_frontend_subnet_prefix = "10.60.1.0/24"
    checkpoint_backend_subnet_prefix  = "10.60.2.0/24"
    collector_subnet_prefix           = "10.60.3.0/24"
    management_subnet_prefix          = "10.60.4.0/24"
    bastion_subnet_prefix             = "10.60.0.0/26"
  }

  assert {
    condition = toset([for route in azurerm_route_table.eu_workload.route : route.address_prefix]) == toset([
      "0.0.0.0/0", "10.62.0.0/16",
      "10.60.0.64/26", "10.60.0.128/25", "10.60.1.0/24", "10.60.2.0/23",
      "10.60.4.0/22", "10.60.8.0/21", "10.60.16.0/20",
      "10.60.32.0/19", "10.60.64.0/18", "10.60.128.0/17",
    ])
    error_message = "Excluding the first /26 must not lose the immediately adjacent Hub addresses."
  }
}

run "bastion_at_end_of_hub" {
  command = plan

  variables {
    bastion_subnet_prefix = "10.60.255.192/26"
  }

  assert {
    condition = toset([for route in azurerm_route_table.eu_workload.route : route.address_prefix]) == toset([
      "0.0.0.0/0", "10.62.0.0/16",
      "10.60.0.0/17", "10.60.128.0/18", "10.60.192.0/19", "10.60.224.0/20",
      "10.60.240.0/21", "10.60.248.0/22", "10.60.252.0/23",
      "10.60.254.0/24", "10.60.255.0/25", "10.60.255.128/26",
    ])
    error_message = "Excluding the last /26 must preserve all earlier Hub addresses."
  }
}

run "reject_noncanonical_hub" {
  command = plan

  variables {
    hub_address_space = "10.60.0.1/16"
  }

  expect_failures = [var.hub_address_space]
}

run "reject_noncanonical_bastion" {
  command = plan

  variables {
    bastion_subnet_prefix = "10.60.4.7/26"
  }

  expect_failures = [var.bastion_subnet_prefix]
}

run "reject_bastion_outside_hub" {
  command = plan

  variables {
    bastion_subnet_prefix = "10.90.4.0/26"
  }

  expect_failures = [azurerm_route_table.eu_workload]
}

run "reject_bastion_equal_to_hub" {
  command = plan

  variables {
    hub_address_space = "10.60.4.0/26"
  }

  expect_failures = [azurerm_route_table.eu_workload]
}

run "reject_invalid_hub_cidr" {
  command = plan

  variables {
    hub_address_space = "not-a-cidr"
  }

  expect_failures = [var.hub_address_space]
}

run "reject_ipv6_hub" {
  command = plan

  variables {
    hub_address_space = "fd00::/48"
  }

  expect_failures = [var.hub_address_space]
}

run "reject_invalid_bastion_cidr" {
  command = plan

  variables {
    bastion_subnet_prefix = "not-a-cidr"
  }

  expect_failures = [var.bastion_subnet_prefix]
}

run "reject_wrong_bastion_prefix_length" {
  command = plan

  variables {
    bastion_subnet_prefix = "10.60.4.0/25"
  }

  expect_failures = [var.bastion_subnet_prefix]
}
