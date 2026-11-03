#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;

# test names contain non-ASCII characters
binmode $_, ':encoding(UTF-8)' for map { Test::More->builder->$_ } qw( output failure_output todo_output );
use Path::Tiny qw( tempdir );

# Hermetic: no user git config, no global identity. libgit2 reads its config
# locations when Git::Raw loads, so the environment is set before that.
my $home;
BEGIN {
    $home = tempdir;
    $ENV{HOME}                = "$home";
    $ENV{XDG_CONFIG_HOME}     = "$home";
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    delete @ENV{qw( GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR )};
}

# MCP::Server (Mojolicious) must be loaded before Git::Raw: the other way round
# the process segfaults with this Git::Raw build. The server itself loads
# Git::Raw lazily, i.e. in the safe order.
use MCP::Wiki::Server;

BEGIN {
    plan skip_all => 'Git::Raw not installed (opt-in test against the real API)'
        unless eval { require Git::Raw; 1 };
}

use Encode qw( decode encode FB_CROAK );

my $dir  = tempdir;
my $repo = Git::Raw::Repository->init( "$dir", 0 );

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

my $server = MCP::Wiki::Server->new( wiki_root => "$dir", use_git => 1 );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
    return $res;
}

# structuredContent is the data itself; the text copy is a character string
# that decode_json would choke on for non-ASCII content.
sub data_of { return $_[0]{structuredContent} }

# Commits reachable from HEAD, oldest first.
sub commits {
    my $head = eval { $repo->head };
    unless ($head) {
        my $err = $@;
        # an unborn branch has no commits; anything else is a real failure
        return if ref $err eq 'Git::Raw::Error' && $err->code == Git::Raw::Error->EUNBORNBRANCH;
        die $err;
    }
    my $walker = Git::Raw::Walker->create($repo);
    $walker->sorting( ['time', 'reverse'] ) if $walker->can('sorting');
    $walker->push( $head->target );
    my @all;
    while ( my $c = $walker->next ) { push @all, $c }
    # order by ancestry, independent of timestamps
    my %by = map { $_->id => $_ } @all;
    my ($tip) = grep { my $c = $_; !grep { ( $_->parents )[0] && ( $_->parents )[0]->id eq $c->id } @all } @all;
    my @chain;
    while ($tip) { unshift @chain, $tip; $tip = ( $tip->parents )[0] }
    return @chain;
}

sub blob_text_at {
    my ( $commit, $page ) = @_;
    my $entry = $commit->tree->entry_bypath($page) or return;
    return decode( 'UTF-8', $entry->object->content, FB_CROAK );
}

sub head_hash { my @c = commits(); return @c ? $c[-1]->id : undef }


# Clean means: the index tree is HEAD's tree, and the work tree holds exactly
# the pages HEAD's tree holds, byte for byte.
sub head_tree { my @c = commits(); return @c ? $c[-1]->tree : undef }

sub in_tree {
    my ( $tree, $path ) = @_;
    my $entry = $tree->entry_bypath( encode( 'UTF-8', $path ) );
    return $entry ? 1 : 0;
}

sub is_clean {
    my ($label) = @_;
    my $tree  = head_tree() or return fail("$label: no HEAD");
    my $index = $repo->index;
    $index->read;
    is( $index->write_tree->id, $tree->id, "$label: the index matches HEAD" );

    my $iter = $dir->iterator( { recurse => 1 } );
    while ( my $p = $iter->() ) {
        next if $p->relative($dir) =~ m{^\.git(/|\z)};
        next unless $p->is_file;
        my $rel = decode( 'UTF-8', $p->relative($dir)->stringify );
        ok( in_tree( $tree, $rel ), "$label: work tree file $rel is in HEAD" );
        my $entry = $tree->entry_bypath( encode( 'UTF-8', $rel ) );
        is( $entry ? $entry->object->content : undef, $p->slurp_raw, "$label: $rel is committed as it is on disk" );
    }
}

sub ok_call {
    my ( $name, $args ) = @_;
    my $res = call( $name, $args );
    ok( !$res->{died} && !$res->{isError}, "$name succeeds" ) or diag( $res->{died} // $res->{content}[0]{text} );
    return $res;
}

for my $case (
    [ 'plain',     'a.md',           'b.md',           'b.md' ],
    # The deleted page is another one: a page below a non-ASCII directory
    # cannot be resolved yet (delete_page answers "Page not found"), which is
    # not what this test is about.
    [ 'non-ASCII', 'sub/älter.md',  'sub/日本/neu.md', 'sub/ünï.md' ],
  )
{
    my ( $label, $from, $to, $gone ) = @$case;

    ok_call( create_page => { page => $from, content => "# T\nbody of $label\n" } );
    my $before = scalar( () = commits() );
    my @events;
    $server->on_change( sub { push @events, $_[0] } );

    ok_call( rename_page => { from => $from, to => $to } );
    is( scalar( () = commits() ), $before + 1, "$label rename: one new commit" ) or diag("warnings: @warnings");
    if ( my $tree = head_tree() ) {
        ok( in_tree( $tree, $to ),    "$label rename: HEAD has the new name" );
        ok( !in_tree( $tree, $from ), "$label rename: HEAD no longer has the old name" );
    }
    is_clean("$label rename");
    is_deeply( [ sort keys %{ $events[-1] } ], [qw( from to type )], "$label rename: event keys unchanged" );

    if ( $gone ne $to ) {
        ok_call( create_page => { page => $gone, content => "# G\n" } );
        $before++;
    }
    ok_call( delete_page => { page => $gone } );
    is( scalar( () = commits() ), $before + 2, "$label delete: one more commit" );
    if ( my $tree = head_tree() ) {
        ok( !in_tree( $tree, $gone ), "$label delete: HEAD no longer has the page" );
    }
    is_clean("$label delete");
    is_deeply( [ sort keys %{ $events[-1] } ], [qw( page type )], "$label delete: event keys unchanged" );
}

done_testing;
