#!/usr/bin/env bash
# Formats GitHub event payloads with message.jq and posts each resulting
# message to a Discord webhook. Used by action.yml and
# security-advisories/action.yml.
#
# Environment:
#   WEBHOOK  Discord webhook URL
#   EVENT    event name to format the payloads as
#   PAYLOAD  file of one or more event payloads
set -euo pipefail

messages="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/discord.XXXXXX")"
trap 'rm -f "$messages"' EXIT

jq --compact-output --arg event "$EVENT" \
  --from-file "$(dirname "$0")/message.jq" \
  "$PAYLOAD" > "$messages"

if [ ! -s "$messages" ]; then
  echo "Skipping: draft pull request, or posted by a bot"
  exit 0
fi
if [ -z "${WEBHOOK:-}" ]; then
  echo "::error::webhook-url is empty; is the secret set, and is this a pull_request event from a fork?"
  exit 1
fi
first=true
while IFS= read -r message; do
  # Stay under Discord's webhook rate limit when posting several
  $first || sleep 1
  first=false
  printf '%s' "$message" | curl --fail-with-body --silent --show-error \
    --header "Content-Type: application/json" \
    --data @- \
    "${WEBHOOK}?with_components=true"
done < "$messages"
