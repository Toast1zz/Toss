#!/bin/bash
# One-off: store Telegram API credentials in Toss's Keychain items so the
# setup screen skips straight to the phone number. Optional — typing them
# into the app does the same. Does not log in to Telegram.
#
# Usage: ./scripts/import-credentials.sh <env file> [path/to/Toss.app]
# The env file holds TELEGRAM_API_ID=... and TELEGRAM_API_HASH=...
# Run it against the same signed app you will use (e.g. /Applications/Toss.app)
# so Keychain trusts that app. Delete the env file afterwards.
set -euo pipefail
ENV_FILE="${1:?usage: $0 <env file> [Toss.app]}"
APP="${2:-/Applications/Toss.app}"
"$APP/Contents/MacOS/Toss" --import-credentials "$ENV_FILE"
