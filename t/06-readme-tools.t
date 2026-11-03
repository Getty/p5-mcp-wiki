#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );
use MCP::Wiki::Server;

# Reads only, apart from a tempdir for the server: the tool table in README.md
# must name exactly the registered tools and, per tool, exactly the required
# and optional arguments of its input schema. lib/ wins; the README follows.

my $readme = path('README.md');
plan skip_all => 'README.md not found (run from the distribution root)' unless $readme->is_file;

# -- what the code registers ------------------------------------------------
my $root   = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => $root->stringify );

my %schema;
for my $tool ( @{ $server->server->tools } ) {
  my $s = $tool->input_schema;
  my %req = map { $_ => 1 } @{ $s->{required} || [] };
  $schema{ $tool->name } = {
    required => [ sort keys %req ],
    optional => [ sort grep { !$req{$_} } keys %{ $s->{properties} || {} } ],
  };
}

# -- what the README documents ---------------------------------------------
my ( $in_section, @header, %doc );
for my $line ( $readme->lines_utf8( { chomp => 1 } ) ) {
  if ( $line =~ /^##\s+MCP Tools\s*$/ ) { $in_section = 1; next }
  next unless $in_section;
  last if $line =~ /^##\s/;
  next unless $line =~ /^\|/;
  my @cell = map { s/^\s+|\s+$//gr } split /\|/, $line =~ s/^\||\|$//gr;
  if ( !@header ) { @header = map {lc} @cell; next }
  next if $line =~ /^\|\s*-/;
  my %row;
  @row{@header} = @cell;
  my ($name) = ( $row{tool} // '' ) =~ /^`([^`]+)`$/ or next;
  $doc{$name} = {
    present  => { map { $_ => exists $row{$_} } qw( required optional ) },
    required => [ sort( ( $row{required} // '' ) =~ /`([^`]+)`/g ) ],
    optional => [ sort( ( $row{optional} // '' ) =~ /`([^`]+)`/g ) ],
  };
}

ok( scalar keys %doc, 'README has a tool table under "MCP Tools"' );
is_deeply( [ sort keys %doc ], [ sort keys %schema ],
  'README documents exactly the registered tools' );

for my $name ( sort keys %schema ) {
  subtest "tool $name" => sub {
    my $d = $doc{$name} or return fail('not in README');
    ok( $d->{present}{required} && $d->{present}{optional},
      'README table has Required and Optional columns' );
    is_deeply( $d->{required}, $schema{$name}{required}, 'required arguments match the schema' );
    is_deeply( $d->{optional}, $schema{$name}{optional}, 'optional arguments match the schema' );
  };
}

# -- CLI: POD options against the Getopt::Long specification ---------------
my $bin = path( 'bin', 'mcp-wiki' )->slurp_utf8;
my ($spec) = $bin =~ /GetOptions\((.*?)\)\s*or\b/s;
my @getopt = sort map { /'([\w-]+)[=!+]?\w*'\s*=>/ ? $1 : () } split /\n/, $spec // '';
my ($pod)  = $bin =~ /^=head1 OPTIONS\b(.*?)(?=^=head1|\z)/ms;
my @pod    = sort( ( $pod // '' ) =~ /^=item\s+B<--([\w-]+)>/mg );

ok( scalar @getopt, 'found GetOptions specification' );
is_deeply( \@pod, \@getopt, 'POD of bin/mcp-wiki documents exactly the Getopt options' );

done_testing;
