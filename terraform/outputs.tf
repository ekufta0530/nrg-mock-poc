output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "ecr_registry" {
  description = "Registry host for scripts/deploy.sh and images/build.sh."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.images : k => r.repository_url }
}

output "asg_names" {
  description = "Self-managed node group ASG names by pool (reset.sh restores their sizes)."
  value       = { for k, g in module.eks.self_managed_node_groups : k => g.autoscaling_group_name }
}

output "node_role_arn" {
  description = "nrg-stag-app-node-role (has kms:Decrypt)."
  value       = aws_iam_role.node.arn
}

output "node_instance_profile_arn" {
  description = "TRAP 2 FIX: set the CAST AI node configuration's instance profile ARN to this."
  value       = aws_iam_instance_profile.node.arn
}

output "trap2_decoy_instance_profile_arn" {
  description = "Trap 2 extra layer: KMS-capable profile whose role is NOT mapped in access entries."
  value       = try(aws_iam_instance_profile.decoy[0].arn, null)
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  value = module.eks.cluster_primary_security_group_id
}

output "private_subnets_by_az" {
  description = "Useful for the optional zone-mismatch extra (list only two of these in the CAST AI node configuration)."
  value       = zipmap(module.vpc.azs, module.vpc.private_subnets)
}

output "kms_key_arn" {
  value = aws_kms_key.app.arn
}

output "kms_alias" {
  value = aws_kms_alias.app.name
}

output "notifications_config_ciphertext" {
  description = "Base64 KMS ciphertext; scripts/deploy.sh puts it in the notifications-config ConfigMap."
  value       = aws_kms_ciphertext.notifications_config.ciphertext_blob
}

output "argocd_port_forward" {
  value = "kubectl -n argocd port-forward svc/argocd-server 8080:80   # admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "gitops_repo_url" {
  value = var.gitops_repo_url
}

output "gitops_revision" {
  value = var.gitops_revision
}

output "node_pools" {
  description = "Pool sizing (reset.sh restores the ASGs to these)."
  value       = var.node_pools
}
