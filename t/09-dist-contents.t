use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path );

# What dist.ini keeps out of the tarball. The tarball is the Docker build
# context and what CPAN ships, so the agent and repo housekeeping files at the
# top level must not be in it; the files the image and the install need must.

plan skip_all => 'dist.ini not found (run from the distribution root)'
  unless path('dist.ini')->is_file;

my @exclude = map { qr/$_/ }
  path('dist.ini')->slurp_utf8 =~ /^gather_exclude_match\s*=\s*(\S+)\s*$/mg;

sub excluded {
    my ($file) = @_;
    return scalar grep { $file =~ $_ } @exclude;
}

ok( scalar @exclude, 'dist.ini excludes files from the tarball' );

for my $file ( '.claude/agents/mcp-wiki-worker.md', '.claude/settings.json', '.codex',
    'CLAUDE.md', 'PLAN.md', '.worktreeinclude', '.gitignore' ) {
    ok( excluded($file), "$file stays out of the tarball" );
}

for my $file ( '.dockerignore', 'Dockerfile', 'docker-entrypoint.sh', 'cpanfile', 'Changes',
    'bin/mcp-wiki', 'lib/MCP/Wiki.pm', 't/00-load.t', 'misc/agent-context/CLAUDE.md',
    'lib/MCP/CLAUDE.md', 'docs/.gitignore' ) {
    ok( !excluded($file), "$file is shipped" );
}

done_testing;
