#!/usr/bin/env bash
# Deploys "Paste an agenda": the parser Lambda, its function URL and the $5 budget alarm.
# Run via `make deploy-ai` after `make deploy-backend` (it reuses the backend image, so run it
# again after every backend deploy that changes app/ai).
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  stack_exists "$BACKEND_STACK" || { echo "Run make deploy-backend first." >&2; exit 1; }
  image_uri="$(output "$BACKEND_STACK" ImageUri 2>/dev/null || true)"
  case "$image_uri" in
    "" | None) echo "The backend stack has no ImageUri output: make deploy-backend first." >&2; exit 1 ;;
  esac

  budget_email="${BUDGET_EMAIL:-${REPORT_EMAIL:-}}"
  echo "==> Deploying $AI_STACK (model: ${PARSER_MODEL:-anthropic.claude-opus-5-5})"
  aws cloudformation deploy \
    --stack-name "$AI_STACK" \
    --template-file infra/ai.yml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image_uri" \
      "CognitoUserPoolId=$(output "$AUTH_STACK" UserPoolId)" \
      "CognitoClientId=$(output "$AUTH_STACK" UserPoolClientId)" \
      "CorsOrigins=$(cors_origins)" \
      "ParserModel=${PARSER_MODEL:-anthropic.claude-opus-5-5}" \
      "ParserEffort=${PARSER_EFFORT:-low}" \
      "ParserApi=${PARSER_API:-messages}" \
      "BudgetEmail=$budget_email" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo
  echo "Parser URL: $(output "$AI_STACK" ParseUrl)"
  echo "Put it in the frontend as the parser address, then make deploy-frontend."
  echo "Logs: aws logs tail /$PROJECT_NAME/ai-parser --follow"
}

main "$@"
