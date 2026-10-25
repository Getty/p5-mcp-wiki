use strict;
use warnings;
use utf8;
use Test::More;

# test names contain non-ASCII characters
binmode $_, ':encoding(UTF-8)' for map { Test::More->builder->$_ } qw( output failure_output todo_output );
use Encode qw( encode_utf8 );
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# list_pages hands out exactly the names the other tools accept: directory
# entries are decoded from UTF-8 (so the names are character strings, like the
# ones a client sends back) and names that are no valid UTF-8 are skipped.
# (An unreadable directory is t/52.)

my $wiki = tempdir( CLEANUP => 1 );
my $page = "# T\nbody\n";

# Names on disk are bytes; the test says explicitly which ones.
sub put {
    my ( $name, $content ) = @_;
    my $path = Path::Tiny::path( "$wiki/" . ( $name =~ /[^\x00-\x7f]/ && utf8::is_utf8($name) ? encode_utf8($name) : $name ) );
    $path->parent->mkpath;
    $path->spew_utf8($content);
    return $path;
}

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

# ---- #16: non-ASCII names
put( 'a.md',       $page );
put( 'über.md',    $page );
put( '日本/x.md', $page );

is_deeply( listed(), [ sort 'a.md', 'über.md', '日本/x.md' ],
    'non-ASCII names are listed as character strings, ASCII unchanged' );

for my $name ( @{ listed() } ) {
    my $res = call( get_toc => { page => $name } );
    ok( !$res->{died} && !$res->{isError}, "get_toc accepts the listed name $name" ) or diag( text_of($res) );
    $res = call( get_paragraph => { page => $name, heading_path => 'T' } );
    ok( !$res->{died} && !$res->{isError}, "get_paragraph accepts the listed name $name" ) or diag( text_of($res) );
}

for my $name ( 'über.md', '日本/x.md' ) {
    my $res = call( delete_page => { page => $name } );
    ok( !$res->{died} && !$res->{isError}, "delete_page accepts the listed name $name" ) or diag( text_of($res) );
    ok( !-e "$wiki/" . encode_utf8($name), "$name is gone from disk" );
}
is_deeply( listed(), ['a.md'], 'only the ASCII page is left' );

# ---- #16: a name that is not valid UTF-8
put( 'über.md', $page );
SKIP: {
    my $bad = Path::Tiny::path("$wiki/\xE9.md");
    my $ok  = eval { $bad->spew_raw($page); 1 } && -e "$wiki/\xE9.md";
    skip 'filesystem refuses a non-UTF-8 file name', 2 unless $ok;

    my @warnings;
    my $pages = listed( \@warnings );
    is_deeply( $pages, [ sort 'a.md', 'über.md' ], 'the non-UTF-8 name is not listed, the others are' );
    ok( scalar @warnings, 'skipping it is reported with a warning' );
    unlink "$wiki/\xE9.md";
}

done_testing;
