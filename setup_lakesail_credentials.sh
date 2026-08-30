#!/usr/bin/env bash

set -Eeuo pipefail

AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-${HOME}/lakesail-credentials}"
SOURCE_AWS_PROFILE="${SOURCE_AWS_PROFILE:-default}"
AWS_PROFILE="${AWS_PROFILE:-lakesail}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

main() {
  local temp_credentials=""

  require_command aws
  require_command jq
  require_command install
  require_command mktemp

  temp_credentials="$(mktemp)"
  trap 'rm -f "$temp_credentials"' EXIT

  printf 'Exporting AWS credentials from profile %s to %s\n' \
    "$SOURCE_AWS_PROFILE" "$AWS_CREDENTIALS_FILE"

  aws configure export-credentials \
    --profile "$SOURCE_AWS_PROFILE" \
    --format process | \
    jq -r --arg aws_profile "$AWS_PROFILE" '
      "[\($aws_profile)]",
      "aws_access_key_id = \(.AccessKeyId)",
      "aws_secret_access_key = \(.SecretAccessKey)",
      "aws_session_token = \(.SessionToken)"
    ' > "$temp_credentials"

  install -m 600 "$temp_credentials" "$AWS_CREDENTIALS_FILE"

  printf 'Wrote credentials file %s with profile %s\n' \
    "$AWS_CREDENTIALS_FILE" "$AWS_PROFILE"
}

main "$@"
