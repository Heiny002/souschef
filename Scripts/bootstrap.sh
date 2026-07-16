#!/usr/bin/env bash
#
# bootstrap.sh — one-time local setup for building SousChef.
#
# The Xcode project's base configuration points at Secrets.xcconfig, which is
# gitignored so real API keys never reach the repo. Without it, the build emits
# a warning and the LLM-fallback features are inert. This script creates it from
# the committed template if it is missing.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f Secrets.xcconfig ]; then
  echo "✓ Secrets.xcconfig already exists — nothing to do."
else
  cp Secrets.example.xcconfig Secrets.xcconfig
  echo "✓ Created Secrets.xcconfig from Secrets.example.xcconfig."
  echo "  Edit it and set ANTHROPIC_API_KEY to enable LLM-fallback extraction."
  echo "  (The app builds and runs without a key; those features stay inert.)"
fi
