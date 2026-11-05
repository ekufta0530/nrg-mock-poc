data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = merge({
    Project     = "nrg-mock-poc"
    Environment = "staging"
    Owner       = "se-onboarding"
    ManagedBy   = "terraform"
    persist     = "true"
  }, var.tags)
}

################################################################################
# VPC — 3 AZs, private + public subnets, single NAT to keep staging cheap
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  tags = local.tags

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]      # /20s
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)] # /24s

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

################################################################################
# EKS
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  tags = local.tags

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Both modes so the trainee can talk about aws-auth *and* access entries (trap 2 extra layer).
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # Self-managed node groups, like prod (prod: general=m5, memory=r5, burst=c5; staging mirrors the
  # three pools at lower counts). All three share the customer-owned node role/profile, which is what
  # trap 2 hinges on.
  self_managed_node_groups = {
    for pool, cfg in var.node_pools : pool => {
      name            = "${var.cluster_name}-ng-${pool}"
      use_name_prefix = false

      ami_type      = "AL2023_x86_64_STANDARD" # cgroup v2: trap 5 depends on it
      instance_type = cfg.instance_type

      # Spot pool: 100% Spot via a mixed-instances policy (several similar-size types to ride out capacity dips).
      use_mixed_instances_policy = cfg.spot
      mixed_instances_policy = cfg.spot ? {
        instances_distribution = {
          on_demand_base_capacity                  = 0
          on_demand_percentage_above_base_capacity = 0
          spot_allocation_strategy                 = "price-capacity-optimized"
        }
        override = [for t in cfg.instance_types : { instance_type = t }]
      } : null

      min_size     = cfg.min_size
      max_size     = cfg.max_size
      desired_size = cfg.desired_size

      # Customer-owned node role + instance profile with the KMS inline policy (trap 2).
      create_iam_instance_profile = false
      iam_instance_profile_arn    = aws_iam_instance_profile.node.arn
      iam_role_arn                = aws_iam_role.node.arn
      # One access entry per role: only the first pool creates it.
      create_access_entry = pool == "general"

      # Launch template: IMDSv2 required, hop limit 2 so pods can reach IMDS (trap 3 contrast).
      launch_template_name            = "${var.cluster_name}-ng-${pool}"
      launch_template_use_name_prefix = false
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Node labels (and optional taints) via nodeadm: nrg.io/pool=<pool> plus any per-pool extras, so
      # workloads can select their pool.
      cloudinit_post_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              flags:
                - --node-labels=${join(",", [for k, v in merge({ "nrg.io/pool" = pool }, cfg.labels) : "${k}=${v}"])}
                ${length(cfg.taints) > 0 ? "- --register-with-taints=${join(",", cfg.taints)}" : "# no taints"}
        EOT
      }]

      # Cluster Autoscaler auto-discovery (prod runs the OSS Cluster Autoscaler today).
      autoscaling_group_tags = {
        persist                                         = "true"
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }
}

################################################################################
# IRSA for platform add-ons (contrast: the platform uses IRSA, notifications doesn't)
################################################################################

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  tags = local.tags

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  tags = local.tags

  role_name                        = "${var.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}
