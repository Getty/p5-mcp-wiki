#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir path );
use MCP::Wiki::Document;

# One operation acts on one consistent snapshot of the page: get_paragraph and
# set_paragraph read the file once and parse and splice that same string.
# The hook sits on Path::Tiny's read methods, so it does not depend on which
# of them Document uses or on Document's private method names.

my @READERS = qw( slurp slurp_utf8 slurp_raw lines lines_utf8 lines_raw );

my ( $watch, $reads, $after_first_read, $depth );
$depth = 0;

for my $name (@READERS) {
  no strict 'refs';
  no warnings 'redefine';
  my $orig = \&{ 'Path::Tiny::'.$name };
  *{ 'Path::Tiny::'.$name } = sub {
    # slurp_utf8 and friends call each other: count the outermost call only
    $depth++;
    my $guard = bless sub { $depth-- }, "Guard21";
    my @ret = wantarray ? $orig->(@_) : scalar $orig->(@_);
    if ( $depth == 1 && defined $watch && "$_[0]" eq $watch ) {
      $reads++;
      if ( $reads == 1 && $after_first_read ) {
        my $cb = $after_first_read;
        undef $after_first_read;
        $cb->();
      }
    }
    return wantarray ? @ret : $ret[0];
  };
}

my $ORIGINAL = <<'MD';
# Top

## A

A body.

## B

B body.
MD

# A second writer inserts a section above B between our (first) read and any
# further read.
my $CONCURRENT = <<'MD';
# Top

## New

New body.

## A

A body.

## B

B body.
MD

sub fresh_doc {
  my $dir  = tempdir;
  my $file = $dir->child('p.md');
  $file->spew_utf8($ORIGINAL);
  my $doc = MCP::Wiki::Document->new( file_path => "$file", wiki_root => "$dir" );
  return ( $doc, $file, $dir );
}

sub concurrent_writer {
  my ($file) = @_;
  return sub { $file->spew_utf8($CONCURRENT) };
}

subtest 'get_paragraph reads the page once' => sub {
  my ( $doc, $file, $dir ) = fresh_doc();
  ( $watch, $reads ) = ( "$file", 0 );
  my $p = $doc->get_paragraph('Top#B');
  is( $reads, 1, 'exactly one read of the page' );
  is( $p->{content}, "\nB body.", 'body of B' );
  undef $watch;
};

subtest 'set_paragraph reads the page once' => sub {
  my ( $doc, $file, $dir ) = fresh_doc();
  ( $watch, $reads ) = ( "$file", 0 );
  ok( $doc->set_paragraph( 'Top#B', "\nNEW B." ), 'set_paragraph succeeds' );
  is( $reads, 1, 'exactly one read of the page' );
  undef $watch;
  is( $file->slurp_utf8, "# Top\n\n## A\n\nA body.\n\n## B\n\nNEW B.\n", 'file holds the edit' );
};

subtest 'get_paragraph answers from the snapshot it parsed' => sub {
  my ( $doc, $file, $dir ) = fresh_doc();
  ( $watch, $reads ) = ( "$file", 0 );
  $after_first_read = concurrent_writer($file);
  my $p = $doc->get_paragraph('Top#B');
  undef $watch;
  is( $p->{content}, "\nB body.", 'body is the one from the parsed snapshot, not shifted lines' );
  is( $p->{line_start}, 7, 'line range belongs to the same snapshot' );
};

subtest 'set_paragraph edits the section it parsed, not what appeared meanwhile' => sub {
  my ( $doc, $file, $dir ) = fresh_doc();
  ( $watch, $reads ) = ( "$file", 0 );
  $after_first_read = concurrent_writer($file);
  $doc->set_paragraph( 'Top#B', "\nNEW B." );
  undef $watch;
  my $got = $file->slurp_utf8;
  is( $got, "# Top\n\n## A\n\nA body.\n\n## B\n\nNEW B.\n",
    'B got the new body; the edit was spliced into the parsed snapshot' );
};

done_testing;

package Guard21;
sub DESTROY { $_[0]->() }
