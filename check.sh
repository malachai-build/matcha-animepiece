#!/usr/bin/env bash
# Static gate: luau-lsp analyze on every chunk, the concatenation and loader.lua.
# Pass: zero SyntaxError in every file, and the loader lists every chunk in src/.
set -e
cd "$(dirname "$0")"
LSP="${LUAU_LSP:-/c/Users/Oscar/.rokit/tool-storage/johnnymorganz/luau-lsp/1.66.1/luau-lsp.exe}"
mkdir -p dist
bash build.sh >/dev/null
fail=0
for f in src/*.lua dist/anime_piece.full.lua loader.lua; do
  out="dist/an_$(basename "$f" .lua).txt"
  "$LSP" analyze --platform=standard "$f" > "$out" 2>&1 || true
  syn=$(grep -c SyntaxError "$out" || true)
  printf '%-28s syntax errors: %s\n' "$f" "$syn"
  [ "$syn" = "0" ] || fail=1
done
for f in src/*.lua; do
  name=$(basename "$f" .lua)
  grep -q "\"$name\"" loader.lua || { echo "loader.lua does not list $name"; fail=1; }
  grep -q "LACED_LOAD.done\[\"$name\"\]" "$f" || { echo "$f has no end marker"; fail=1; }
done
exit $fail
