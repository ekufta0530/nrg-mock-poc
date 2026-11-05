variable "aws_profile" {
  description = "AWS CLI profile to use. null = the CLI's default credentials (what was active at build time)."
  type        = string
  default     = null
}

variable "allowed_account_ids" {
  description = "Guard rail: Terraform refuses to run against any other account."
  type        = list(string)
  default     = ["445567108000"]
}

variable "region" {
  description = "AWS region for the POV cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. The trainee brief and CAST AI scripts assume nrg-stag-us-east-1."
  type        = string
  default     = "nrg-stag-us-east-1"
}

variable "kubernetes_version" {
  description = "EKS control plane version (standard support through 2027-03)."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Lock this down to office/VPN ranges if you can."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "Extra IAM principals (facilitator, trainee SSO roles) granted cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "node_pools" {
  description = <<-EOT
    Self-managed node groups. general / memory / burst mirror nrg-prod-us-east-1's pools at staging scale.
    Defaults keep staging deliberately over-provisioned (the savings story).

    Beyond those three:
      - spot             a pool that makes sense: stateless, interruption-tolerant workloads (label-renderer).
      - app-loadgen,     the sprawl anti-pattern, one tiny node group per app (checkout-loadgen,
        app-producer,    routing-producer, redis-queue) with a dedicated label + taint. Each runs a single
        app-queue        ~250m pod. This is what Chris is asked to consolidate.

    Optional per pool: spot (mixed-instances policy, 100% Spot), instance_types (Spot overrides; the first
    is also the launch template type), labels (extra node labels), taints (kubelet registration taints,
    "key=value:Effect").
  EOT
  type = map(object({
    instance_type  = string
    min_size       = number
    max_size       = number
    desired_size   = number
    spot           = optional(bool, false)
    instance_types = optional(list(string), [])
    labels         = optional(map(string), {})
    taints         = optional(list(string), [])
  }))
  default = {
    general = { instance_type = "m5.xlarge", min_size = 2, max_size = 4, desired_size = 3 }
    memory  = { instance_type = "r5.large", min_size = 1, max_size = 3, desired_size = 2 }
    burst   = { instance_type = "c5.xlarge", min_size = 1, max_size = 3, desired_size = 1 }

    # Stateless label rendering tolerates interruption: 3 replicas, no local state, re-rendered on retry.
    spot = {
      instance_type  = "m5.xlarge"
      instance_types = ["m5.xlarge", "m5a.xlarge", "m5n.xlarge", "m4.xlarge", "m5d.xlarge"]
      spot           = true
      min_size       = 1
      max_size       = 4
      desired_size   = 2
      labels         = { "nrg.io/capacity-type" = "spot" }
      taints         = ["nrg.io/capacity-type=spot:NoSchedule"]
    }

    # Sprawl: one node group per app, each hosting a single 250m pod.
    app-loadgen = {
      instance_type = "t3.medium", min_size = 1, max_size = 2, desired_size = 1
      taints        = ["nrg.io/dedicated=checkout-loadgen:NoSchedule"]
    }
    app-producer = {
      instance_type = "t3.medium", min_size = 1, max_size = 2, desired_size = 1
      taints        = ["nrg.io/dedicated=routing-producer:NoSchedule"]
    }
    app-queue = {
      instance_type = "t3.medium", min_size = 1, max_size = 2, desired_size = 1
      taints        = ["nrg.io/dedicated=redis-queue:NoSchedule"]
    }
  }
}

variable "enable_trap2_unmapped_decoy" {
  description = <<-EOT
    Trap 2 optional extra layer: create nrg-stag-app-node-role-v2 + instance profile that has KMS access
    but is NOT mapped in EKS access entries. Hand its ARN to the trainee as "the right profile":
    nodes launch but never register, and the rebalance times out.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}

variable "gitops_repo_url" {
  description = "Git repo Argo CD syncs (HTTPS or SSH URL of this project, pushed to GitHub). Written into the generated root Application."
  type        = string
  default     = "https://github.com/CHANGE-ME/nrg-mock-poc.git"
}

variable "gitops_revision" {
  description = "Branch/tag Argo CD tracks."
  type        = string
  default     = "main"
}

variable "argocd_chart_version" {
  description = "argo/argo-cd Helm chart version."
  type        = string
  default     = "10.11.7"
}

variable "write_gitops_files" {
  description = "Write the Terraform-derived files Argo CD needs (cluster-autoscaler Application, notifications ConfigMap) into this repo."
  type        = bool
  default     = true
}

variable "cluster_autoscaler_chart_version" {
  description = "kubernetes/autoscaler cluster-autoscaler chart version (9.59.0 ships CA 1.35.0; keep the CA minor in step with kubernetes_version)."
  type        = string
  default     = "9.59.0"
}
