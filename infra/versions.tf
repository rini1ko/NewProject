terraform {
  required_version = ">= 1.10"

  # State lives in HCP Terraform. One workspace = one environment (this one: dev).
  # Fill in your organization and workspace name, then run `terraform init`.
  cloud {
    organization = "ooad-rini1ko"

    workspaces {
      name = "new-project-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  # Lab 4's rule (every resource is tagged PROJECT_NAME) now costs one block.
  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}
