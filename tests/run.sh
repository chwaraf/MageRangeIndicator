#!/usr/bin/env bash
#
# Offline spec for MageRangeIndicator.
#
# Loads the addon against tests/wow_stub.lua under real Lua 5.1 - the version
# WoW runs - so the range logic, the secret-value guards and both client paths
# can be checked without a game client.
#
#   tests/run.sh
#
# Needs python3 with lupa (which embeds the Lua 5.1 interpreter):
#
#   python3 -m venv .venv && .venv/bin/pip install lupa
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"

has_lupa() {
    [ -n "$1" ] && [ -x "$1" ] && "$1" -c 'import lupa.lua51' >/dev/null 2>&1
}

python="${MRI_PYTHON:-}"
if ! has_lupa "$python"; then python="$(command -v python3 || true)"; fi
if ! has_lupa "$python"; then python="$repo/.venv/bin/python"; fi
if ! has_lupa "$python"; then python="$(dirname "$repo")/.venv/bin/python"; fi

if ! has_lupa "$python"; then
    echo "lupa with the Lua 5.1 backend is required:" >&2
    echo "  python3 -m venv .venv && .venv/bin/pip install lupa" >&2
    echo "(or point MRI_PYTHON at an interpreter that has it)" >&2
    exit 2
fi

exec "$python" - "$repo" <<'PY'
import sys
import lupa.lua51 as lupa

repo = sys.argv[1]
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.globals().REPO_ROOT = repo
lua.execute('dofile(REPO_ROOT .. "/tests/spec.lua")')
PY
