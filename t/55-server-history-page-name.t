#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# get_section_history and restore_section hand History the canonical page name
# (relative to the wiki root, as list_pages shows it), whatever spelling the
# client used: History looks the page up in each commit's tree by that string.
# A stand-in records what it receives; no Git::Raw involved.

{
    package Local::RecordingHistory;
    sub new { return bless { seen => [] }, shift }
    sub seen { return @{ $_[0]{seen} } }
    sub get_section_commits {
        my ( $self, $page ) = @_;
        push @{ $self->{seen} }, [ commits => $page ];
        return ();
    }
    sub restore_section {
        my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
        push @{ $self->{seen} }, [ restore => $page ];
        return { success => 1, content => $opts->{current_content}, restored_from => $commit_hash };
    }
}

my $wiki = tempdir( CLEANUP => 1 );
$wiki->child('sub')->mkpath;
$wiki->child( 'sub', 'a.md' )->spew_utf8("# T\n## S\nx\n");
my $have_symlink = eval { symlink( 'sub/a.md', "$wiki/alias.md" ) };

my $history = Local::RecordingHistory->new;
my $server  = MCP::Wiki::Server->new( wiki_root => "$wiki", git_history => $history );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
    return $res;
}

my @spellings = ( 'sub/a.md', './sub/a.md', 'sub/../sub/a.md', 'sub//a.md' );
push @spellings, 'alias.md' if $have_symlink;

for my $spelling (@spellings) {
    my $before = () = $history->seen;
    my $res = call( get_section_history => { page => $spelling, heading_path => 'T#S' } );
    ok( !$res->{died} && !$res->{isError}, "get_section_history accepts $spelling" ) or diag( $res->{died} // $res->{content}[0]{text} );
    my @seen = ( $history->seen )[ $before .. $#{ [ $history->seen ] } ];
    is_deeply( \@seen, [ [ commits => 'sub/a.md' ] ], "get_section_history: History gets sub/a.md for $spelling" );

    $before = () = $history->seen;
    $res = call( restore_section => { page => $spelling, heading_path => 'T#S', commit_hash => 'abc123' } );
    ok( !$res->{died} && !$res->{isError}, "restore_section accepts $spelling" ) or diag( $res->{died} // $res->{content}[0]{text} );
    @seen = ( $history->seen )[ $before .. $#{ [ $history->seen ] } ];
    is_deeply( \@seen, [ [ restore => 'sub/a.md' ] ], "restore_section: History gets sub/a.md for $spelling" );
}

is( $wiki->child( 'sub', 'a.md' )->slurp_utf8, "# T\n## S\nx\n", 'the page itself is untouched' );

done_testing;
