//********************* Basic Configurations **************************//
variable "resource_group_name" {
  description = "Azure Resource Group name to build into"
  type        = string
}

variable "location" {
  type        = string
  description = "The location/region where Network Security Group will be created. The full list of Azure regions can be found at https://azure.microsoft.com/regions"
}

variable "security_group_name" {
  description = "Network Security Group name"
  default     = "nsg"
}

variable "tags" {
  description = "The tags to associate with Network Security Group"
  type        = map(string)
  default     = {}
}

variable "enable_nsg" {
  description = "Controls whether a Network Security Group is created or used. Set to false to skip NSG entirely."
  type        = bool
  default     = true
}

variable "nsg_id" {
  description = "If you want to use an existing Network Security Group, provide the ID here"
  type        = string
  default     = ""
}

//********************* Security Rules definition **************************//
variable "security_rules" {
  description = "Security rules for the Network Security Group. Each rule may use source_address_prefix or source_address_prefixes."
  type        = list(any)
  default     = []
}
