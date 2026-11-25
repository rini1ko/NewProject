terraform {
  required_version = ">= 1.10"

  # Its own state in its own HCP Terraform workspace: one plan can never break both clouds.
  # Without an HCP workspace, `terraform init -backend=false` is enough for `terraform validate`.
  cloud {
    organization = "ooad-rini1ko"

    workspaces {
      name = "spry-gcp"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
