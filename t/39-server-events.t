use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# on_change events name the page the way list_pages does (canonical, relative
# to the wiki root), whatever spelling the client used, and every handler gets
# an event of its own.

my $wiki = tempdir;
$wiki->child($_)->mkpath for qw( sub x );

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );
my @events;
$server->on_change( sub { push @events, $_[0] } );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or fail("$name died: $@");
    ok( $res && !$res->{isError}, "$name succeeds" ) or diag( $res ? $res->{content}[0]{text} : '' );
    return $res;
}

sub last_event { return pop @events }

# ---- create
call( create_page => { page => 'sub/./a.md', content => "# H\nbody\n" } );
is_deeply( last_event(), { type => 'create', page => 'sub/a.md', reason => undef },
    'create: "sub/./a.md" is reported as sub/a.md' );
ok( $wiki->child('sub/a.md')->is_file, 'the page is where the canonical name says' );

call( create_page => { page => 'x/../sub/b.md', content => "# H\nbody\n" } );
is_deeply( last_event(), { type => 'create', page => 'sub/b.md', reason => undef },
    'create: "x/../sub/b.md" is reported as sub/b.md' );

# ---- update through an in-root symlink
$wiki->child('page.md')->spew_utf8("# H\nbody\n");
SKIP: {
    skip 'symlink() unavailable', 3 unless eval { symlink( 'page.md', "$wiki/alias.md" ) };

    call( update_paragraph => { page => 'alias.md', heading_path => 'H', content => 'changed', reason => 'why' } );
    is_deeply( last_event(),
        { type => 'update', page => 'page.md', heading_path => 'H', reason => 'why' },
        'update: the alias is reported as the page it resolves to' );
    like( $wiki->child('page.md')->slurp_utf8, qr/^changed$/m, 'page.md is the file that changed' );
    unlink "$wiki/alias.md";
}

call( update_paragraph => { page => './sub/../sub/./a.md', heading_path => 'H', content => 'again' } );
is_deeply( last_event(), { type => 'update', page => 'sub/a.md', heading_path => 'H', reason => undef },
    'update: "./sub/../sub/./a.md" is reported as sub/a.md' );

# ---- rename: from/to, no page
call( rename_page => { from => 'sub/./a.md', to => 'x/../sub/./c.md' } );
is_deeply( last_event(), { type => 'rename', from => 'sub/a.md', to => 'sub/c.md' },
    'rename: from and to are canonical, there is no page key' );
ok( $wiki->child('sub/c.md')->is_file && !$wiki->child('sub/a.md')->exists, 'the file moved' );

# ---- delete
call( delete_page => { page => './sub/../sub/c.md' } );
is_deeply( last_event(), { type => 'delete', page => 'sub/c.md' },
    'delete: "./sub/../sub/c.md" is reported as sub/c.md' );
ok( !$wiki->child('sub/c.md')->exists, 'the page is gone' );

# ---- handlers do not share one event
{
    my $s2 = MCP::Wiki::Server->new( wiki_root => "$wiki" );
    my ( $first, $second );
    $s2->on_change( sub { $first = $_[0]; $_[0]{page} = 'tampered.md'; $_[0]{extra} = 1; } );
    $s2->on_change( sub { $second = $_[0] } );

    my ($tool) = grep { $_->name eq 'update_paragraph' } @{ $s2->server->tools };
    my $res = $tool->code->( $tool, { page => 'page.md', heading_path => 'H', content => 'third' } );
    ok( !$res->{isError}, 'update for the handler test succeeds' );

    ok( $second, 'the second handler ran' );
    is_deeply( $second, { type => 'update', page => 'page.md', heading_path => 'H', reason => undef },
        'the second handler sees the event untouched by the first' );
    isnt( $first, $second, 'the handlers got different hashrefs' );
}

done_testing;
