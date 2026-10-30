# Values shared by auth.tf, reports.tf and ai.tf.
#
# The network, database, API and site are still CloudFormation stacks (ecr, backend, frontend,
# certificate). Terraform only reads their outputs.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

data "aws_cloudformation_stack" "frontend" {
  name = "${var.project_name}-frontend"
}

# The database password is created by `make deploy-backend` as a SecureString.
# Note: reading it here puts it into the Terraform state (see ADR 0007).
data "aws_ssm_parameter" "db_password" {
  name            = "/${var.project_name}/db-password"
  with_decryption = true
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  backend  = data.aws_cloudformation_stack.backend.outputs
  frontend = data.aws_cloudformation_stack.frontend.outputs

  # CustomDomainUrl exists only when `make add-domain` was run.
  frontend_urls = compact([
    lookup(local.frontend, "AppUrl", ""),
    lookup(local.frontend, "CustomDomainUrl", ""),
  ])

  # Cognito redirects back to <origin>/login for these (OAuth, Google).
  app_urls = distinct(concat(var.extra_app_urls, local.frontend_urls))

  # Sites allowed to call the agenda parser.
  cors_origins = distinct(concat(local.frontend_urls, var.cors_origins_extra))

  google_enabled = var.google_client_id != ""
  reports_bucket = "${var.project_name}-reports-${local.account_id}"
}
