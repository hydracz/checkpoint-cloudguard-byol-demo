locals {
  module_name    = "single_terraform_registry"
  module_version = "1.0.9"
  extended_zone_region_map = {
    "losangeles" = ["westus"]
    "perth"      = ["australiaeast"]
  }
  vm_os_sku              = "${var.installation_type == "standalone" ? "mgmt-byol" : var.vm_os_sku}${(var.hyper_v_generation == "V2" && var.installation_type != "standalone") ? "-gen2" : ""}"
  is_blink               = var.installation_type == "gateway"
  template_name          = var.enable_ipv6 ? "single_terraform_registry_dual_stack" : "single_terraform_registry"
  source_image_id_set    = trimspace(var.source_image_id) != ""
  use_custom_image       = local.source_image_id_set || module.custom_image.create_custom_image
  custom_image_id        = local.source_image_id_set ? trimspace(var.source_image_id) : module.custom_image.id
  source_image_uses_plan = !local.use_custom_image || var.source_image_requires_plan
}
