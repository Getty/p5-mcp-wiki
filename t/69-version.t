#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Find::Rule;
use Path::Tiny;

my @files = ( File::Find::Rule->file->name('*.pm')->in('lib'), 'bin/mcp-wiki' );

my ($main) = path('lib/MCP/Wiki.pm')->slurp_utf8 =~ /^our \$VERSION = '([^']+)';/m;
plan tests => 1 + @files;

ok( $main, 'MCP::Wiki carries a version' );

for my $file ( sort @files ) {
    my ($v) = path($file)->slurp_utf8 =~ /^our \$VERSION = '([^']+)';/m;
    is( $v, $main, $file . ' carries the version of MCP::Wiki' );
}
