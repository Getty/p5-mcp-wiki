#!/usr/bin/env bash
# Prepare a build leg of the mcp-wiki binary: Git::Raw 0.90 without OpenSSL and libssh2.
# usage: scripts/binary-prepare.sh <cache dir>   -- run from the dist root, CI only
# The bundle's dzil-binary.yml runs it once per leg, after the packing perl and
# before the deps install, with the deps local lib active; the workflow restores
# and saves the cache dir per leg. Prints "prepare: OK" or "FAIL: <reason>" and exits 1.
#
# Git::Raw 0.90's Makefile.PL turns SSL and SSH on whenever its probe
# (Devel::CheckLib) finds their headers - there is no switch to turn them off -
# and the binary then needs the host's libssl/libssh2 at runtime. mcp-wiki only
# does local git, so the headers are hidden. Runners are throwaway: nothing is
# restored, which is why this refuses to run anywhere else.
set -u

fail() {
  printf 'FAIL: %s\n' "$*"
  exit 1
}

[ "${GITHUB_ACTIONS:-}" = true ] ||
  fail 'binary-prepare.sh runs only on a CI runner: it hides the system OpenSSL and libssh2 headers and restores nothing'

[ $# -eq 1 ] || fail 'usage: binary-prepare.sh <cache dir>'
cache=$1
# Git Bash: D:\a\... -> /d/a/... (GNU tar takes "D:" for a remote host)
if command -v cygpath >/dev/null 2>&1; then cache=$(cygpath -u "$cache"); fi
case $cache in
  /*) ;;
  *) fail "the cache dir is not an absolute path: $1" ;;
esac
[ -n "${PERL_LOCAL_LIB_ROOT:-}" ] ||
  fail 'no local lib is active (PERL_LOCAL_LIB_ROOT): Git::Raw would land in the packing perl'
for tool in perl curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is needed on PATH"
done
perl -S cpanm --version >/dev/null 2>&1 || fail 'cpanm is needed on PATH'
mkdir -p "$cache" || fail "cannot create the cache dir: $cache"

work='' part=''
cleanup() {
  if [ -n "$part" ]; then rm -f "$part"; fi
  if [ -n "$work" ]; then rm -rf "$work"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# What the probe would find: libssh2.h and openssl/opensslconf.h in the
# compiler's default include dirs, plus Makefile.PL's darwin incpaths.
case $(uname -s) in
  Linux)
    hide=(/usr/include/openssl /usr/include/libssh2.h
      /usr/local/include/openssl /usr/local/include/libssh2.h) ;;
  Darwin)
    # Intel Homebrew lives in /usr/local, which clang searches by default;
    # /opt/local is MacPorts. Headers only: brew's curl needs the dylibs.
    hide=(/usr/local/opt/openssl/include /usr/local/opt/libssh2/include
      /opt/local/include/libssh2.h /usr/local/include/openssl /usr/local/include/libssh2.h) ;;
  MINGW* | MSYS*)
    # Strawberry ships both in c/include, which its gcc searches
    sperl=$(perl -e 'print $^X') || fail 'cannot locate the packing perl'
    sperl=$(cygpath -u "$sperl")
    straw=$(dirname "$(dirname "$(dirname "$sperl")")")
    echo "Strawberry: $straw"
    hide=("$straw/c/include/openssl" "$straw/c/include/libssh2.h") ;;
  *) fail "unknown build platform: $(uname -s)" ;;
esac
for p in "${hide[@]}"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    mv "$p" "$p.hidden-by-binary-prepare" || fail "cannot hide $p"
    echo "hidden: $p"
  else
    echo "absent: $p"
  fi
done

# The sha256 is the one CPAN's authors/id/J/JA/JACQUESG/CHECKSUMS lists for
# Git-Raw-0.90.tar.gz.
url=https://cpan.metacpan.org/authors/id/J/JA/JACQUESG/Git-Raw-0.90.tar.gz
sum=2d4e08b2912d5e497caf09e64d79123fedb13de63bb8de3800c0dc184b30424e
tarball=$cache/Git-Raw-0.90.tar.gz

check_sum() {    # $1 = file, $2 = what to call it
  local got
  got=$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile(shift, "b")->hexdigest' "$1") ||
    fail "cannot read $2"
  [ "$got" = "$sum" ] || fail "$2: sha256 $got, expected $sum"
}

if [ -f "$tarball" ]; then
  check_sum "$tarball" "$tarball"
  echo "Git-Raw-0.90.tar.gz: from cache ($tarball)"
else
  # download beside the final name, check, then rename: the cache never holds a partial file
  part=$tarball.part.$$
  curl -fsSL --retry 3 -o "$part" "$url" || fail "cannot fetch $url"
  check_sum "$part" "$url"
  mv "$part" "$tarball" || fail "cannot store $tarball"
  part=''
  echo "Git-Raw-0.90.tar.gz: fetched from $url"
fi

# prints Git/Raw.pm's path if Git::Raw 0.90 loads from a root in PERL_LOCAL_LIB_ROOT
# and was built without SSH and, on Linux, without HTTPS - there HTTPS is OpenSSL;
# macOS (SecureTransport) and Windows (WinHTTP) always have it.
gitraw_in_local_lib() {
  perl -MConfig -MFile::Spec -e '
    my $norm = sub {
      ( my $p = File::Spec->rel2abs(shift) ) =~ tr{\\}{/};
      return $^O eq "MSWin32" ? lc $p : $p;
    };
    eval { require Git::Raw; 1 } or exit 1;
    Git::Raw->VERSION eq "0.90" or exit 1;
    my %f = Git::Raw->features;
    exit 1 if $f{ssh} || ( $^O eq "linux" && $f{https} );
    my $file = $norm->( $INC{"Git/Raw.pm"} );
    for my $root ( grep { length } split /\Q$Config{path_sep}\E/, $ENV{PERL_LOCAL_LIB_ROOT} ) {
      if ( index( $file, $norm->($root) . "/" ) == 0 ) { print $INC{"Git/Raw.pm"}; exit 0 }
    }
    exit 1;
  ' 2>/dev/null
}

if where=$(gitraw_in_local_lib); then
  echo "Git::Raw 0.90 is already in the local lib ($where): build skipped"
else
  work=$(mktemp -d) || fail 'cannot create a temp dir'
  tar xzf "$tarball" -C "$work" || fail "cannot unpack $tarball"
  src=$work/Git-Raw-0.90

  # Git::Raw 0.90 bundles zlib 1.2.12, whose zutil.h does
  # "#if defined(MACOS) || defined(TARGET_OS_MAC) ... #define fdopen(fd,mode) NULL",
  # which breaks against the stdio.h of the Xcode 16+ SDKs; zlib 1.3.1 checks only
  # MACOS there. Off macOS neither is defined, so every leg takes the same patch.
  # -i.orig: older Windows perls refuse an in-place edit without a backup.
  zutil=$src/deps/libgit2/deps/zlib/zutil.h
  perl -pi.orig -e 's/^#if defined\(MACOS\) \|\| defined\(TARGET_OS_MAC\)$/#if defined(MACOS)/' "$zutil" ||
    fail "cannot patch $zutil"
  perl -ne '
    $new++ if /^#if defined\(MACOS\)$/;
    $old++ if /^#if defined\(MACOS\) \|\| defined\(TARGET_OS_MAC\)$/;
    END { exit !( ( $new // 0 ) == 1 && !$old ) }
  ' "$zutil" || fail "the zutil.h patch did not apply: $zutil"
  echo "patched: deps/libgit2/deps/zlib/zutil.h"

  log=${PERL_CPANM_HOME:-$HOME/.cpanm}/build.log
  # "." - cpanm takes a directory only when it starts with . or /, and Git Bash
  # turns /d/a/... into D:/a/.... --notest: the binary's verify exercises Git::Raw.
  if ! (cd "$src" && perl -S cpanm --notest .); then
    echo "Git::Raw build failed - the tail of $log:"
    tail -n 80 "$log"
    fail 'Git::Raw 0.90 did not build'
  fi
  [ -f "$log" ] || fail "no cpanm build log at $log: cannot tell how Git::Raw was configured"
  echo 'Git::Raw configure said:'
  grep -E 'support (enabled|disabled)' "$log" | sed 's/^/  /'
  # require both "disabled" lines: a log without an "enabled" line proves nothing
  if ! grep -q '^SSL support disabled' "$log" || ! grep -q '^SSH2 support disabled' "$log"; then
    fail "Git::Raw's configure did not report SSL and SSH2 disabled: a header was not hidden"
  fi
fi

where=$(gitraw_in_local_lib) ||
  fail 'Git::Raw 0.90 does not load from the local lib, or it was built with SSH or OpenSSL'
echo "Git::Raw 0.90 loads from $where"
echo 'prepare: OK'
