terraform {
  required_version = ">= 1.6"

  required_providers {
    castai = {
      source  = "castai/castai"
      version = "~> 9.17"
    }
  }
}

# Auth: export CASTAI_API_TOKEN (full-access key for the org Chris connected the cluster to).
provider "castai" {
  api_url = var.castai_api_url
}
