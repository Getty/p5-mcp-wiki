#!/usr/bin/env bash
# Verify a packed mcp-wiki binary on the build leg (perl and git present).
# usage: scripts/binary-verify.sh <binary>   -- run from the dist root
# One MCP session twice: a cold first start on a fresh PAR cache, then a warm
# one on the same cache. Prints "verify: OK" or "FAIL: <reason>" and exits 1.
set -u

fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

# the last 40 lines of a run's stderr, before the FAIL line that follows
show_stderr() {
  [ -s "$1" ] && tail -n 40 "$1" | sed 's/^/stderr: /'
  return 0
}

[ $# -ge 1 ] || fail 'usage: binary-verify.sh <binary>'
bin=${!#}
[ -x "$bin" ] || fail "not an executable file: $bin"
command -v perl >/dev/null 2>&1 || fail 'perl is needed to check the answers'
command -v git >/dev/null 2>&1 || fail 'git is needed to check the history'

work=$(mktemp -d) || fail 'cannot create a temp dir'
trap 'rm -rf "$work"' EXIT

# a native path for the binary on Windows (Git Bash), the path itself elsewhere
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

cat >"$work/requests.jsonl" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"binary-verify","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_page","arguments":{"page":"smoke.md","content":"# Intro\n\nHello\n\n## Alpha\n\nOne\n","reason":"smoke: create page"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update_paragraph","arguments":{"page":"smoke.md","heading_path":"Intro#Alpha","content":"Two\n","reason":"smoke: update Alpha"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_section_history","arguments":{"page":"smoke.md","heading_path":"Intro#Alpha"}}}
JSON

cat >"$work/check.pl" <<'PERL'
use strict;
use warnings;
use JSON::PP ();

my ($file) = @ARGV;
my $json = JSON::PP->new;
my ( %by_id, @fail );

open my $fh, '<:raw', $file or die "cannot open $file: $!\n";
my $n = 0;
while ( my $line = <$fh> ) {
  $n++;
  $line =~ s/\r?\n\z//;
  my $msg = eval { $json->decode($line) };
  unless ( ref $msg eq 'HASH' && ( $msg->{jsonrpc} // '' ) eq '2.0' ) {
    push @fail, "stdout line $n is not JSON-RPC: " . substr( $line, 0, 120 );
    next;
  }
  $by_id{ $msg->{id} } = $msg if defined $msg->{id};
}

sub result_of {
  my ($id) = @_;
  my $r = $by_id{$id} or do { push @fail, "no answer for id $id"; return {} };
  push @fail, "id $id is a JSON-RPC error: " . $json->encode( $r->{error} ) if $r->{error};
  return $r->{result} // {};
}

result_of(1);
my @tools = @{ result_of(2)->{tools} // [] };
push @fail, 'expected 15 tools, got ' . scalar(@tools) unless @tools == 15;
for my $id ( 3, 4 ) {
  my $r = result_of($id);
  push @fail, "id $id tool error: " . ( $r->{content}[0]{text} // '' ) if $r->{isError};
}

# the history answer (id 5) lists both reasons
my $h = result_of(5);
push @fail, 'id 5 tool error: ' . ( $h->{content}[0]{text} // '' ) if $h->{isError};
my $history = $json->encode($h);
for my $reason ( 'smoke: create page', 'smoke: update Alpha' ) {
  push @fail, "the history answer lacks '$reason'" if index( $history, $reason ) < 0;
}

if (@fail) { print "$_\n" for @fail; exit 1 }
PERL

run_session() {    # $1 = label
  local label=$1 wiki="$work/wiki-$1"
  # pin the format: Git 3.0 defaults (reftable, SHA-256) are not readable by libgit2 1.5
  git -c init.defaultObjectFormat=sha1 -c init.defaultRefFormat=files init -q "$wiki" || fail 'git init failed'
  local nwiki
  nwiki=$(native "$wiki")
  "$bin" --wiki-root "$nwiki" --git <"$work/requests.jsonl" >"$work/out-$label.jsonl" 2>"$work/err-$label.txt"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    show_stderr "$work/err-$label.txt"
    fail "$label start: the binary exited $rc"
  fi

  if grep -q 'Git is not available' "$work/err-$label.txt"; then
    show_stderr "$work/err-$label.txt"
    fail "$label start: the binary serves without history (Git::Raw missing or the repository rejected)"
  fi
  local problems
  problems=$(perl "$work/check.pl" "$work/out-$label.jsonl") || {
    show_stderr "$work/err-$label.txt"
    fail "$label start: $(printf '%s' "$problems" | tr '\n' ' ')"
  }

  local log
  log=$(git -C "$wiki" log --format=%s 2>/dev/null)
  case $log in *'smoke: create page'*) ;; *) show_stderr "$work/err-$label.txt"; fail "$label start: git log lacks the create reason" ;; esac
  case $log in *'smoke: update Alpha'*) ;; *) show_stderr "$work/err-$label.txt"; fail "$label start: git log lacks the update reason" ;; esac
}

# a fresh PAR cache: the first start unpacks into it, the second reuses it
mkdir "$work/par-cache"
PAR_GLOBAL_TEMP=$(native "$work/par-cache")
PAR_GLOBAL_TMPDIR=$PAR_GLOBAL_TEMP
export PAR_GLOBAL_TEMP PAR_GLOBAL_TMPDIR

run_session cold
run_session warm

echo 'verify: OK'
