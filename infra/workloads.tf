resource "azurerm_network_interface" "eu_workload" {
  name                = "${var.prefix}-eu-workload-nic"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.eu_workload.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.eu_workload_ip
  }
}

resource "azurerm_network_interface" "remote_workload" {
  name                = "${var.prefix}-remote-workload-nic"
  location            = var.remote_location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.remote_workload.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.remote_workload_ip
  }
}

resource "azurerm_linux_virtual_machine" "eu_workload" {
  name                            = "${var.prefix}-eu-workload"
  computer_name                   = "${var.prefix}-eu"
  resource_group_name             = module.checkpoint.resource_group_name
  location                        = var.location
  size                            = var.workload_vm_size
  admin_username                  = var.workload_admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.eu_workload.id]
  custom_data = base64encode(templatefile("${path.module}/../cloud-init/workload.yaml", {
    site_name = "EU workload"
  }))
  tags = local.base_tags

  admin_ssh_key {
    username   = var.workload_admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    # Subscription policy can attach a system identity after VM creation.
    ignore_changes = [identity]
  }

  depends_on = [azurerm_subnet_route_table_association.eu_workload]
}

resource "azurerm_linux_virtual_machine" "remote_workload" {
  name                            = "${var.prefix}-remote-workload"
  computer_name                   = "${var.prefix}-remote"
  resource_group_name             = module.checkpoint.resource_group_name
  location                        = var.remote_location
  size                            = var.workload_vm_size
  admin_username                  = var.workload_admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.remote_workload.id]
  custom_data = base64encode(templatefile("${path.module}/../cloud-init/workload.yaml", {
    site_name = "Cross-region workload"
  }))
  tags = local.base_tags

  admin_ssh_key {
    username   = var.workload_admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    # Subscription policy can attach a system identity after VM creation.
    ignore_changes = [identity]
  }

  depends_on = [azurerm_subnet_route_table_association.remote_workload]
}
