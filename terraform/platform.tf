################################################################################
# ECR repositories for the two custom images
################################################################################

resource "aws_ecr_repository" "images" {
  for_each = toset(["nrg-worker", "nrg-loadgen"])

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

################################################################################
# Argo CD — the only add-on Terraform installs by Helm. Everything else on the
# cluster (metrics-server, Cluster Autoscaler, ingress-nginx, the workloads and,
# later, the CAST AI umbrella chart) is an Argo CD Application under gitops/.
# The root app-of-apps is applied by scripts/bootstrap-gitops.sh once the repo is pushed.
################################################################################

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [yamlencode({
    global = { domain = "argocd.staging.nrg.example" }
    configs = {
      params = { "server.insecure" = true } # reach it with kubectl port-forward; no ingress/TLS in staging
    }
    dex           = { enabled = false }
    notifications = { enabled = false }
    # Requests are small on purpose: this is the platform team's tooling, not part of the savings story.
    controller     = { resources = { requests = { cpu = "250m", memory = "512Mi" } } }
    server         = { resources = { requests = { cpu = "100m", memory = "128Mi" } } }
    repoServer     = { resources = { requests = { cpu = "100m", memory = "256Mi" } } }
    applicationSet = { resources = { requests = { cpu = "50m", memory = "128Mi" } } }
  })]

  depends_on = [module.eks]
}
