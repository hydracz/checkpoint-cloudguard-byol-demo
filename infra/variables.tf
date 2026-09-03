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

variable "management_cidrs" {
  description = "Additional trusted private/VPN administrator CIDRs allowed to reach the dedicated management NIC. The management subnet is always included automatically."
  type        = list(string)
  default     = []

  validation {
    condition = (
      length(var.management_cidrs) <= 49 &&
      !contains(var.management_cidrs, "0.0.0.0/0") &&
      alltrue([
        for cidr in var.management_cidrs :
        try(
          cidrnetmask(cidr) != "" &&
          tonumber(split("/", cidr)[1]) >= 0 &&
          tonumber(split("/", cidr)[1]) <= 32 &&
          cidrhost(cidr, 0) == split("/", cidr)[0],
          false,
        )
      ])
    )
    error_message = "management_cidrs must contain at most 49 canonical IPv4 networks with /1-/32 prefixes; 0.0.0.0/0 is not allowed."
  }
}

variable "checkpoint_admin_password" {
  description = "Password for the built-in Gaia admin account. Deployment wrappers hash this value locally for console and CLI/Portal login; SSH remains public-key-only."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = var.checkpoint_admin_password == "" || (
      length(var.checkpoint_admin_password) >= 8 &&
      length(var.checkpoint_admin_password) <= 128 &&
      !strcontains(var.checkpoint_admin_password, "*") &&
      length(regexall("[\r\n]", var.checkpoint_admin_password)) == 0 &&
      length(compact([
        can(regex("[a-z]", var.checkpoint_admin_password)) ? "lower" : "",
        can(regex("[A-Z]", var.checkpoint_admin_password)) ? "upper" : "",
        can(regex("[0-9]", var.checkpoint_admin_password)) ? "number" : "",
        can(regex("[^A-Za-z0-9]", var.checkpoint_admin_password)) ? "special" : "",
      ])) >= 3
    )
    error_message = "checkpoint_admin_password must be 8-128 characters, contain at least three of lowercase, uppercase, number, and special characters, and must not contain '*' or a newline."
  }
}

variable "checkpoint_admin_password_hash" {
  description = "Internal SHA-512 salted hash populated by the deployment wrappers. Do not set this directly."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = (
      var.checkpoint_admin_password_hash == "" ||
      can(regex("^\\$6\\$[A-Za-z0-9./]{2,16}\\$[A-Za-z0-9./]{1,86}$", var.checkpoint_admin_password_hash))
    )
    error_message = "checkpoint_admin_password_hash must be empty or a SHA-512 crypt hash generated by the deployment wrappers."
  }
}

variable "admin_ssh_public_key" {
  description = "SSH public key used for the Check Point and Linux demo VMs. Deployment scripts generate a repository-local key when omitted."
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

variable "enable_management_workstation" {
  description = "Deploy a private Windows Server workstation and Basic Azure Bastion in the Check Point hub VNet for future SmartConsole use."
  type        = bool
  default     = true
}

variable "windows_client_vm_size" {
  description = "Size of the Windows Server management workstation. Standard_D4ls_v6 provides 4 vCPU and 8 GiB."
  type        = string
  default     = "Standard_D4ls_v6"
}

variable "windows_client_admin_username" {
  description = "Local administrator account for the Windows management workstation."
  type        = string
  default     = "azureadmin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9._-]{2,19}$", var.windows_client_admin_username))
    error_message = "windows_client_admin_username must be 3-20 characters, start with a letter, and contain only letters, digits, period, underscore, or hyphen."
  }
}

variable "windows_client_admin_password" {
  description = "Optional Windows administrator password. Leave empty to generate one; retrieve it with 'terraform -chdir=infra output -raw windows_client_admin_password'."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = var.windows_client_admin_password == "" || (
      length(var.windows_client_admin_password) >= 12 &&
      length(var.windows_client_admin_password) <= 123 &&
      length(regexall("[\r\n]", var.windows_client_admin_password)) == 0 &&
      length(compact([
        can(regex("[a-z]", var.windows_client_admin_password)) ? "lower" : "",
        can(regex("[A-Z]", var.windows_client_admin_password)) ? "upper" : "",
        can(regex("[0-9]", var.windows_client_admin_password)) ? "number" : "",
        can(regex("[^A-Za-z0-9]", var.windows_client_admin_password)) ? "special" : "",
      ])) >= 3
    )
    error_message = "windows_client_admin_password must be empty or 12-123 characters with at least three of lowercase, uppercase, number, and special characters, and no newline."
  }
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

variable "management_subnet_prefix" {
  description = "Private subnet shared by the Check Point eth0 management NIC and Windows management workstation."
  type        = string
  default     = "10.60.3.0/24"

  validation {
    condition     = can(cidrnetmask(var.management_subnet_prefix)) && endswith(var.management_subnet_prefix, "/24")
    error_message = "management_subnet_prefix must be a valid IPv4 /24."
  }
}

variable "bastion_subnet_prefix" {
  description = "Dedicated AzureBastionSubnet prefix in the Check Point hub VNet."
  type        = string
  default     = "10.60.4.0/26"

  validation {
    condition     = can(cidrnetmask(var.bastion_subnet_prefix)) && endswith(var.bastion_subnet_prefix, "/26")
    error_message = "bastion_subnet_prefix must be a valid IPv4 /26."
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

variable "skip_policy_configuration" {
  description = "When the optional configure-policy.sh script is run, skip Management API objects, rules, and policy installation while retaining Gaia routes, GUI clients, and Log Exporter configuration."
  type        = bool
  default     = true
}

variable "enable_tls_inspection" {
  description = "Enable TLS inspection in the optional post-deployment policy automation. The infrastructure-only deployment ignores this setting."
  type        = bool
  default     = false

  validation {
    condition = (
      (
        var.checkpoint_os_version != "R81" ||
        !var.enable_tls_inspection ||
        var.r81_tls_manually_configured
      ) &&
      (!var.r81_tls_manually_configured || var.enable_tls_inspection)
    )
    error_message = "R81 Management API 1.7 cannot automate the outbound HTTPS Inspection CA or gateway setting. Set enable_tls_inspection=false, or set r81_tls_manually_configured=true after completing the documented SmartConsole bootstrap."
  }
}

variable "r81_tls_manually_configured" {
  description = "Assert that the R81 outbound CA, gateway HTTPS Inspection setting, layer, and Inspect rule were configured in SmartConsole. Requires CHECKPOINT_TLS_CA_FILE when installing workload trust."
  type        = bool
  default     = false

  validation {
    condition     = !var.r81_tls_manually_configured || var.checkpoint_os_version == "R81"
    error_message = "r81_tls_manually_configured=true is valid only for R81."
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
    condition = !var.enable_inbound_demo || try(
      cidrnetmask(var.inbound_demo_source_cidr) != "" &&
      tonumber(split("/", var.inbound_demo_source_cidr)[1]) >= 1 &&
      tonumber(split("/", var.inbound_demo_source_cidr)[1]) <= 32 &&
      cidrhost(var.inbound_demo_source_cidr, 0) == split("/", var.inbound_demo_source_cidr)[0],
      false,
    )
    error_message = "enable_inbound_demo=true requires a canonical, restricted IPv4 network; use /32 for one IP."
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
