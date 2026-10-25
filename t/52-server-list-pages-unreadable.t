use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# An unreadable directory does not make list_pages fail: it is skipped with a
# warning and every other page is listed.

my $wiki = tempdir( CLEANUP => 1 );
my $page = "# T\nbody\n";

sub put {
    my ( $name, $content ) = @_;
    my $path = Path::Tiny::path("$wiki/$name");
    $path->parent->mkpath;
    $path->spew_utf8($content);
    return $path;
}

put( 'a.md', $page );

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
    return $res;
}

sub text_of { return $_[0]{died} // $_[0]{content}[0]{text} }

sub listed {
    my $warnings = shift;
    local $SIG{__WARN__} = sub { push @{$warnings}, @_ } if $warnings;
    my $res = call('list_pages');
    ok( !$res->{died} && !$res->{isError}, 'list_pages succeeds' ) or diag( text_of($res) );
    return [] if $res->{died} || $res->{isError};
    # structuredContent is the data itself; the text copy is a JSON string whose
    # byte/character status is not what this test is about.
    return $res->{structuredContent}{pages};
}

# ---- #20: unreadable directory
SKIP: {
    skip 'permission checks are meaningless as root', 4 if $> == 0;
    skip 'no POSIX permissions here', 4 if $^O eq 'MSWin32';

    put( 'sub/p.md', $page );
    my $locked = $wiki->child('locked');
    $locked->mkpath;
    $locked->child('hidden.md')->spew_utf8($page);
    chmod 0000, "$locked";
    skip 'directory is still readable', 4 if opendir( my $dh, "$locked" );

    my @warnings;
    my $pages = listed( \@warnings );
    chmod 0700, "$locked";    # before anything else can fail: tempdir cleanup needs it

    is_deeply( $pages, [ sort 'a.md', 'sub/p.md' ], 'the unreadable directory is skipped, the other pages are listed' );
    ok( scalar @warnings, 'skipping it is reported with a warning' );
    ok( -e $locked->child('hidden.md'), 'nothing in the directory was touched' );
}

done_testing;
