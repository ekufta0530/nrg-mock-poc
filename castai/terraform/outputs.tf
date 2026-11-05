output "armed" {
  value = {
    instance_profile_arn = local.instance_profile_arn
    imds_hop_limit       = var.trap3_hop_limit_1 ? 1 : 2
    subnets              = local.subnets
  }
}
