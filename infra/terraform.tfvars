# Non-secret values only. Secrets (google_client_secret) are sensitive variables in the
# HCP Terraform workspace. Fill these in from your .env.
project_name = "new-project"
region       = "eu-central-1"

report_email = "zaits.pn@ucu.edu.ua"

parser_api     = "converse"
parser_model   = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
bedrock_region = "us-east-1"
budget_email   = "zaits.pn@ucu.edu.ua"

google_client_id = "576014935628-r424tuv8d6q7kggpttba4qib3a8co9p1.apps.googleusercontent.com"
# cors_origins_extra = []           # CORS_ORIGINS_AWS from .env, if any

schedule_target = "queue"