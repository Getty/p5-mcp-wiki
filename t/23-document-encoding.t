use strict;
use warnings;
use utf8;
use Test::More;
use Path::Tiny qw( tempdir );
use Encode ();
use MCP::Wiki::Server;

# Reads decode leniently, so a page that is not valid UTF-8 can be read. Writing
# it back would replace every non-ASCII byte with U+FFFD: writes to such a page
# are refused and the file stays byte-identical.

{
  # restore_section of MCP::Wiki::Git::History returns the whole new document;
  # this stand-in does the same from what the server hands over.
  package Local::FakeHistory;
  sub new { return bless {}, shift }
  sub restore_section {
    my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
    ( my $doc = $opts->{current_content} ) =~ s/^new alpha$/old alpha/m;
    return { success => 1, content => $doc, restored_from => $commit_hash };
  }
}

my $wiki   = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => "$wiki", git_history => Local::FakeHistory->new );
my @events;
$server->on_change( sub { push @events, $_[0] } );

sub call_tool {
  my ( $name, $args ) = @_;
  my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
  die "tool '$name' is not registered" unless $tool;
  return $tool->code->( $tool, $args );
}

# ASCII headings, Latin-1 bytes in the bodies and in one heading
my $LATIN1 = "# Top\ncr\xE8me\n## Other\nna\xEFve\n## Alpha\nnew alpha\n# Caf\xE9\nx\n";
my $latin1 = $wiki->child('latin1.md');

sub fresh_latin1 { $latin1->spew_raw($LATIN1) }

subtest 'update_paragraph refuses a page that is not valid UTF-8' => sub {
  fresh_latin1();
  my $res = call_tool( 'update_paragraph',
    { page => 'latin1.md', heading_path => 'Top#Other', content => 'changed' } );
  ok( $res->{isError}, 'isError' );
  like( $res->{content}[0]{text}, qr/UTF-8/i, 'the message says why' );
  like( $res->{content}[0]{text}, qr/latin1\.md/, 'and names the page' );
  is( $latin1->slurp_raw, $LATIN1, 'file is byte-identical' );
};

subtest 'restore_section refuses a page that is not valid UTF-8' => sub {
  fresh_latin1();
  @events = ();
  my $res = call_tool( 'restore_section',
    { page => 'latin1.md', heading_path => 'Top#Alpha', commit_hash => 'abc123' } );
  ok( $res->{isError}, 'isError' );
  like( $res->{content}[0]{text}, qr/UTF-8/i, 'the message says why' );
  is( $latin1->slurp_raw, $LATIN1, 'file is byte-identical' );
  is( scalar @events, 0, 'no restore event fires' );
};

subtest 'reads of the same page keep working' => sub {
  fresh_latin1();
  my $toc = call_tool( 'get_toc', { page => 'latin1.md' } );
  ok( !$toc->{isError}, 'get_toc answers' );
  my $para = call_tool( 'get_paragraph', { page => 'latin1.md', heading_path => 'Top#Other' } );
  ok( !$para->{isError}, 'get_paragraph answers' );
  like( $para->{content}[0]{text}, qr/na/, 'with the section body' );
  is( $latin1->slurp_raw, $LATIN1, 'reading changes nothing' );
};

subtest 'a valid UTF-8 page still round-trips and edits' => sub {
  my $text = "# Tïtle\nüber\n## 日本語\n本文 😀\n## Last\nend\n";
  my $page = $wiki->child('utf8.md');
  $page->spew_raw( Encode::encode( 'UTF-8', $text ) );

  my $got = call_tool( 'get_paragraph', { page => 'utf8.md', heading_path => 'Tïtle#日本語' } );
  ok( !$got->{isError}, 'get_paragraph answers' );
  my $body = $got->{structuredContent}{content};
  is( $body, '本文 😀', 'body with CJK and emoji' );

  my $res = call_tool( 'update_paragraph',
    { page => 'utf8.md', heading_path => 'Tïtle#日本語', content => $body } );
  ok( !$res->{isError}, 'update_paragraph with the unchanged body succeeds' );
  is( $page->slurp_raw, Encode::encode( 'UTF-8', $text ), 'bytes identical after get -> update' );

  $res = call_tool( 'update_paragraph',
    { page => 'utf8.md', heading_path => 'Tïtle#日本語', content => 'neu ü 😀' } );
  ok( !$res->{isError}, 'a real edit succeeds' );
  is( $page->slurp_raw,
    Encode::encode( 'UTF-8', "# Tïtle\nüber\n## 日本語\nneu ü 😀\n## Last\nend\n" ),
    'only the target section changed' );
};

done_testing;
