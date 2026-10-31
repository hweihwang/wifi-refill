#!/bin/bash
# Builds Wi-Fi Refill, replaces the copy in ~/Applications and starts it. For development on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(scripts/build-app.sh "${1:-0.0.0}" | tail -1)
pkill -x WiFiRefill || true
rm -rf ~/Applications/"Wi-Fi Refill.app"
ditto "$app" ~/Applications/"Wi-Fi Refill.app"
open ~/Applications/"Wi-Fi Refill.app"
