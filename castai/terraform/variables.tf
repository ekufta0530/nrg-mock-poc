variable "castai_api_url" {
  type    = string
  default = "https://api.cast.ai"
}

variable "cluster_id" {
  description = "Cast AI cluster ID of nrg-stag-us-east-1 (castctl cluster list, or the console URL). Exists only after Chris has connected the cluster."
  type        = string
}

variable "cast_instance_profile_arn" {
  description = <<-EOT
    The instance profile castctl created for Cast AI nodes (cast-nrg-stag-us-east-1-eks-<id>). It has no KMS access.
    aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName,'cast-nrg-stag')].Arn" --output text
  EOT
  type        = string
}

variable "infra_state_path" {
  description = "State file of the main environment (../../terraform), read for the customer's profile, subnets and security groups."
  type        = string
  default     = "../../terraform/terraform.tfstate"
}

# ---- the switchboard -------------------------------------------------------------------------

variable "trap2_no_kms_profile" {
  description = "Trap 2: use the Cast-generated instance profile (no kms:Decrypt) instead of the customer's nrg-stag-app-node-profile."
  type        = bool
  default     = true
}

variable "trap2_decoy_profile" {
  description = "Trap 2 extra layer: a KMS-capable profile whose role is NOT in EKS access entries (needs enable_trap2_unmapped_decoy=true in ../../terraform). Wins over trap2_no_kms_profile."
  type        = bool
  default     = false
}

variable "trap3_hop_limit_1" {
  description = "Trap 3: IMDSv2 only with hop limit 1, so pods can't reach IMDS. false = hop limit 2, matching the customer's launch templates."
  type        = bool
  default     = true
}

variable "zone_two_subnets" {
  description = "Zone extra: list subnets from only 2 of the 3 AZs (pair with the label-renderer zone trap in Git)."
  type        = bool
  default     = false
}
