# Shared setup for the infra scripts: credentials and settings come from .env via make.
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID in .env}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY in .env}"
: "${AWS_REGION:?Set AWS_REGION in .env}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
[ -n "${AWS_SESSION_TOKEN:-}" ] || unset AWS_SESSION_TOKEN

# APP_NAME is the old name of the setting and still works.
PROJECT_NAME="${PROJECT_NAME:-${APP_NAME:-meetings}}"
ECR_STACK="$PROJECT_NAME-ecr"
BACKEND_STACK="$PROJECT_NAME-backend"
FRONTEND_STACK="$PROJECT_NAME-frontend"
# Cognito, the weekly report and the agenda parser are Terraform now (infra/*.tf, state in HCP
# Terraform); their values are read with tf_output. The network, API, database and site are
# still CloudFormation stacks.
TF_DIR="infra"
# CloudFront only accepts certificates from us-east-1.
CERT_STACK="$PROJECT_NAME-certificate"
CERT_REGION="us-east-1"

# Every resource is tagged PROJECT_NAME=<PROJECT_NAME>: explicitly in the templates, via the
# stack tags (which also cover resources CloudFormation creates implicitly), and by the
# scripts for resources created outside CloudFormation.
TAG_KEY="PROJECT_NAME"
STACK_TAGS=("$TAG_KEY=$PROJECT_NAME")

# output STACK KEY [REGION]: prints one CloudFormation stack output (empty if absent).
output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# tf_output NAME: prints one Terraform output (`terraform output -raw`). Needs `terraform login`
# and `terraform init` in infra/ once. Nothing is applied here: applies run in HCP Terraform.
tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

# stack_exists STACK [REGION]
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${2:-$AWS_REGION}" >/dev/null 2>&1
}

# cors_origins: the sites allowed to call the API: the CloudFront address and custom domain
# (once the frontend stack exists) plus CORS_ORIGINS_AWS.
cors_origins() {
  local candidates="" origins="" origin
  if stack_exists "$FRONTEND_STACK"; then
    candidates="$(output "$FRONTEND_STACK" AppUrl),$(output "$FRONTEND_STACK" CustomDomainUrl)"
  fi
  # Read line by line rather than word-splitting, so "*" (allow any origin) is not
  # expanded into file names.
  while IFS= read -r origin; do
    origin="${origin//[[:space:]]/}"
    [ -n "$origin" ] && origins="${origins:+$origins,}$origin"
  done < <(echo "$candidates,${CORS_ORIGINS_AWS:-}" | tr ',' '\n')
  echo "${origins:-http://localhost:5173}"
}

# update_backend_cors: points the backend's CORS_ORIGINS at the current frontend addresses.
# Every other backend parameter keeps its previous value.
update_backend_cors() {
  local origins
  origins="$(cors_origins)"
  echo "    CORS origins: $origins"
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "CorsOrigins=$origins" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  # The agenda parser's CORS list and Cognito's redirect URLs are Terraform's job: see
  # update_auth_urls.
}

# update_auth_urls: Cognito's redirect URLs and the parser's CORS origins are Terraform now.
# They are computed from the frontend stack's outputs, so a new Terraform run picks up a new
# CloudFront address or custom domain. Nothing is applied from here.
update_auth_urls() {
  echo "    Cognito redirect URLs and the parser's CORS list follow the frontend stack:"
  echo "    start a run in HCP Terraform (workspace UI: New run) so they pick up the change."
}

# require_auth_stack: exits with a hint when Terraform's outputs are not available.
require_auth_stack() {
  tf_output user_pool_id >/dev/null 2>&1 || {
    echo "Terraform outputs not available. Once: terraform login, then make infra-init;" >&2
    echo "and the HCP Terraform workspace must have been applied at least once." >&2
    exit 1
  }
}
