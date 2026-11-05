# Facilitator only. Creates a Cast AI node configuration for nrg-stag-us-east-1 with traps 2 and 3
# (and the zone extra) armed or fixed by variable, and makes it the cluster default so the first
# rebalance and any new node uses it. It does NOT touch the configuration castctl created, so you can
# diff the two in the console. Apply AFTER Chris enables automation and BEFORE the first rebalance.
#
#   export CASTAI_API_TOKEN=...
#   terraform init
#   terraform apply -var cluster_id=<id> -var cast_instance_profile_arn=<arn>
#
# Chris fixes things in the console (or his own IaC). If you re-apply, you overwrite his fix, so only
# re-apply to re-arm, or to reset between runs. See guides/02-node-configuration-traps.md.

data "terraform_remote_state" "infra" {
  backend = "local"
  config  = { path = var.infra_state_path }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  subnet_ids = [for az in sort(keys(local.infra.private_subnets_by_az)) : local.infra.private_subnets_by_az[az]]
  subnets    = var.zone_two_subnets ? slice(local.subnet_ids, 0, 2) : local.subnet_ids

  instance_profile_arn = (
    var.trap2_decoy_profile ? local.infra.trap2_decoy_instance_profile_arn :
    var.trap2_no_kms_profile ? var.cast_instance_profile_arn :
    local.infra.node_instance_profile_arn
  )
}

resource "castai_node_configuration" "nrg" {
  cluster_id = var.cluster_id
  name       = "nrg-staging"
  subnets    = local.subnets

  disk_cpu_ratio = 0
  min_disk_size  = 100

  eks {
    instance_profile_arn = local.instance_profile_arn
    security_groups      = [local.infra.node_security_group_id, local.infra.cluster_security_group_id]

    # Trap 3. imds_v1 = false is required for the trap: with IMDSv1 still on, the AWS CLI falls back to it
    # and succeeds even at hop limit 1.
    imds_v1        = false
    imds_hop_limit = var.trap3_hop_limit_1 ? 1 : 2
  }
}

resource "castai_node_configuration_default" "nrg" {
  cluster_id       = var.cluster_id
  configuration_id = castai_node_configuration.nrg.id
}
