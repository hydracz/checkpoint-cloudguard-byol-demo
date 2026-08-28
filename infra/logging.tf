resource "azurerm_log_analytics_workspace" "checkpoint" {
  name                = "${var.prefix}-checkpoint-law"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.base_tags
}

resource "azurerm_network_security_group" "collector" {
  name                = "${var.prefix}-collector-nsg"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  security_rule {
    name                       = "AllowCheckpointSyslogUDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "514"
    source_address_prefix      = "${local.gateway_backend_ip}/32"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowCheckpointSyslogTCP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "514"
    source_address_prefix      = "${local.gateway_backend_ip}/32"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "collector" {
  subnet_id                 = azurerm_subnet.collector.id
  network_security_group_id = azurerm_network_security_group.collector.id
}

resource "azurerm_public_ip" "collector" {
  name                = "${var.prefix}-collector-pip"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.base_tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "collector" {
  name                = "${var.prefix}-collector-nic"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  tags                = local.base_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.collector.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.collector_ip
    public_ip_address_id          = azurerm_public_ip.collector.id
  }
}

resource "azurerm_linux_virtual_machine" "collector" {
  name                            = "${var.prefix}-log-collector"
  computer_name                   = "${var.prefix}-logs"
  resource_group_name             = module.checkpoint.resource_group_name
  location                        = var.location
  size                            = var.collector_vm_size
  admin_username                  = var.workload_admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.collector.id]
  custom_data                     = base64encode(file("${path.module}/../cloud-init/collector.yaml"))
  tags                            = local.base_tags

  identity {
    type = "SystemAssigned"
  }

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
}

resource "azurerm_virtual_machine_extension" "azure_monitor_agent" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.collector.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.35"
  automatic_upgrade_enabled  = true
  auto_upgrade_minor_version = true
  tags                       = local.base_tags
}

resource "azurerm_monitor_data_collection_rule" "checkpoint_syslog" {
  name                = "${var.prefix}-checkpoint-syslog-dcr"
  location            = var.location
  resource_group_name = module.checkpoint.resource_group_name
  kind                = "Linux"
  tags                = local.base_tags

  destinations {
    log_analytics {
      name                  = "checkpoint-law"
      workspace_resource_id = azurerm_log_analytics_workspace.checkpoint.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["checkpoint-law"]
  }

  data_sources {
    syslog {
      name           = "checkpoint-syslog"
      facility_names = ["*"]
      log_levels     = ["*"]
      streams        = ["Microsoft-Syslog"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "collector" {
  name                    = "${var.prefix}-collector-dcra"
  target_resource_id      = azurerm_linux_virtual_machine.collector.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.checkpoint_syslog.id

  depends_on = [azurerm_virtual_machine_extension.azure_monitor_agent]
}

locals {
  audit_storage_name = substr("cp${replace(var.prefix, "-", "")}${random_string.storage_suffix.result}", 0, 24)
  audit_storage_id   = "${module.checkpoint.resource_group_id}/providers/Microsoft.Storage/storageAccounts/${local.audit_storage_name}"
}

resource "azurerm_resource_group_template_deployment" "audit_storage" {
  name                = "${var.prefix}-audit-storage"
  resource_group_name = module.checkpoint.resource_group_name
  deployment_mode     = "Incremental"
  parameters_content = jsonencode({
    storageName = {
      value = local.audit_storage_name
    }
    location = {
      value = var.location
    }
    retentionDays = {
      value = var.immutable_retention_days
    }
    tags = {
      value = local.base_tags
    }
  })
  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = {
      storageName = {
        type = "String"
      }
      location = {
        type = "String"
      }
      retentionDays = {
        type = "Int"
      }
      tags = {
        type = "Object"
      }
    }
    resources = [
      {
        type       = "Microsoft.Storage/storageAccounts"
        apiVersion = "2023-05-01"
        name       = "[parameters('storageName')]"
        location   = "[parameters('location')]"
        kind       = "StorageV2"
        sku = {
          name = "Standard_GRS"
        }
        tags = "[parameters('tags')]"
        properties = {
          supportsHttpsTrafficOnly     = true
          minimumTlsVersion            = "TLS1_2"
          allowBlobPublicAccess        = false
          allowSharedKeyAccess         = false
          allowCrossTenantReplication  = false
          publicNetworkAccess          = "Disabled"
          defaultToOAuthAuthentication = true
          infrastructureEncryption     = true
        }
      },
      {
        type       = "Microsoft.Storage/storageAccounts/blobServices"
        apiVersion = "2023-05-01"
        name       = "[format('{0}/default', parameters('storageName'))]"
        dependsOn = [
          "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageName'))]"
        ]
        properties = {
          isVersioningEnabled = true
        }
      },
      {
        type       = "Microsoft.Storage/storageAccounts/blobServices/containers"
        apiVersion = "2023-05-01"
        name       = "[format('{0}/default/am-syslog', parameters('storageName'))]"
        dependsOn = [
          "[resourceId('Microsoft.Storage/storageAccounts/blobServices', parameters('storageName'), 'default')]"
        ]
        properties = {
          publicAccess = "None"
        }
      },
      {
        type       = "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"
        apiVersion = "2023-05-01"
        name       = "[format('{0}/default/am-syslog/default', parameters('storageName'))]"
        dependsOn = [
          "[resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', parameters('storageName'), 'default', 'am-syslog')]"
        ]
        properties = {
          immutabilityPeriodSinceCreationInDays = "[parameters('retentionDays')]"
          state                                 = "Unlocked"
          allowProtectedAppendWrites            = true
        }
      }
    ]
  })
}

resource "azurerm_log_analytics_data_export_rule" "syslog" {
  count = var.enable_log_data_export ? 1 : 0

  name                    = "${var.prefix}-syslog-to-worm"
  resource_group_name     = module.checkpoint.resource_group_name
  workspace_resource_id   = azurerm_log_analytics_workspace.checkpoint.id
  destination_resource_id = local.audit_storage_id
  table_names             = ["Syslog"]
  enabled                 = true

  depends_on = [azurerm_resource_group_template_deployment.audit_storage]
}
