#!/usr/bin/env bash
# Sends one "build this week" message to the report queue: make report-now WEEK=2026-W39
# Without WEEK the builder takes the previous ISO week.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  week="${WEEK:-}"
  if [ -n "$week" ] && ! [[ "$week" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
    echo "WEEK must look like 2026-W39" >&2
    exit 1
  fi
  queue_url="$(output "$PROJECT_NAME-reports" QueueUrl)"
  [ -n "$queue_url" ] && [ "$queue_url" != "None" ] || { echo "Run make deploy-reports first." >&2; exit 1; }

  if [ -n "$week" ]; then body="{\"week\": \"$week\", \"source\": \"make\"}"
  else body='{"week": null, "source": "make"}'; fi
  # boto3 instead of `aws sqs send-message`: AWS CLI v2 on Python 3.14 fails on the sqs
  # command with "badly formed help string". Needs: sudo apt install -y python3-boto3
  QUEUE_URL="$queue_url" BODY="$body" python3 - <<'PY'
import os, re, boto3
url = os.environ["QUEUE_URL"]
region = re.match(r"https://sqs\.([a-z0-9-]+)\.amazonaws\.com/", url).group(1)
resp = boto3.client("sqs", region_name=region).send_message(
    QueueUrl=url, MessageBody=os.environ["BODY"]
)
print("MessageId:", resp["MessageId"])
PY
  echo "Sent $body. Watch: aws logs tail /$PROJECT_NAME/reports-builder --since 5m --filter-pattern triggered"
}

main "$@"