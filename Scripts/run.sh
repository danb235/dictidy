#!/usr/bin/env bash
# Builds the app bundle if needed, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d "RewriteDB.app" ]; then
    ./Scripts/build-app.sh
fi
open RewriteDB.app
