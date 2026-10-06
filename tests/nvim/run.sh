#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HERE/../.." && pwd)"
NVIM="${NVIM:-nvim}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
"$HERE/demo_repo.sh" "$T/repo"
export XDG_STATE_HOME="$T/state" GITCPPDIFF_TEST_REPO="$T/repo" GITCPPDIFF_PLUGIN="$PLUGIN"
"$NVIM" --headless -u NONE -i NONE --cmd 'set columns=170 lines=50' -c "luafile $HERE/spec.lua" -c 'qa!' 2>&1
"$NVIM" --headless -u NONE -i NONE -c "luafile $HERE/build_spec.lua" -c 'qa!' 2>&1
