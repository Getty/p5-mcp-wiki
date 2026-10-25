use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# create_page and rename_page check for the target and then act. A page that
# appears in between must not be overwritten. The server has no race hook, so
# the window is opened deterministically: both tools call mkpath on the
# target's parent directory after the existence check and before the write, and
# this wraps Path::Tiny::mkpath to drop the racing file in right there. The
# hook has to fire, otherwise the test says so instead of passing vacuously.

my $wiki = tempdir( CLEANUP => 1 );
my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
    return $res;
}

# Runs $code; while it runs, the first mkpath on $parent also creates $racer.
sub with_race {
    my ( $parent, $racer, $content, $code ) = @_;
    my $fired = 0;
    my $orig  = \&Path::Tiny::mkpath;
    no warnings 'redefine';
    local *Path::Tiny::mkpath = sub {
        my @ret = $orig->(@_);
        if ( !$fired && "$_[0]" eq "$parent" ) {
            $fired = 1;
            $racer->spew_utf8($content);
        }
        return wantarray ? @ret : $ret[0];
    };
    my $res = $code->();
    ok( $fired, 'the racing file appeared between check and write' );
    return $res;
}

# ---- the existing-target guards (no race)
$wiki->child('exists.md')->spew_utf8("# E\nold\n");
$wiki->child('src.md')->spew_utf8("# S\nsource\n");
{
    my $res = call( create_page => { page => 'exists.md', content => "# E\nnew\n" } );
    ok( $res->{isError}, 'create_page on an existing page is an error' );
    like( $res->{content}[0]{text}, qr/already exists/, 'error text unchanged' );
    is( $wiki->child('exists.md')->slurp_utf8, "# E\nold\n", 'page untouched' );

    $res = call( rename_page => { from => 'src.md', to => 'exists.md' } );
    ok( $res->{isError}, 'rename onto an existing target is an error' );
    like( $res->{content}[0]{text}, qr/already exists/, 'error text unchanged' );
    is( $wiki->child('exists.md')->slurp_utf8, "# E\nold\n", 'target untouched' );
    is( $wiki->child('src.md')->slurp_utf8, "# S\nsource\n", 'source untouched' );
}

# ---- create_page loses the race
{
    my $target = $wiki->child('race.md');
    my $res = with_race( $wiki, $target, "# Racer\nfirst\n",
        sub { call( create_page => { page => 'race.md', content => "# Mine\nsecond\n" } ) } );
    ok( !$res->{died}, 'create_page does not die' ) or diag( $res->{died} );
    ok( $res->{isError}, 'create_page reports an error when the page appeared meanwhile' );
    is( $target->slurp_utf8, "# Racer\nfirst\n", 'the page that won the race is not overwritten' );
}

# ---- rename_page loses the race
{
    $wiki->child('mv.md')->spew_utf8("# M\nmoving\n");
    my $target = $wiki->child('mvtarget.md');
    my $res = with_race( $wiki, $target, "# Racer\nfirst\n",
        sub { call( rename_page => { from => 'mv.md', to => 'mvtarget.md' } ) } );
    ok( !$res->{died}, 'rename_page does not die' ) or diag( $res->{died} );
    ok( $res->{isError}, 'rename_page reports an error when the target appeared meanwhile' );
    is( $target->slurp_utf8, "# Racer\nfirst\n", 'the target that won the race is not replaced' );
    is( eval { $wiki->child('mv.md')->slurp_utf8 }, "# M\nmoving\n", 'the source is still there' );
}

done_testing;
