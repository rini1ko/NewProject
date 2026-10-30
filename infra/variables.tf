variable "project_name" {
  type        = string
  description = "PROJECT_NAME from .env; prefix of every resource name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.project_name))
    error_message = "project_name must start with a letter and contain only a-z, 0-9 and -."
  }
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region of the project (AWS_REGION in .env)."
}

# ----------------------------------------------------------------------------- auth (Lab 4)
variable "google_client_id" {
  type        = string
  default     = ""
  description = "Google OAuth client id; empty keeps Google sign-in disabled."
}

variable "google_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth client secret. Set it as a sensitive variable in the HCP workspace, never in a file."
}

variable "extra_app_urls" {
  type        = list(string)
  default     = ["http://localhost:5173", "http://localhost:3000"]
  description = "Frontend origins besides the deployed site (the CloudFront address and custom domain are read from the frontend stack)."
}

# ----------------------------------------------------------------------------- reports (Lab 5)
variable "report_email" {
  type        = string
  description = "Sender and recipient of the weekly report (a verified SES identity)."
}

variable "schedule_expression" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "Use rate(5 minutes) to test, then set it back."
}

variable "schedule_target" {
  type        = string
  default     = "direct"
  description = "direct = the schedule invokes the builder; queue = the schedule sends to SQS."

  validation {
    condition     = contains(["direct", "queue"], var.schedule_target)
    error_message = "schedule_target must be direct or queue."
  }
}

variable "schedule_state" {
  type    = string
  default = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.schedule_state)
    error_message = "schedule_state must be ENABLED or DISABLED."
  }
}

variable "db_name" {
  type    = string
  default = "meetings"
}

variable "db_user" {
  type    = string
  default = "meetings"
}

# ----------------------------------------------------------------------------- agenda parser (Lab 6)
variable "parser_model" {
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  description = "Bedrock model ID (or inference profile) used by the agenda parser."
}

variable "parser_api" {
  type        = string
  default     = "converse"
  description = "converse = Bedrock Converse API; messages = Anthropic Messages API on Bedrock."

  validation {
    condition     = contains(["converse", "messages"], var.parser_api)
    error_message = "parser_api must be converse or messages."
  }
}

variable "parser_effort" {
  type    = string
  default = "low"
}

variable "bedrock_region" {
  type    = string
  default = "us-east-1"
}

variable "cors_origins_extra" {
  type        = list(string)
  default     = []
  description = "Extra origins allowed to call the parser (CORS_ORIGINS_AWS in .env)."
}

variable "budget_email" {
  type        = string
  default     = ""
  description = "Gets an email at 80% and 100% of a $5 monthly AWS budget. Empty = no budget."
}
