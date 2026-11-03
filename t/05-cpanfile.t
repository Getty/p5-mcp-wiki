#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny;
use File::Find::Rule;

# Reads only: compares the modules lib/ and bin/ load with the cpanfile.

my %OPTIONAL = map { $_ => 1 } qw( Git::Raw );    # loaded via eval require; recommends, never requires
my %INDIRECT = map { $_ => 1 } qw( Mojolicious ); # needed by MCP::Server, never loaded by our code
my %FALLBACK_CORE = map { $_ => 1 } qw(
  strict warnings Carp Getopt::Long Pod::Usage Digest::SHA File::Spec
);

# pragmas and the like: they name no distribution to declare
my %PRAGMA = map { $_ => 1 } qw(
  strict warnings feature utf8 lib parent base constant vars overload integer
  bytes open if less sort subs locale mro re fields diagnostics bigint bignum
  bigrat bigfloat charnames encoding filetest sigtrap vmsish threads
);

my $have_corelist = eval { require Module::CoreList; 1 };
sub is_core {
  my ($mod) = @_;
  return $have_corelist ? defined Module::CoreList->first_release($mod)
                        : $FALLBACK_CORE{$mod};
}

# modules loaded by lib/ and bin/ (POD and comments stripped)
my %used;
for my $file ( File::Find::Rule->file->name( '*.pm', 'mcp-wiki' )->in( 'lib', 'bin' ) ) {
  my $in_pod = 0;
  for my $line ( path($file)->lines_utf8 ) {
    if ( $line =~ /^=cut\b/ )       { $in_pod = 0; next }
    if ( $line =~ /^=[a-zA-Z]/ )    { $in_pod = 1; next }
    next if $in_pod;
    $line =~ s/#.*//;
    while ( $line =~ /\b(?:use|require)\s+([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*)/g ) {
      my $mod = $1;
      next if $PRAGMA{$mod};
      next if $mod =~ /^v\d/;    # use v5.36
      $used{$mod} = 1;
    }
  }
}
delete $used{$_} for grep { /^MCP::Wiki(?:::|$)/ } keys %used;
ok( scalar keys %used, 'found loaded modules in lib/ and bin/' );

# cpanfile: top-level (runtime) requires/recommends only
my ( %requires, %recommends, $min_perl );
my $depth = 0;
for my $line ( path('cpanfile')->lines_utf8 ) {
  $line =~ s/#.*//;
  if ( $line =~ /^\s*on\s+\w+\s*=>\s*sub\s*\{/ ) { $depth++; next }
  if ( $line =~ /^\s*\}\s*;/ )                   { $depth--; next }
  next if $depth;
  $min_perl = $1  if $line =~ /^\s*requires\s+'perl'\s*,\s*'?([0-9._]+)'?/;
  $requires{$1}   = 1 if $line =~ /^\s*requires\s+'([^']+)'/;
  $recommends{$1} = 1 if $line =~ /^\s*(?:recommends|suggests)\s+'([^']+)'/;
}
# perl is a language version, not a module: checked below, not by the loaders
delete $requires{perl};
my %declared = ( %requires, %recommends );

# a declared distribution may cover a family (MCP covers MCP::Server)
sub covered {
  my ($mod) = @_;
  return 1 if $declared{$mod};
  return scalar grep { index( $mod, $_.'::' ) == 0 } keys %declared;
}

for my $mod ( sort keys %used ) {
  next if is_core($mod);
  ok( covered($mod), $mod.' is declared in cpanfile' );
}

for my $mod ( sort keys %requires ) {
  my $loaded = $used{$mod}
    || $INDIRECT{$mod}
    || grep { index( $_, $mod.'::' ) == 0 } keys %used;
  ok( $loaded, 'requires '.$mod.' is loaded by lib/ or bin/' );
}

ok( defined $min_perl && $min_perl >= 5.020, 'cpanfile declares a minimum perl of at least 5.020' )
  or diag( 'minimum perl in cpanfile: '.( $min_perl // 'none' ) );

for my $mod ( sort keys %OPTIONAL ) {
  ok( !$requires{$mod},  $mod.' is not a hard requirement' );
  ok( $recommends{$mod}, $mod.' is listed as recommends' );
}

done_testing;
