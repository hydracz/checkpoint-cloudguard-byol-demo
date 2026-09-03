resource "random_password" "windows_client" {
  count = var.enable_management_workstation ? 1 : 0

  length           = 24
  min_lower        = 4
  min_numeric      = 4
  min_special      = 4
  min_upper        = 4
  override_special = "!#%*-_=+?"
}

resource "azurerm_subnet" "azure_bastion" {
  count = var.enable_management_workstation ? 1 : 0

  name                 = "AzureBastionSubnet"
  resource_group_name  = module.checkpoint.resource_group_name
  virtual_network_name = module.checkpoint.vnet_name
  address_prefixes     = [var.bastion_subnet_prefix]
}

resource "azurerm_network_security_group" "windows_client" {
  count = var.enable_management_workstation ? 1 : 0

  name                = "${var.prefix}-windows-client-nsg"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  security_rule {
    name                       = "AllowRdpFromAzureBastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.bastion_subnet_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyOtherVnetInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "windows_client" {
  count = var.enable_management_workstation ? 1 : 0

  network_interface_id      = azurerm_network_interface.windows_client[0].id
  network_security_group_id = azurerm_network_security_group.windows_client[0].id
}

resource "azurerm_network_interface" "windows_client" {
  count = var.enable_management_workstation ? 1 : 0

  name                = "${var.prefix}-windows-client-nic"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = module.checkpoint.management_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.windows_client_ip
  }
}

resource "azurerm_windows_virtual_machine" "management" {
  count = var.enable_management_workstation ? 1 : 0

  name                  = "${var.prefix}-windows-client"
  computer_name         = substr(replace("${var.prefix}console", "-", ""), 0, 15)
  resource_group_name   = module.checkpoint.resource_group_name
  location              = var.location
  size                  = var.windows_client_vm_size
  admin_username        = var.windows_client_admin_username
  admin_password        = local.windows_client_admin_password
  network_interface_ids = [azurerm_network_interface.windows_client[0].id]
  patch_assessment_mode = "AutomaticByPlatform"
  patch_mode            = "AutomaticByPlatform"
  secure_boot_enabled   = true
  vtpm_enabled          = true
  tags                  = local.base_tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  boot_diagnostics {}

  lifecycle {
    # Subscription policy can attach a system identity after VM creation.
    ignore_changes = [identity]
  }

  depends_on = [azurerm_network_interface_security_group_association.windows_client]
}

resource "azurerm_public_ip" "bastion" {
  count = var.enable_management_workstation ? 1 : 0

  name                = "${var.prefix}-bastion-pip"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.base_tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_bastion_host" "management" {
  count = var.enable_management_workstation ? 1 : 0

  name                = "${var.prefix}-bastion"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  sku                 = "Basic"
  copy_paste_enabled  = true
  tags                = local.base_tags

  ip_configuration {
    name                 = "management"
    subnet_id            = azurerm_subnet.azure_bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
