#!/usr/bin/env bash
# Deletes the parser stack (Lambda, function URL, budget). Nothing else depends on it.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh
  stack_exists "$AI_STACK" || { echo "Stack $AI_STACK does not exist."; exit 0; }
  echo "==> Deleting $AI_STACK"
  aws cloudformation delete-stack --stack-name "$AI_STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$AI_STACK"
  echo "Done."
}

main "$@"
