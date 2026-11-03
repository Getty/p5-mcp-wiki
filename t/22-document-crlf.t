#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Document;

# A page whose first line ends in CRLF is a CRLF page: bodies come back with
# LF, writes go out with CRLF, so the file stays consistent and an unchanged
# get -> set trip is byte-identical. LF pages behave as before.

my $LF = "# Title\nintro\n## Sub ##\nsub body\n\n## Next\nnext\n";
( my $CRLF = $LF ) =~ s/\n/\r\n/g;

my $dir = tempdir;
my $n   = 0;

sub doc_for {
  my ($bytes) = @_;
  my $file = $dir->child( 'p'.( ++$n ).'.md' );
  $file->spew_raw($bytes);
  return ( MCP::Wiki::Document->new( file_path => "$file", wiki_root => "$dir" ), $file );
}

sub has_cr {
  my (@entries) = @_;
  return scalar grep { /\r/ } map { ( $_->heading, $_->heading_path ) } @entries;
}

subtest 'LF control page behaves as before' => sub {
  my ( $doc, $file ) = doc_for($LF);
  is( $doc->get_paragraph('Title#Sub')->{content}, "sub body\n", 'body' );
  $doc->set_paragraph( 'Title#Sub', "sub body\n" );
  is( $file->slurp_raw, $LF, 'unchanged get -> set is byte-identical' );
  $doc->set_paragraph( 'Title#Sub', "line1\nline2\n" );
  is( $file->slurp_raw, "# Title\nintro\n## Sub ##\nline1\nline2\n\n## Next\nnext\n", 'set writes LF' );
};

subtest 'CRLF page: TOC carries no CR' => sub {
  my ($doc) = doc_for($CRLF);
  my @toc = $doc->get_toc;
  is_deeply( [ map { $_->heading_path } @toc ], [ 'Title', 'Title#Sub', 'Title#Next' ], 'heading_paths' );
  is_deeply( [ map { $_->heading } @toc ], [ 'Title', 'Sub', 'Next' ], 'headings' );
  ok( !has_cr(@toc), 'no \\r in heading or heading_path' );
};

subtest 'CRLF page: get_paragraph returns the LF body' => sub {
  my ($doc) = doc_for($CRLF);
  my $p = $doc->get_paragraph('Title#Sub');
  is( $p->{content}, "sub body\n", 'same body as the LF page' );
  unlike( $p->{content}, qr/\r/, 'no \\r anywhere' );
  my ($lf_doc) = doc_for($LF);
  is( $p->{content}, $lf_doc->get_paragraph('Title#Sub')->{content}, 'CRLF result equals LF result' );
};

subtest 'CRLF page: unchanged get -> set is byte-identical' => sub {
  my ( $doc, $file ) = doc_for($CRLF);
  $doc->set_paragraph( 'Title#Sub', $doc->get_paragraph('Title#Sub')->{content} );
  is( $file->slurp_raw, $CRLF, 'bytes identical' );
};

subtest 'CRLF page: unchanged round trip keeps a missing final line ending' => sub {
  ( my $bytes = $CRLF ) =~ s/\r\n\z//;
  my ( $doc, $file ) = doc_for($bytes);
  $doc->set_paragraph( 'Title#Next', $doc->get_paragraph('Title#Next')->{content} );
  is( $file->slurp_raw, $bytes, 'bytes identical, no final CRLF added' );
};

subtest 'CRLF page: set writes CRLF throughout' => sub {
  my ( $doc, $file ) = doc_for($CRLF);
  $doc->set_paragraph( 'Title#Sub', "line1\nline2\n" );
  my $got = $file->slurp_raw;
  is( $got, "# Title\r\nintro\r\n## Sub ##\r\nline1\r\nline2\r\n\r\n## Next\r\nnext\r\n", 'exact bytes' );
  unlike( $got, qr/(?<!\r)\n/, 'no bare LF' );
  unlike( $got, qr/\r\r/, 'no doubled CR' );
  my @toc = MCP::Wiki::Document->new( file_path => "$file", wiki_root => "$dir" )->get_toc;
  ok( !has_cr(@toc), 'TOC still free of \\r' );
};

subtest 'a page without any newline counts as LF' => sub {
  my ( $doc, $file ) = doc_for('# Only');
  $doc->set_paragraph( 'Only', "a\nb" );
  is( $file->slurp_raw, "# Only\na\nb", 'LF endings' );
};

done_testing;
