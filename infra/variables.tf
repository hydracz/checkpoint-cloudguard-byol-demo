variable "subscription_id" {
  description = "Target Azure subscription ID. Put the customer/test subscription in the non-secret tfvars file."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "tenant_id" {
  description = "Optional Microsoft Entra tenant ID for service-principal authentication. Azure CLI mode derives it automatically."
  type        = string
  default     = ""
}

variable "client_id" {
  description = "Optional service principal client ID. Leave empty to use Azure CLI authentication."
  type        = string
  default     = ""
}

variable "client_secret" {
  description = "Optional service principal client secret. Leave empty to use Azure CLI authentication."
  type        = string
  default     = ""
  sensitive   = true
}

variable "resource_group_name" {
  description = "Resource group created by the official Check Point module."
  type        = string
  default     = "rg-checkpoint-byol-demo"
}

variable "prefix" {
  description = "Short prefix used for Azure resource names."
  type        = string
  default     = "cpbyol"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.prefix))
    error_message = "prefix must be 2-15 lowercase letters, digits, or hyphens and start with a letter."
  }
}

variable "company_domain" {
  description = "Company domain used as the demo HTTPS Inspection CA issued-by value. The default is the IANA-reserved example.org domain."
  type        = string
  default     = "example.org"

  validation {
    condition = (
      length(var.company_domain) <= 253 &&
      length(split(".", var.company_domain)) >= 2 &&
      alltrue([
        for label in split(".", var.company_domain) :
        can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", label))
      ])
    )
    error_message = "company_domain must be a DNS domain such as example.org."
  }
}

variable "location" {
  description = "Primary EU Azure region for Check Point, logging, and the first workload."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "francecentral", "germanywestcentral", "swedencentral"], var.location)
    error_message = "location must be an EU region approved by this demo."
  }
}

variable "remote_location" {
  description = "Second EU Azure region used to demonstrate cross-region east-west inspection."
  type        = string
  default     = "northeurope"

  validation {
    condition = (
      contains(["westeurope", "northeurope", "francecentral", "germanywestcentral", "swedencentral"], var.remote_location) &&
      var.remote_location != var.location
    )
    error_message = "remote_location must be an approved EU region different from location."
  }
}

variable "management_cidr" {
  description = "Public administrator CIDR allowed to reach SSH, Gaia Portal, and SmartConsole ports. Never use 0.0.0.0/0."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.management_cidr)) && var.management_cidr != "0.0.0.0/0"
    error_message = "management_cidr must be a valid, restricted IPv4 CIDR and cannot be 0.0.0.0/0."
  }
}

variable "admin_ssh_public_key" {
  description = "SSH public key used for the Check Point and Linux demo VMs."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^ssh-(rsa|ed25519|ecdsa-[^ ]+) ", trimspace(var.admin_ssh_public_key)))
    error_message = "admin_ssh_public_key must be an OpenSSH public key."
  }
}

variable "sic_key" {
  description = "Check Point Secure Internal Communication activation key. The wrapper generates and stores one locally when omitted."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.sic_key) >= 12
    error_message = "sic_key must be at least 12 characters."
  }
}

variable "checkpoint_os_version" {
  description = "Check Point Gaia release. R81 is supported only with an explicitly planless custom image."
  type        = string
  default     = "R82"

  validation {
    condition = (
      contains(["R81", "R82", "R8210"], var.checkpoint_os_version) &&
      (
        var.checkpoint_os_version == "R81" ?
        (trimspace(var.checkpoint_image_id) != "" && !var.checkpoint_image_requires_plan) :
        (trimspace(var.checkpoint_image_id) == "" || var.checkpoint_image_requires_plan)
      )
    )
    error_message = "R81 requires a non-empty planless custom image; R82/R8210 custom images must retain their Marketplace plan."
  }
}

variable "checkpoint_image_id" {
  description = "Optional generalized Check Point managed image or Azure Compute Gallery image ID. Leave empty to use the Azure Marketplace image."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.checkpoint_image_id) == "" ||
      can(regex(
        "(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourcegroups/[^/]+/providers/microsoft\\.compute/(images/[^/]+|galleries/[^/]+/images/[^/]+(/versions/[0-9]+\\.[0-9]+\\.[0-9]+)?)$",
        trimspace(var.checkpoint_image_id),
      ))
    )
    error_message = "checkpoint_image_id must be empty or a managed image, Compute Gallery image definition, or Compute Gallery image version resource ID."
  }
}

variable "checkpoint_image_requires_plan" {
  description = "Whether checkpoint_image_id requires the Check Point Marketplace purchase plan. R81 must be false; R82/R8210 custom images must be true."
  type        = bool
  default     = true
}

variable "checkpoint_vm_size" {
  description = "Check Point standalone VM size. The Gen1 mgmt-byol image cannot run on Gen2-only Dv6 sizes."
  type        = string
  default     = "Standard_D8s_v5"

  validation {
    condition     = !endswith(lower(var.checkpoint_vm_size), "_v6")
    error_message = "Check Point standalone mgmt-byol is a Gen1 image; Azure Dv6 is Gen2-only. Use Standard_D8s_v5 (8C/32GiB) unless Check Point publishes a supported Gen2 standalone image."
  }
}

variable "workload_vm_size" {
  description = "Size of each Ubuntu test workload. Standard_D4ls_v6 provides 4 vCPU and 8 GiB."
  type        = string
  default     = "Standard_D4ls_v6"
}

variable "collector_vm_size" {
  description = "Size of the Ubuntu syslog collector. Standard_D4ls_v6 provides 4 vCPU and 8 GiB."
  type        = string
  default     = "Standard_D4ls_v6"
}

variable "workload_admin_username" {
  description = "Linux account used by the Ubuntu test VMs."
  type        = string
  default     = "azureuser"
}

variable "hub_address_space" {
  description = "Hub VNet address space."
  type        = string
  default     = "10.60.0.0/16"
}

variable "checkpoint_frontend_subnet_prefix" {
  description = "Check Point external/frontend subnet."
  type        = string
  default     = "10.60.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.checkpoint_frontend_subnet_prefix)) && endswith(var.checkpoint_frontend_subnet_prefix, "/24")
    error_message = "checkpoint_frontend_subnet_prefix must be a valid IPv4 /24."
  }
}

variable "checkpoint_backend_subnet_prefix" {
  description = "Check Point internal/backend subnet."
  type        = string
  default     = "10.60.1.0/24"

  validation {
    condition     = can(cidrnetmask(var.checkpoint_backend_subnet_prefix)) && endswith(var.checkpoint_backend_subnet_prefix, "/24")
    error_message = "checkpoint_backend_subnet_prefix must be a valid IPv4 /24."
  }
}

variable "collector_subnet_prefix" {
  description = "Syslog collector subnet in the hub."
  type        = string
  default     = "10.60.2.0/24"

  validation {
    condition     = can(cidrnetmask(var.collector_subnet_prefix)) && endswith(var.collector_subnet_prefix, "/24")
    error_message = "collector_subnet_prefix must be a valid IPv4 /24."
  }
}

variable "eu_spoke_address_space" {
  description = "Primary-region workload VNet address space."
  type        = string
  default     = "10.61.0.0/16"
}

variable "eu_workload_subnet_prefix" {
  description = "Primary-region workload subnet."
  type        = string
  default     = "10.61.0.0/24"
}

variable "remote_spoke_address_space" {
  description = "Second-region workload VNet address space."
  type        = string
  default     = "10.62.0.0/16"
}

variable "remote_workload_subnet_prefix" {
  description = "Second-region workload subnet."
  type        = string
  default     = "10.62.0.0/24"
}

variable "blocked_countries" {
  description = "Exact English names of Check Point Geo Updatable Objects imported and blocked by the demo policy."
  type        = list(string)
  default     = ["China"]

  validation {
    condition     = length(var.blocked_countries) > 0 && alltrue([for country in var.blocked_countries : length(trimspace(country)) > 0])
    error_message = "blocked_countries must contain at least one non-empty country name."
  }
}

variable "blocked_applications" {
  description = "Existing Check Point Application/Site object or category names blocked by the demo policy."
  type        = list(string)
  default     = ["P2P File Sharing"]
}

variable "blocked_urls" {
  description = "Domains or URLs placed in the custom Application/Site object."
  type        = list(string)
  default     = ["example.com", "httpbin.org/anything/blocked"]

  validation {
    condition     = length(var.blocked_urls) > 0 && alltrue([for url in var.blocked_urls : length(trimspace(url)) > 0])
    error_message = "blocked_urls must contain at least one non-empty domain or URL."
  }
}

variable "policy_package_name" {
  description = "Existing standalone policy package configured by the post-deployment Management API script."
  type        = string
  default     = "Standard"
}

variable "enable_tls_inspection" {
  description = "Generate a demo outbound CA, install HTTPS inspection policy, and trust the public CA on both demo workloads."
  type        = bool
  default     = true

  validation {
    condition     = var.checkpoint_os_version != "R81" || !var.enable_tls_inspection
    error_message = "R81 Management API 1.7 cannot automate the outbound HTTPS Inspection CA or gateway setting. Set enable_tls_inspection=false, or use R82/R8210 for automated TLS inspection."
  }
}

variable "enable_inbound_demo" {
  description = "Expose TCP/18080 through the gateway and configure DNAT to the primary workload TCP/8080."
  type        = bool
  default     = false
}

variable "inbound_demo_source_cidr" {
  description = "Restricted source CIDR for the optional inbound DNAT demo."
  type        = string
  default     = ""

  validation {
    condition = !var.enable_inbound_demo || (
      var.inbound_demo_source_cidr != "" &&
      var.inbound_demo_source_cidr != "0.0.0.0/0" &&
      can(cidrnetmask(var.inbound_demo_source_cidr))
    )
    error_message = "enable_inbound_demo=true requires a restricted inbound_demo_source_cidr."
  }
}

variable "log_analytics_retention_days" {
  description = "Queryable Check Point Syslog retention in Log Analytics."
  type        = number
  default     = 90

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "log_analytics_retention_days must be between 30 and 730."
  }
}

variable "immutable_retention_days" {
  description = "Initial unlocked WORM retention period for continuously exported Syslog blobs."
  type        = number
  default     = 365

  validation {
    condition     = var.immutable_retention_days >= 30 && var.immutable_retention_days <= 3650
    error_message = "immutable_retention_days must be between 30 and 3650."
  }
}

variable "enable_log_data_export" {
  description = "Create Log Analytics continuous export after the Syslog table has received its first record. Managed by scripts/enable-audit-export.sh."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional Azure resource tags."
  type        = map(string)
  default     = {}
}
