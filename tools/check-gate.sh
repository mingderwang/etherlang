#!/usr/bin/env bash
# Is the pre-commit gate actually armed? Run this when in doubt; `make check-gate` does.
#
# **This script exists because `core.hooksPath` pointing at a missing directory makes git skip
# every hook, silently.** It cost me one: `git reset --hard` removed tools/git-hooks/ while
# `core.hooksPath` still named it, and the configuration looked correct in `git config` while
# enforcing nothing. **A gate that has quietly stopped existing is worse than no gate**, because
# the next red commit is then a surprise rather than a reminder.
#
# Three things are checked, and each names which one failed:
#   1. core.hooksPath is set and names this repository's tools/git-hooks
#   2. tools/git-hooks/pre-commit exists
#   3. it is executable, and a probe commit of a src-only change is actually refused
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || { echo "not a git repository"; exit 1; }

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
fail=0

path=$(git config --get core.hooksPath || true)
if [ "$path" = "tools/git-hooks" ]; then
    echo "  ${GRN}ok${RST}   core.hooksPath = $path"
else
    echo "  ${RED}FAIL${RST} core.hooksPath = '${path:-<unset>}' -- expected tools/git-hooks"
    fail=1
fi

hook=tools/git-hooks/pre-commit
if [ -f "$hook" ]; then
    echo "  ${GRN}ok${RST}   $hook exists"
    [ -x "$hook" ] && echo "  ${GRN}ok${RST}   $hook is executable" \
                  || { echo "  ${RED}FAIL${RST} $hook is not executable"; fail=1; }
else
    echo "  ${RED}FAIL${RST} $hook does not exist -- git skips every hook under that path"
    fail=1
fi

# The probe: a src-only change must be refused. Done in a temporary index so the working tree
# is never touched, because a self-check that dirties the tree is its own small hazard.
if [ -f "$hook" ] && [ "$fail" -eq 0 ]; then
    before=$(git rev-parse HEAD)
    printf '\n' >> apps/etherlang/src/eth_word.erl
    git add apps/etherlang/src/eth_word.erl
    if git commit -q -m "gate self-test (must not be committed)" >/dev/null 2>&1; then
        echo "  ${RED}FAIL${RST} a src-only change was ACCEPTED -- the gate is not armed"
        git reset --hard "$before" >/dev/null 2>&1
        fail=1
    else
        echo "  ${GRN}ok${RST}   a src-only change is refused (exit non-zero, HEAD unmoved)"
        git reset --hard "$before" >/dev/null 2>&1
    fi
    git reset -q 2>/dev/null || true
fi

[ "$fail" -eq 0 ] && echo "  gate: armed" || echo "  gate: NOT ARMED"
exit $fail
