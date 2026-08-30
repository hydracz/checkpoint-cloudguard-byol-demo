terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.80.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id != "" ? var.tenant_id : null
  client_id           = var.client_id != "" ? var.client_id : null
  client_secret       = var.client_secret != "" ? var.client_secret : null
  storage_use_azuread = true
}
