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

# Load a git-ignored .env if present (KEY=VALUE lines). Never echo values.
load_env() {
	if [ -f "$REPO_ROOT/.env" ]; then
		set -a
		# shellcheck disable=SC1091
		. "$REPO_ROOT/.env"
		set +a
	fi
}
