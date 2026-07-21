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

if [ -f Signing.xcconfig ]; then
  echo "✓ Signing.xcconfig already exists — nothing to do."
else
  cp Signing.example.xcconfig Signing.xcconfig
  echo "✓ Created Signing.xcconfig from Signing.example.xcconfig."
  echo "  Edit it and set DEVELOPMENT_TEAM to run on a physical device."
  echo "  (The app builds for the Simulator without it. Keeping it here instead"
  echo "   of the project file means 'git pull' won't conflict on project.pbxproj.)"
fi
