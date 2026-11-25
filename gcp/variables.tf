variable "project_id" {
  type        = string
  description = "Google Cloud project ID (permanent, globally unique), e.g. spry-yourname-2026"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "image" {
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
  description = "API image. Starts as Google's hello image so that the first apply works before you have pushed your own: see README."
}

variable "db_running" {
  type        = bool
  default     = true
  description = "false stops the Cloud SQL instance (activation policy NEVER): compute stops billing, storage does not."
}

variable "db_deletion_protection" {
  type    = bool
  default = false # a throwaway lab database; keep it true for anything real
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Sign-in stays on AWS Cognito for now: the API checks its tokens"
}

variable "cognito_client_id" {
  type = string
}

variable "extra_cors_origins" {
  type        = list(string)
  default     = ["http://localhost:5173"]
  description = "Besides the Firebase Hosting site, which is added automatically"
}

variable "allow_unauthenticated" {
  type        = bool
  default     = true
  description = "Cloud Run only lets the request in; the API still requires a valid Cognito token on every route except /api/health"
}
