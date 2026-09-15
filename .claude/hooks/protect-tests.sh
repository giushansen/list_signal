#!/usr/bin/env bash
# Claude Code PreToolUse hook: existing tests are read-only for agents.
#
# The owner's rule (2026-09-15): no AI agent deletes or rewrites a test
# without the owner's consent. New test files may be created; existing
# ones may not be edited, overwritten, moved or deleted, whether through
# the file tools or through a shell command. Consent is the owner running
# `touch .claude/tests-unlock` in the project root (git-ignored); agents
# must never create that file themselves. Remove it when done.
#
# Same rule, other layer: .githooks/pre-commit refuses to commit such a
# change, so a tool that bypasses this hook still cannot land it.
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -e "$ROOT/.claude/tests-unlock" ]; then exit 0; fi

exec python3 "$ROOT/.claude/hooks/protect-tests.py" "$ROOT"
