#!/usr/bin/env bash
# Shared helpers for tools/* scripts. bash 3.2 compatible (macOS default bash).
#
# Two roots (StudWork v1.4.0, docs/framework/games-repo.md):
#   CORE_ROOT     this repo (roblox-core), found from this file's location
#   PROJECT_ROOT  the project the tool works on: $STUDWORK_PROJECT_ROOT, default CORE_ROOT
#                 (a games repo sets it in its tools/ wrappers; the core must sit INSIDE it,
#                 normally as the git submodule roblox-core/)
# Every tool runs from PROJECT_ROOT. CORE_DIR is the core's path RELATIVE to PROJECT_ROOT ("."
# when they are the same); core files are reached as "$(core_path <path>)". Both are exported
# (STUDWORK_PROJECT_ROOT, STUDWORK_CORE_DIR) for the Lune tools (tools/lune/Roots.luau).
# REPO_ROOT is kept as an alias of PROJECT_ROOT.
set -euo pipefail

CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! PROJECT_ROOT="$(cd "${STUDWORK_PROJECT_ROOT:-$CORE_ROOT}" 2>/dev/null && pwd)"; then
	echo "error: STUDWORK_PROJECT_ROOT is not a folder: ${STUDWORK_PROJECT_ROOT:-}" >&2
	exit 1
fi
export PATH="$HOME/.rokit/bin:$PATH"

# core_rel <project> <core>: the core's path relative to the project (empty if outside it)
core_rel() {
	if [ "$1" = "$2" ]; then
		echo "."
	else
		case "$2" in
		"$1"/*) echo "${2#"$1"/}" ;;
		*) echo "" ;;
		esac
	fi
}
CORE_DIR="$(core_rel "$PROJECT_ROOT" "$CORE_ROOT")"
if [ -z "$CORE_DIR" ]; then
	# symlinked folders: compare the physical paths
	CORE_DIR="$(core_rel "$(cd "$PROJECT_ROOT" && pwd -P)" "$(cd "$CORE_ROOT" && pwd -P)")"
fi
if [ -z "$CORE_DIR" ]; then
	echo "error: the core ($CORE_ROOT) is not inside STUDWORK_PROJECT_ROOT ($PROJECT_ROOT); add it as a submodule (roblox-core/)" >&2
	exit 1
fi
STUDWORK_PROJECT_ROOT="$PROJECT_ROOT"
STUDWORK_CORE_DIR="$CORE_DIR"
export STUDWORK_PROJECT_ROOT STUDWORK_CORE_DIR
REPO_ROOT="$PROJECT_ROOT"
cd "$PROJECT_ROOT"

# true when the project is a games repo (the core is a subfolder of it)
is_games_repo() {
	[ "$CORE_DIR" != "." ]
}

# Rokit's shims (~/.rokit/bin) pick tool versions from the rokit.toml found above the working
# directory, and a games repo has none (pins live only in the core). So in a games repo the tools
# run through .cache/studwork-bin/: links to the exact binaries the CORE's rokit.toml pins, in
# Rokit's tool storage (~/.rokit/tool-storage/<owner>/<repo>/<version>/<tool>, lowercase), put
# first on PATH. A missing binary means `tools/install` (rokit install in the core) hasn't run.
if is_games_repo; then
	STUDWORK_BIN="$PROJECT_ROOT/.cache/studwork-bin"
	mkdir -p "$STUDWORK_BIN"
	while IFS= read -r line; do
		case "$line" in
		*=*\"*/*@*\"*) ;;
		*) continue ;;
		esac
		tool="$(echo "${line%%=*}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
		spec="$(echo "${line#*=}" | tr -d ' "')"
		owner_repo="$(echo "${spec%@*}" | tr '[:upper:]' '[:lower:]')"
		version="${spec##*@}"
		bin="$HOME/.rokit/tool-storage/$owner_repo/$version/$tool"
		if [ -x "$bin" ]; then
			ln -sf "$bin" "$STUDWORK_BIN/$tool"
		fi
	done <"$CORE_ROOT/rokit.toml"
	export PATH="$STUDWORK_BIN:$PATH"
fi

# core_path <path>: a core-relative path as seen from PROJECT_ROOT
core_path() {
	if [ "$CORE_DIR" = "." ]; then
		echo "$1"
	else
		echo "$CORE_DIR/$1"
	fi
}

# lune_tool <name> [args...]: run the core's tools/lune/<name>
lune_tool() {
	local name="$1"
	shift
	lune run "$(core_path "tools/lune/$name")" "$@"
}

# game_dir <name|path>: a game folder of the project (games/<g>; in the core repo also
# examples/<g>, examples/overrides/<g>; or a folder path) with a default.project.json and src/.
# Prints nothing when there is none.
game_dir() {
	local g="${1%/}"
	local d
	[ -n "$g" ] || return 0
	for d in "$g" "games/$g" "examples/$g" "examples/overrides/$g"; do
		if [ -f "$d/default.project.json" ] && [ -d "$d/src" ]; then
			echo "$d"
			return 0
		fi
	done
	return 0
}

die() {
	echo "error: $*" >&2
	exit 1
}

# Load the PROJECT's git-ignored .env if present (KEY=VALUE lines). Never echo values: xtrace is
# switched off while it is sourced (a `bash -x` trace would otherwise print every assignment) and
# restored after.
load_env() {
	local had_x=0
	case "$-" in *x*) had_x=1 ;; esac
	{ set +x; } 2>/dev/null
	if [ -f "$PROJECT_ROOT/.env" ]; then
		set -a
		# shellcheck disable=SC1091
		. "$PROJECT_ROOT/.env"
		set +a
	fi
	if [ "$had_x" -eq 1 ]; then set -x; fi
}
