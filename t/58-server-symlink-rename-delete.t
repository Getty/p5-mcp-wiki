use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# rename_page and delete_page refuse a page name that is itself a symlink:
# they would move or remove the link's target and leave the link dangling.
# Reading and writing through the link keeps working, and so does a rename or
# delete of a page that merely lies in a symlinked directory.

plan skip_all => 'symlink() unavailable' unless eval { symlink( '', '' ); 1 };

my $wiki = tempdir;
$wiki->child('real')->mkpath;
$wiki->child('page.md')->spew_utf8("# Page\n\nbody\n");
$wiki->child( 'real', 'deep.md' )->spew_utf8("# Deep\n\nbody\n");
symlink 'page.md', $wiki->child('alias.md') or die "symlink: $!";
symlink 'real',    $wiki->child('dir')      or die "symlink: $!";

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );
my @events;
$server->on_change( sub { push @events, $_[0] } );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    return $tool->code->( $tool, $args );
}

my $res = call( rename_page => { from => 'alias.md', to => 'moved.md' } );
ok( $res->{isError}, 'rename of a symlink name is refused' );
like( $res->{content}[0]{text}, qr/symlink/i, 'the message says why' );
like( $res->{content}[0]{text}, qr/page\.md/, 'the message names the page it points to' );
ok( $wiki->child('page.md')->is_file && -l $wiki->child('alias.md'), 'page and link are untouched' );
ok( !$wiki->child('moved.md')->exists, 'nothing was created' );

$res = call( delete_page => { page => 'alias.md' } );
ok( $res->{isError}, 'delete of a symlink name is refused' );
like( $res->{content}[0]{text}, qr/symlink/i, 'the message says why' );
ok( $wiki->child('page.md')->is_file && -l $wiki->child('alias.md'), 'page and link are untouched' );
is( scalar @events, 0, 'no event fired' );

$res = call( rename_page => { from => 'page.md', to => 'alias.md' } );
ok( $res->{isError}, 'a symlink as target is still refused (exists)' );

$res = call( get_toc => { page => 'alias.md' } );
ok( !$res->{isError}, 'reading through the link still works' );
$res = call( update_paragraph => { page => 'alias.md', heading_path => 'Page', content => 'changed' } );
ok( !$res->{isError}, 'writing through the link still works' );
like( eval { $wiki->child('page.md')->slurp_utf8 } // '', qr/changed/, 'the target changed' );

$res = call( rename_page => { from => 'dir/deep.md', to => 'dir/deeper.md' } );
ok( !$res->{isError}, 'a page in a symlinked directory can be renamed' )
    or diag $res->{content}[0]{text};
ok( $wiki->child( 'real', 'deeper.md' )->is_file, 'it moved' );
$res = call( delete_page => { page => 'dir/deeper.md' } );
ok( !$res->{isError}, 'a page in a symlinked directory can be deleted' )
    or diag $res->{content}[0]{text};

done_testing;
