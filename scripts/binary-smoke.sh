#!/bin/sh
# Smoke a packed mcp-wiki binary on a clean machine: no perl, no git, POSIX sh.
# usage: scripts/binary-smoke.sh <binary>   -- run from the dist root
# One MCP session against a hand-laid git repository. Prints "smoke: OK" or
# "FAIL: <reason>" and exits 1.

fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

[ $# -ge 1 ] || fail 'usage: binary-smoke.sh <binary>'
for bin in "$@"; do :; done
[ -x "$bin" ] || fail "not an executable file: $bin"

work=$(mktemp -d) || fail 'cannot create a temp dir'
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# a native path on Windows (Git Bash), the path itself elsewhere
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

# the repository, by hand: git itself is not on this machine
wiki="$work/wiki"
mkdir -p "$wiki/.git/objects" "$wiki/.git/refs/heads" || fail 'cannot lay out the wiki'
printf 'ref: refs/heads/main\n' >"$wiki/.git/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' >"$wiki/.git/config"

cat >"$work/requests.jsonl" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"binary-smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_page","arguments":{"page":"smoke.md","content":"# Intro\n\nHello\n\n## Alpha\n\nOne\n","reason":"smoke: create page"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update_paragraph","arguments":{"page":"smoke.md","heading_path":"Intro#Alpha","content":"Two\n","reason":"smoke: update Alpha"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_section_history","arguments":{"page":"smoke.md","heading_path":"Intro#Alpha"}}}
JSON

out="$work/out.jsonl"
err="$work/err.txt"
"$bin" --wiki-root "$(native "$wiki")" --git <"$work/requests.jsonl" >"$out" 2>"$err"
rc=$?
[ "$rc" -eq 0 ] || fail "the binary exited $rc: $(head -n 1 "$err")"

if grep -q 'Git is not available' "$err"; then
  fail "the binary runs without Git::Raw (stderr: $(head -n 1 "$err"))"
fi

# every stdout line is JSON-RPC, nothing else
if grep -v '"jsonrpc":"2.0"' "$out" | grep -q .; then
  fail 'stdout holds a line that is not JSON-RPC'
fi

for id in 1 2 3 4 5; do
  grep -q "\"id\":${id}[,}]" "$out" || fail "no answer for id $id"
done
grep -q '"error"' "$out" && fail 'the session holds a JSON-RPC error'
grep -q '"isError":true' "$out" && fail 'a tool call answered with isError'

# the tools/list answer: all 15 tools by name
list=$(grep '"id":2[,}]' "$out" | head -n 1)
count=0
for tool in list_pages get_toc get_page get_paragraph create_page update_paragraph \
  write_page add_section delete_section rename_heading search_pages rename_page \
  delete_page get_section_history restore_section; do
  case $list in
    *"\"name\":\"$tool\""*) count=$((count + 1)) ;;
    *) fail "tool $tool is missing from tools/list" ;;
  esac
done
[ "$count" -eq 15 ] || fail "expected 15 tools, got $count"

history=$(grep '"id":5[,}]' "$out" | head -n 1)
case $history in *'smoke: create page'*) ;; *) fail 'the history lacks the create reason' ;; esac
case $history in *'smoke: update Alpha'*) ;; *) fail 'the history lacks the update reason' ;; esac

echo 'smoke: OK'
