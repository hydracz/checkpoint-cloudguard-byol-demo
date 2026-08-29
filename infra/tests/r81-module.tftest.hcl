mock_provider "azurerm" {}
mock_provider "random" {}

run "r81_planless_full_module_plan" {
  command = plan

  variables {
    subscription_id                = "00000000-0000-0000-0000-000000000000"
    tenant_id                      = "00000000-0000-0000-0000-000000000000"
    client_id                      = "00000000-0000-0000-0000-000000000000"
    client_secret                  = "validation-only"
    management_cidr                = "203.0.113.10/32"
    admin_ssh_public_key           = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINrbzTpCfh3HdCuNNixUv4ZIwRdvtxGlkzkErWrpPqbQ terraform-validation"
    sic_key                        = "validation-only-sic-key"
    checkpoint_os_version          = "R81"
    checkpoint_image_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-image-rg/providers/Microsoft.Compute/galleries/example-gallery/images/checkpoint-r81-planless/versions/1.0.0"
    checkpoint_image_requires_plan = false
    enable_log_data_export         = false
    enable_tls_inspection          = false
  }

  assert {
    condition     = local.checkpoint_offer == "cgi-mgmt-r81" && !local.checkpoint_source_requires_plan
    error_message = "The complete Check Point module must accept the R81 planless image branch."
  }
}
