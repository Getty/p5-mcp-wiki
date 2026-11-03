#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Encode ();
use Path::Tiny qw( tempdir );

binmode $_, ':encoding(UTF-8)' for Test::More->builder->output, Test::More->builder->failure_output, Test::More->builder->todo_output;

# chmod can be made to fail on demand; this has to be in place before Document
# is compiled. Without the switch it is plain chmod.
our $FAIL_CHMOD = 0;
BEGIN {
  no warnings 'once';
  *CORE::GLOBAL::chmod = sub {
    if ($main::FAIL_CHMOD) { $! = 1; return 0 }
    return CORE::chmod( shift, @_ );
  };
}
use MCP::Wiki::Server;

# A write keeps the page's permission bits; a page without write permission is
# refused and left as it was.

plan skip_all => 'file modes are not meaningful on MSWin32' if $^O eq 'MSWin32';

{
  package Local::FakeHistory;
  sub new { return bless {}, shift }
  sub restore_section {
    my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
    ( my $doc = $opts->{current_content} ) =~ s/^new alpha$/old alpha/m;
    return { success => 1, content => $doc, restored_from => $commit_hash };
  }
}

umask 022;

my $wiki   = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => "$wiki", git_history => Local::FakeHistory->new );

sub call_tool {
  my ( $name, $args ) = @_;
  my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
  die "tool '$name' is not registered" unless $tool;
  return $tool->code->( $tool, $args );
}

sub mode_of { return sprintf '%04o', ( stat $_[0] )[2] & 07777 }

my $TEXT = "# Top\nintro\n## Alpha\nnew alpha\n";

subtest 'update_paragraph keeps a 0600 page 0600' => sub {
  my $page = $wiki->child('private.md');
  $page->spew_utf8($TEXT);
  chmod 0600, "$page";
  my $res = call_tool( 'update_paragraph',
    { page => 'private.md', heading_path => 'Top#Alpha', content => 'edited' } );
  ok( !$res->{isError}, 'update succeeds' ) or diag $res->{content}[0]{text};
  is( $page->slurp_utf8, "# Top\nintro\n## Alpha\nedited\n", 'content written' );
  is( mode_of("$page"), '0600', 'mode unchanged' );
};

subtest 'restore_section keeps a 0600 page 0600' => sub {
  my $page = $wiki->child('private2.md');
  $page->spew_utf8($TEXT);
  chmod 0600, "$page";
  my $res = call_tool( 'restore_section',
    { page => 'private2.md', heading_path => 'Top#Alpha', commit_hash => 'abc123' } );
  ok( !$res->{isError}, 'restore succeeds' ) or diag $res->{content}[0]{text};
  is( $page->slurp_utf8, "# Top\nintro\n## Alpha\nold alpha\n", 'content written' );
  is( mode_of("$page"), '0600', 'mode unchanged' );
};

SKIP: {
  skip "root can write to a 0444 page", 3 if $> == 0;

  subtest 'update_paragraph refuses a read-only page' => sub {
    my $page = $wiki->child('ro.md');
    $page->spew_utf8($TEXT);
    chmod 0444, "$page";
    my $res = call_tool( 'update_paragraph',
      { page => 'ro.md', heading_path => 'Top#Alpha', content => 'edited' } );
    ok( $res->{isError}, 'isError' );
    like( $res->{content}[0]{text}, qr/ro\.md/, 'names the page' );
    is( $page->slurp_utf8, $TEXT, 'content unchanged' );
    is( mode_of("$page"), '0444', 'mode unchanged' );
  };

  subtest 'restore_section refuses a read-only page' => sub {
    my $page = $wiki->child('ro2.md');
    $page->spew_utf8($TEXT);
    chmod 0444, "$page";
    my $res = call_tool( 'restore_section',
      { page => 'ro2.md', heading_path => 'Top#Alpha', commit_hash => 'abc123' } );
    ok( $res->{isError}, 'isError' );
    is( $page->slurp_utf8, $TEXT, 'content unchanged' );
    is( mode_of("$page"), '0444', 'mode unchanged' );
  };
  subtest 'the refusal names a page below a non-ASCII directory as text' => sub {
    for my $name ( 'ö/ro.md', '日本/ro.md' ) {
      my $page = $wiki->child( Encode::encode( 'UTF-8', $name ) );
      $page->parent->mkpath;
      $page->spew_utf8($TEXT);
      chmod 0444, "$page";
      my $res = call_tool( 'update_paragraph',
        { page => $name, heading_path => 'Top#Alpha', content => 'edited' } );
      ok( $res->{isError}, "$name: isError" );
      my $text = $res->{content}[0]{text};
      like( $text, qr/\Q$name\E/, "$name: the page is named as characters" );
      unlike( $text, qr/\x{C3}[\x{80}-\x{BF}]|\x{E6}\x{97}/, "$name: nothing double-encoded" );
      is( $page->slurp_utf8, $TEXT, "$name: content unchanged" );
    }
  };
}

subtest 'a mode that cannot be restored names the page as text' => sub {
  for my $name ( 'ö/cm.md', '日本/cm.md' ) {
    my $page = $wiki->child( Encode::encode( 'UTF-8', $name ) );
    $page->parent->mkpath;
    $page->spew_utf8($TEXT);
    chmod 0600, "$page";
    local $FAIL_CHMOD = 1;
    my $res = call_tool( 'update_paragraph',
      { page => $name, heading_path => 'Top#Alpha', content => 'edited' } );
    ok( $res->{isError}, "$name: isError" );
    my $text = $res->{content}[0]{text};
    like( $text, qr/mode could not be restored/, "$name: says what failed" );
    like( $text, qr/\Q$name\E/, "$name: the page is named as characters" );
    unlike( $text, qr/\x{C3}[\x{80}-\x{BF}]|\x{E6}\x{97}/, "$name: nothing double-encoded" );
  }
};

done_testing;
