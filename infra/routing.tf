locals {
  route_networks = {
    for name, prefix in {
      hub     = var.hub_address_space
      bastion = var.bastion_subnet_prefix
      } : name => can(cidrnetmask(prefix)) ? {
      prefix_length = tonumber(split("/", prefix)[1])
      network_number = sum([
        for index, octet in split(".", cidrhost(prefix, 0)) :
        tonumber(octet) * pow(256, 3 - index)
      ])
    } : null
  }

  bastion_is_hub_subnet = try(
    local.route_networks.bastion.prefix_length > local.route_networks.hub.prefix_length &&
    local.route_networks.bastion.network_number >= local.route_networks.hub.network_number &&
    local.route_networks.bastion.network_number + pow(2, 32 - local.route_networks.bastion.prefix_length) <=
    local.route_networks.hub.network_number + pow(2, 32 - local.route_networks.hub.prefix_length),
    false,
  )

  # One sibling at each prefix depth covers exactly Hub minus Bastion.
  eu_hub_child_indices = {
    for newbits in range(1,
      var.enable_management_workstation && local.bastion_is_hub_subnet ?
      local.route_networks.bastion.prefix_length - local.route_networks.hub.prefix_length + 1 : 1
      ) : newbits => floor(
      (local.route_networks.bastion.network_number - local.route_networks.hub.network_number) /
      pow(2, 32 - local.route_networks.hub.prefix_length - newbits)
    )
  }

  eu_hub_inspection_prefixes = [
    for newbits, child_index in local.eu_hub_child_indices :
    cidrsubnet(
      var.hub_address_space,
      tonumber(newbits),
      child_index % 2 == 0 ? child_index + 1 : child_index - 1,
    )
  ]

  eu_hub_inspection_routes = var.enable_management_workstation ? {
    for prefix in local.eu_hub_inspection_prefixes :
    "hub-inspect-${replace(replace(prefix, ".", "-"), "/", "-")}" => prefix
    } : {
    "hub-via-checkpoint" = var.hub_address_space
  }
}
