#!/usr/bin/env bash
# Deploys the weekly report (S3, SQS, Scheduler, builder + mailer Lambdas, SES identity).
# Run via `make deploy-reports` after `make deploy-backend`.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  : "${REPORT_EMAIL:?Set REPORT_EMAIL in .env (sender and recipient, e.g. you@example.com)}"
  stack_exists "$BACKEND_STACK" || { echo "Run make deploy-backend first." >&2; exit 1; }
  REPORTS_STACK="$PROJECT_NAME-reports"

  # The backend stack must already expose the new outputs (make deploy-backend, succeeded).
  image_uri="$(output "$BACKEND_STACK" ImageUri 2>/dev/null || true)"
  case "$image_uri" in
    "" | None)
      echo "The backend stack has no ImageUri output yet: make deploy-backend must succeed first." >&2
      exit 1
      ;;
  esac

  db_password="$(aws ssm get-parameter --name "/$PROJECT_NAME/db-password" --with-decryption \
    --query Parameter.Value --output text)"

  echo "==> Deploying $REPORTS_STACK (schedule target: ${REPORT_SCHEDULE_TARGET:-direct})"
  aws cloudformation deploy \
    --stack-name "$REPORTS_STACK" \
    --template-file infra/reports.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image_uri" \
      "VpcId=$(output "$BACKEND_STACK" VpcId)" \
      "SubnetIds=$(output "$BACKEND_STACK" PrivateSubnetIds)" \
      "SecurityGroupId=$(output "$BACKEND_STACK" FunctionSecurityGroupId)" \
      "RouteTableId=$(output "$BACKEND_STACK" PrivateRouteTableId)" \
      "DatabaseEndpoint=$(output "$BACKEND_STACK" DatabaseEndpoint)" \
      "DBPassword=$db_password" \
      "ReportEmail=$REPORT_EMAIL" \
      "ScheduleTarget=${REPORT_SCHEDULE_TARGET:-direct}" \
      "ScheduleExpression=${REPORT_SCHEDULE_EXPRESSION:-cron(0 7 ? * MON *)}" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  echo
  echo "Bucket: $(output "$REPORTS_STACK" BucketName)"
  echo "Queue:  $(output "$REPORTS_STACK" QueueUrl)"
  echo "SES sent a confirmation link to $REPORT_EMAIL: open it once, or no email will be sent."
}

main "$@"