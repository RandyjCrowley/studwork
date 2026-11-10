#!/usr/bin/env bash
# Shared helpers for tools/* scripts. bash 3.2 compatible (macOS default bash).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.rokit/bin:$PATH"
cd "$REPO_ROOT"

die() {
	echo "error: $*" >&2
	exit 1
}

# Load a git-ignored .env if present (KEY=VALUE lines). Never echo values: xtrace is switched off
# while it is sourced (a `bash -x` trace would otherwise print every assignment) and restored after.
load_env() {
	local had_x=0
	case "$-" in *x*) had_x=1 ;; esac
	{ set +x; } 2>/dev/null
	if [ -f "$REPO_ROOT/.env" ]; then
		set -a
		# shellcheck disable=SC1091
		. "$REPO_ROOT/.env"
		set +a
	fi
	if [ "$had_x" -eq 1 ]; then set -x; fi
}
