#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# A directory named like a page (dir.md) is no page: every tool refuses it with
# an error result, list_pages does not offer it, and neither the directory nor
# what is inside it is touched.

my $wiki = tempdir( CLEANUP => 1 );
my $dir  = $wiki->child('dir.md');

# Each call starts from the same tree, whatever an earlier call did to it.
sub reset_fixture {
    $_->is_dir ? $_->remove_tree : $_->remove for $wiki->children;
    $dir->mkpath;
    $dir->child('inner.txt')->spew_utf8("keep me\n");
    $wiki->child('real.md')->spew_utf8("# T\nbody\n");
}
reset_fixture();

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
    return $res;
}

sub snapshot {
    my @s;
    my $iter = $wiki->iterator( { recurse => 1 } );
    while ( my $p = $iter->() ) { push @s, $p->relative($wiki) . '=' . ( $p->is_file ? $p->slurp_raw : '<dir>' ) }
    return join "\n", sort @s;
}

my $before = snapshot();

my %calls = (
    get_toc          => { page => 'dir.md' },
    get_paragraph    => { page => 'dir.md', heading_path => 'T' },
    update_paragraph => { page => 'dir.md', heading_path => 'T', content => 'x' },
    rename_page      => { from => 'dir.md', to => 'moved.md' },
    delete_page      => { page => 'dir.md' },
    create_page      => { page => 'dir.md', content => "# T\n" },
);

for my $name ( sort keys %calls ) {
    reset_fixture();
    my $res = call( $name, $calls{$name} );
    ok( !$res->{died}, "$name does not die" ) or diag( $res->{died} );
    ok( $res->{isError}, "$name on a directory answers isError" );
    ok( $dir->is_dir, "$name: dir.md is still a directory" );
    ok( !$wiki->child('moved.md')->exists, "$name: nothing was moved" );
    is( snapshot(), $before, "$name: nothing changed on disk" );
}

reset_fixture();
my $res = call('list_pages');
ok( !$res->{isError}, 'list_pages succeeds' );
is_deeply( $res->{structuredContent}{pages}, ['real.md'], 'the directory is not listed' );

done_testing;
