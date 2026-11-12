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
#
# Three layouts (StudWork v1.5.0, docs/framework/single-game-project.md), exported as
# STUDWORK_LAYOUT for the Lune tools (tools/lune/Roots.luau decides the same way):
#   core         CORE_DIR = "."  the framework repo itself
#   single-game  the project root has the committed marker studwork.json with
#                {"layout": "single-game"}: the root IS the game; the core is its studwork/ submodule
#   games-repo   any other project: games/<name>/ folders; the core is its roblox-core/ submodule
set -euo pipefail

STUDWORK_CALLER_PWD="$PWD"
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
# layout_of <project> <core_dir>: core | single-game | games-repo (marker: studwork.json)
layout_of() {
	if [ "$2" = "." ]; then
		echo "core"
	elif [ -f "$1/studwork.json" ] && grep -q '"layout"[[:space:]]*:[[:space:]]*"single-game"' "$1/studwork.json"; then
		echo "single-game"
	else
		echo "games-repo"
	fi
}
STUDWORK_LAYOUT="$(layout_of "$PROJECT_ROOT" "$CORE_DIR")"
export STUDWORK_PROJECT_ROOT STUDWORK_CORE_DIR STUDWORK_LAYOUT STUDWORK_CALLER_PWD
REPO_ROOT="$PROJECT_ROOT"
cd "$PROJECT_ROOT"

# true when the core is a subfolder of the project: a games repo OR (v1.5.0) a single-game
# project. Everything that applies to an external core (toolchain links, the git shim, the
# framework pin) keys on this; use is_single_game to tell the two apart.
is_games_repo() {
	[ "$CORE_DIR" != "." ]
}

# (v1.5.0) true in a single-game project: the project root is the game (studwork.json marker)
is_single_game() {
	[ "$STUDWORK_LAYOUT" = "single-game" ]
}

# (v1.5.0) the root game's name in a single-game project: deploy.json "name" (fallback: the
# project folder's name). Used for build/<name>.rbxl and publish/deploy-stamp.
single_game_name() {
	local n=""
	if [ -f deploy.json ]; then
		n="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' deploy.json | head -1)"
	fi
	[ -n "$n" ] || n="$(basename "$PROJECT_ROOT")"
	echo "$n"
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

	# v1.4.1 fix (known issue V1): git runs hooks with repo-local env vars set: GIT_INDEX_FILE
	# (".git/index", RELATIVE, for a normal commit; an absolute temporary index for a partial
	# `git commit <paths>`) and GIT_PREFIX, plus GIT_DIR/GIT_WORK_TREE in some setups. Inherited by
	# `git -C roblox-core ...` (the framework pin check), they point the submodule's git at the
	# games repo's index ("not a git checkout"). So in a games repo `git` is a shim: a call starting
	# with -C <dir> runs with git's repo-local vars cleared (`git rev-parse --local-env-vars`, keeping
	# -c config like git's own submodule code), every other call keeps the caller's vars, made
	# absolute here, so staged-file checks still read the commit's own index (partial commits too).
	for v in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR; do
		eval "val=\${$v:-}"
		case "$val" in
		"" | /*) ;;
		*) export "$v=$STUDWORK_CALLER_PWD/$val" ;;
		esac
	done
	REAL_GIT="$(command -v git)"
	case "$REAL_GIT" in
	"$STUDWORK_BIN"/*) ;; # nested tool call: the shim is already in place
	*)
		cat >"$STUDWORK_BIN/git.tmp.$$" <<EOF
#!/bin/sh
# generated by roblox-core/tools/_common.sh (v1.4.1): see the comment there
if [ "\${1:-}" = "-C" ]; then
	for v in \$("$REAL_GIT" rev-parse --local-env-vars); do
		case "\$v" in GIT_CONFIG_PARAMETERS | GIT_CONFIG_COUNT) ;; *) unset "\$v" ;; esac
	done
fi
exec "$REAL_GIT" "\$@"
EOF
		chmod +x "$STUDWORK_BIN/git.tmp.$$"
		mv -f "$STUDWORK_BIN/git.tmp.$$" "$STUDWORK_BIN/git"
		;;
	esac
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
# Prints nothing when there is none. In a single-game project (v1.5.0) the game is the root:
# no name, ".", or its deploy.json name -> ".".
game_dir() {
	local g="${1%/}"
	local d
	if is_single_game; then
		if [ -z "$g" ] || [ "$g" = "." ] || [ "$g" = "$(single_game_name)" ]; then
			if [ -f default.project.json ] && [ -d src ]; then echo "."; fi
			return 0
		fi
	fi
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

# help_if_asked <script> "$@": with --help or -h anywhere in the arguments, print the script's
# leading comment block (its usage) and exit 0 (v1.7.0). Works in core, games-repo and
# single-game modes alike (the usage is the tool's own header).
help_if_asked() {
	local script="$1"
	shift
	local a
	for a in "$@"; do
		if [ "$a" = "--help" ] || [ "$a" = "-h" ]; then
			awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$script"
			exit 0
		fi
	done
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
