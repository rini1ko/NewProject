# Cognito user pool, domain, Google sign-in and the web app client (was auth.yaml, Lab 4).

# Deleting the pool deletes every account in it, so Terraform may never destroy it
# (the CloudFormation template had DeletionPolicy: Retain for the same reason).
resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"

  # Users sign in with their email; Cognito emails a code to verify it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # A new email takes effect only after its code is entered.
  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  username_configuration {
    case_sensitive = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  # Mirrored by the signup form (frontend/src/pages/signup-page.tsx).
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = false
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: no SES setup, limited to about 50 emails a day.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your Meetings verification code"
    email_message        = "Your Meetings verification code is {####}"
  }

  lifecycle {
    prevent_destroy = true
    # The schema of a pool cannot be changed after creation; ignoring it keeps a harmless
    # difference in how the API reports it from forcing a replacement.
    ignore_changes = [schema]
  }
}

# Hosted domain for the OAuth endpoints (needed for Google). Prefixes are global.
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.project_name}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_identity_provider" "google" {
  count = local.google_enabled ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Cognito fills in these URLs itself when it creates a Google provider. They are written out
  # so that Terraform does not try to remove them after the import.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    username       = "sub" # added by Cognito by default
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
  }
}

# Public client (no secret): the SPA talks to Cognito directly with SRP.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Referencing the provider makes the client wait for it (no DependsOn to write by hand).
  supported_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # "<origin>/login" for every origin: the CloudFormation Split/Join trick is one expression.
  callback_urls = [for url in local.app_urls : "${url}/login"]
  logout_urls   = [for url in local.app_urls : "${url}/login"]
}
