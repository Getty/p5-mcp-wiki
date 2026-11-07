#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path );

# The standalone binary is declared to the [@Author::GETTY] bundle: dist.ini
# keys, a caller workflow pinned to the bundle's reusable workflow, the binary
# scripts executable in git, and CI that does not build the binary on every
# push. Reads repository files only; no network, nothing written.
#
# The release tarball may ship neither .github/ nor .git, so the checks that
# need them skip when that file is absent, never when it is present.

plan skip_all => 'dist.ini not found (run from the distribution root)'
  unless path('dist.ini')->is_file;

# -- dist.ini declares the binary -----------------------------------------------
my $dist_ini = path('dist.ini')->slurp_utf8;
my %want = (
  binary         => 'mcp-wiki',
  binary_modules => 'MCP::Wiki::Git::History Git::Raw',
  binary_require => 'Git::Raw MCP::Wiki::Git::History',
  binary_prepare => 'scripts/binary-prepare.sh',
  binary_verify  => 'scripts/binary-verify.sh',
  binary_smoke   => 'scripts/binary-smoke.sh',
);
for my $key ( sort keys %want ) {
  like( $dist_ini, qr/^\Q$key\E\s*=\s*\Q$want{$key}\E\s*$/m, "dist.ini: $key = $want{$key}" );
}

# -- caller workflow ---------------------------------------------------------------
SKIP: {
  skip '.github/ not shipped in the distribution', 2 unless path('.github')->is_dir;
  my $wf = path('.github/workflows/binaries.yml');
  ok( $wf->is_file, 'binaries.yml exists' );
  # The whole file is pinned: the plan says "verbatim", and a partial pin
  # let broken callers (no tag input, no permissions) pass.
  my $caller = <<'YAML';
name: binaries
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag:
        description: Release tag to build and attach; empty = probe run
        required: false
jobs:
  binaries:
    permissions:
      contents: write
    uses: Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@binary-v1
    with:
      tag: ${{ github.event.release.tag_name || inputs.tag }}
YAML
  is( ( $wf->is_file ? $wf->slurp_utf8 : '' ), $caller, 'binaries.yml is the bundle caller workflow, verbatim' );
}

# -- scripts tracked and executable ------------------------------------------------
SKIP: {
  skip 'not a git checkout', 2 unless path('.git')->exists;
  my $git = do {
    my ($g) = grep { -x "$_/git" && !-d "$_/git" } split /:/, $ENV{PATH} // '';
    $g ? "$g/git" : undef;
  };
  skip 'git not available', 2 unless $git;
  my @lines = grep { length } split /\n/, scalar qx{$git ls-files -s -- scripts/binary-prepare.sh scripts/binary-verify.sh scripts/binary-smoke.sh 2>/dev/null};
  is( scalar @lines, 3, 'three binary scripts are tracked' );
  is( scalar( grep { /^100755 / } @lines ), 3, 'all of them mode 100755' );
}

# -- CI does not build the binary locally ------------------------------------------
SKIP: {
  my $ci = path('.github/workflows/ci.yml');
  skip 'ci.yml not shipped in the distribution', 1 unless path('.github')->is_dir;
  like( $ci->is_file ? $ci->slurp_utf8 : '', qr/^\s*DZIL_BINARY_SKIP:\s*['"]?1['"]?\s*$/m,
    'ci.yml sets DZIL_BINARY_SKIP: 1' );
}

done_testing;
