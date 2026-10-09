#!/usr/bin/env bash
# Point git at tools/git-hooks/, then **verify the gate is actually armed.**
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$ROOT" config core.hooksPath tools/git-hooks
chmod +x "$ROOT"/tools/git-hooks/* 2>/dev/null || true
exec "$ROOT/tools/check-gate.sh"
