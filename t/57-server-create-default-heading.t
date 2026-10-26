use strict;
use warnings;
use utf8;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# create_page without content starts the page with a heading made of the file
# name without ".md", not of the whole path.

my $wiki   = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );

sub create {
    my ($page) = @_;
    my ($tool) = grep { $_->name eq 'create_page' } @{ $server->server->tools };
    BAIL_OUT('no create_page tool') unless $tool;
    my $res = $tool->code->( $tool, { page => $page } );
    ok( !$res->{isError}, "create $page" ) or diag $res->{content}[0]{text};
}

create('c.md');
is( $wiki->child('c.md')->slurp_utf8, "# c\n", 'top-level page: heading is the name' );

create('a/b/d.md');
is( $wiki->child('a/b/d.md')->slurp_utf8, "# d\n", 'nested page: no directories in the heading' );

create('Notes.MD');
is( $wiki->child('Notes.MD')->slurp_utf8, "# Notes\n", 'the extension is cut in any case' );

create('sub/./Über uns.md');
is( $wiki->child('sub/Über uns.md')->slurp_utf8, "# Über uns\n", 'non-ASCII name stays text' );

my ($tool) = grep { $_->name eq 'create_page' } @{ $server->server->tools };
unlike( $tool->description, qr/<page>/, 'description no longer promises the page name as heading' );
like( $tool->description, qr/file name/i, 'description says the heading is the file name' );

done_testing;
