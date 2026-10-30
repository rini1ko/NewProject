# One-time bootstrap (Part 1, Step 7 of the lab): the IAM role that HCP Terraform assumes through
# OIDC. Run it LOCALLY with your own AWS credentials and a local state; skip it if you
# already created this role in class.
#
#   cd infra/bootstrap
#   terraform init
#   terraform apply -var tfc_organization=<your HCP organization> -var region=<AWS_REGION>
#
# Then add two environment variables to the project's HCP workspace:
#   TFC_AWS_PROVIDER_AUTH = true
#   TFC_AWS_RUN_ROLE_ARN  = <role_arn output>

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

variable "tfc_organization" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region
}

data "tls_certificate" "tfc" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "tfc" {
  name = "hcp-terraform-${var.tfc_organization}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        StringLike = {
          "app.terraform.io:sub" = "organization:${var.tfc_organization}:project:*:workspace:*:run_phase:*"
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to the services the workspace manages
# and the trust to one workspace (a question for class).
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}
