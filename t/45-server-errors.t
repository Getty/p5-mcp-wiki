use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# Tool errors are written for a model: they name the page the way the client
# wrote it (relative to the root), never the wiki root or any other absolute
# path, carry no Perl "at FILE line N." trailer, and an unknown heading_path
# says which paths do exist.

my $wiki = tempdir( CLEANUP => 1 );
$wiki->child('page.md')->spew_utf8("# Intro\nintro\n## Alpha\na\n## Beta\nb\n");
$wiki->child('other.md')->spew_utf8("# O\n");
$wiki->child('blocker')->spew_utf8("i am a file, not a directory\n");
$wiki->child('big.md')->spew_utf8( "# H\n" . join( '', map { sprintf "## S%02d\nx\n", $_ } 1 .. 60 ) );

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );
my @roots  = ( "$wiki", $wiki->realpath . '' );

sub error_of {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return ( undef, "DIED: $@" );
    return ( $res->{isError} ? 1 : 0, $res->{content}[0]{text} // '' );
}

sub clean_ok {
    my ( $label, $name, $args, @hints ) = @_;
    my ( $is_error, $text ) = error_of( $name, $args );
    ok( $is_error, "$label: isError" ) or diag($text);
    for my $root (@roots) {
        ok( index( $text, $root ) < 0, "$label: no absolute wiki path" ) or diag($text);
    }
    unlike( $text, qr/ at \S+ line \d+/, "$label: no 'at FILE line N' trailer" );
    unlike( $text, qr{(?<![\w.])/(?:tmp|home|var|usr)/}, "$label: no absolute path of any kind" );
    like( $text, $_, "$label: names the problem" ) for @hints;
    return $text;
}

clean_ok( 'get_toc, missing page',          get_toc          => { page => 'nope.md' }, qr/nope\.md/ );
clean_ok( 'get_paragraph, missing page',    get_paragraph    => { page => 'nope.md', heading_path => 'X' }, qr/nope\.md/ );
clean_ok( 'update_paragraph, missing page', update_paragraph => { page => 'nope.md', heading_path => 'X', content => 'c' }, qr/nope\.md/ );
clean_ok( 'delete_page, missing page',      delete_page      => { page => 'nope.md' }, qr/nope\.md/ );
clean_ok( 'rename_page, missing source',    rename_page      => { from => 'nope.md', to => 'new.md' }, qr/nope\.md/ );

# unknown heading: the message lists what exists
for my $case (
    [ get_paragraph    => { page => 'page.md', heading_path => 'Alpha' } ],
    [ update_paragraph => { page => 'page.md', heading_path => 'Alpha', content => 'c' } ],
  )
{
    my ( $name, $args ) = @$case;
    clean_ok( "$name, unknown heading", $name, $args, qr/Alpha/, qr/Intro#Alpha/, qr/Intro#Beta/ );
}
is( $wiki->child('page.md')->slurp_utf8, "# Intro\nintro\n## Alpha\na\n## Beta\nb\n", 'the failed update left the page alone' );

# the list is capped at 50
for my $name (qw( get_paragraph update_paragraph )) {
    my $args = { page => 'big.md', heading_path => 'Nope', ( $name eq 'update_paragraph' ? ( content => 'c' ) : () ) };
    my $text = clean_ok( "$name, 61 headings", $name, $args );
    like( $text, qr/H#S01\b/, "$name: lists the first paths" );
    like( $text, qr/H#S49\b/, "$name: lists the 50th path" );
    unlike( $text, qr/H#S60\b/, "$name: does not list the paths beyond the cap" );
    like( $text, qr/\.\.\. and 11 more/, "$name: says how many more there are" );
}

# create on an existing page, and a failing mkpath
clean_ok( 'create_page, existing page', create_page => { page => 'other.md', content => 'x' }, qr/other\.md/ );
is( $wiki->child('other.md')->slurp_utf8, "# O\n", 'the existing page is untouched' );
clean_ok( 'create_page, parent is a file', create_page => { page => 'blocker/x.md', content => 'x' }, qr/blocker/ );
is( $wiki->child('blocker')->slurp_utf8, "i am a file, not a directory\n", 'the blocking file is untouched' );

# rename onto an existing target
clean_ok( 'rename_page, target exists', rename_page => { from => 'other.md', to => 'page.md' }, qr/page\.md/ );

done_testing;
