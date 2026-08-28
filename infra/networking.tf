resource "azurerm_virtual_network" "eu_spoke" {
  name                = local.eu_spoke_vnet_name
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  address_space       = [var.eu_spoke_address_space]
  tags                = local.base_tags
}

resource "azurerm_virtual_network" "remote_spoke" {
  name                = local.remote_spoke_vnet_name
  location            = var.remote_location
  resource_group_name = module.checkpoint.resource_group_name
  address_space       = [var.remote_spoke_address_space]
  tags                = local.base_tags
}

resource "azurerm_subnet" "eu_workload" {
  name                 = "workload"
  resource_group_name  = module.checkpoint.resource_group_name
  virtual_network_name = azurerm_virtual_network.eu_spoke.name
  address_prefixes     = [var.eu_workload_subnet_prefix]
}

resource "azurerm_subnet" "remote_workload" {
  name                 = "workload"
  resource_group_name  = module.checkpoint.resource_group_name
  virtual_network_name = azurerm_virtual_network.remote_spoke.name
  address_prefixes     = [var.remote_workload_subnet_prefix]
}

resource "azurerm_subnet" "collector" {
  name                 = "log-collector"
  resource_group_name  = module.checkpoint.resource_group_name
  virtual_network_name = module.checkpoint.vnet_name
  address_prefixes     = [var.collector_subnet_prefix]
}

resource "azurerm_virtual_network_peering" "hub_to_eu" {
  name                         = "hub-to-eu-spoke"
  resource_group_name          = module.checkpoint.resource_group_name
  virtual_network_name         = module.checkpoint.vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.eu_spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "eu_to_hub" {
  name                         = "eu-spoke-to-hub"
  resource_group_name          = module.checkpoint.resource_group_name
  virtual_network_name         = azurerm_virtual_network.eu_spoke.name
  remote_virtual_network_id    = module.checkpoint.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "hub_to_remote" {
  name                         = "hub-to-remote-spoke"
  resource_group_name          = module.checkpoint.resource_group_name
  virtual_network_name         = module.checkpoint.vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.remote_spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "remote_to_hub" {
  name                         = "remote-spoke-to-hub"
  resource_group_name          = module.checkpoint.resource_group_name
  virtual_network_name         = azurerm_virtual_network.remote_spoke.name
  remote_virtual_network_id    = module.checkpoint.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_route_table" "eu_workload" {
  name                          = "${var.prefix}-eu-workload-rt"
  location                      = var.location
  resource_group_name           = module.checkpoint.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = local.base_tags

  route {
    name                   = "default-via-checkpoint"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }

  route {
    name                   = "remote-spoke-via-checkpoint"
    address_prefix         = var.remote_spoke_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }

  route {
    name                   = "hub-via-checkpoint"
    address_prefix         = var.hub_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }
}

resource "azurerm_route_table" "remote_workload" {
  name                          = "${var.prefix}-remote-workload-rt"
  location                      = var.remote_location
  resource_group_name           = module.checkpoint.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = local.base_tags

  route {
    name                   = "default-via-checkpoint"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }

  route {
    name                   = "eu-spoke-via-checkpoint"
    address_prefix         = var.eu_spoke_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }

  route {
    name                   = "hub-via-checkpoint"
    address_prefix         = var.hub_address_space
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.gateway_backend_ip
  }
}

resource "azurerm_subnet_route_table_association" "eu_workload" {
  subnet_id      = azurerm_subnet.eu_workload.id
  route_table_id = azurerm_route_table.eu_workload.id

  depends_on = [
    azurerm_virtual_network_peering.hub_to_eu,
    azurerm_virtual_network_peering.eu_to_hub,
  ]
}

resource "azurerm_subnet_route_table_association" "remote_workload" {
  subnet_id      = azurerm_subnet.remote_workload.id
  route_table_id = azurerm_route_table.remote_workload.id

  depends_on = [
    azurerm_virtual_network_peering.hub_to_remote,
    azurerm_virtual_network_peering.remote_to_hub,
  ]
}

resource "azurerm_network_security_group" "eu_workload" {
  name                = "${var.prefix}-eu-workload-nsg"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  security_rule {
    name                   = "AllowInspectedWeb"
    priority               = 100
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "8080"
    source_address_prefixes = concat(
      [var.hub_address_space, var.eu_spoke_address_space, var.remote_spoke_address_space],
      var.enable_inbound_demo ? [var.inbound_demo_source_cidr] : [],
    )
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "remote_workload" {
  name                = "${var.prefix}-remote-workload-nsg"
  location            = var.remote_location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  security_rule {
    name                       = "AllowInspectedWeb"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefixes    = [var.hub_address_space, var.eu_spoke_address_space, var.remote_spoke_address_space]
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "eu_workload" {
  subnet_id                 = azurerm_subnet.eu_workload.id
  network_security_group_id = azurerm_network_security_group.eu_workload.id
}

resource "azurerm_subnet_network_security_group_association" "remote_workload" {
  subnet_id                 = azurerm_subnet.remote_workload.id
  network_security_group_id = azurerm_network_security_group.remote_workload.id
}
