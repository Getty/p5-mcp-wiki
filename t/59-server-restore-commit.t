#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# With use_git a restore is committed like every other write: the reason is the
# commit message, else "Restore <heading_path> from <short hash>". Without
# use_git nothing is committed. A stand-in records the calls; no Git::Raw.

{
    package Local::CommitRecorder;
    sub new { return bless { commits => [] }, shift }
    sub commits { return @{ $_[0]{commits} } }
    sub restore_section {
        my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
        return { success => 1, content => $opts->{current_content}, restored_from => $commit_hash };
    }
    sub auto_commit {
        my ( $self, $paths, $message, %opts ) = @_;
        push @{ $self->{commits} }, { paths => $paths, message => $message, %opts };
        return { success => 1 };
    }
}

sub restore {
    my ( $use_git, %extra ) = @_;
    my $wiki = tempdir;
    $wiki->child('sub')->mkpath;
    $wiki->child( 'sub', 'p.md' )->spew_utf8("# Intro\n## Alpha\ntext\n");
    my $history = Local::CommitRecorder->new;
    my $server  = MCP::Wiki::Server->new( wiki_root => "$wiki", use_git => $use_git, git_history => $history );
    my ($tool)  = grep { $_->name eq 'restore_section' } @{ $server->server->tools };
    my $res = $tool->code->( $tool, {
        page => 'sub/./p.md', heading_path => 'Intro#Alpha',
        commit_hash => '0123456789abcdef0123456789abcdef01234567', %extra,
    } );
    ok( !$res->{isError}, 'restore succeeds' ) or diag $res->{content}[0]{text};
    return ( $history, $tool );
}

my ($h) = restore( 1, reason => 'Alpha was better before' );
my @c = $h->commits;
is( scalar @c, 1, 'one commit for the restore' );
is_deeply( $c[0]{paths}, ['sub/p.md'], 'it stages the canonical page name' ) if @c;
is( $c[0]{message} // '', 'Restore Intro#Alpha from 0123456', 'the generated message names section and short hash' );
is( $c[0]{reason} // '', 'Alpha was better before', 'the reason goes along; History makes it the message' );

($h) = restore(1);
@c = $h->commits;
is( $c[0]{message} // '', 'Restore Intro#Alpha from 0123456', 'without a reason the generated message stands' );
ok( !exists $c[0]{reason}, 'no reason is passed on' ) if @c;

($h) = restore(0);
is( scalar( () = $h->commits ), 0, 'without use_git nothing is committed' );

my ( undef, $tool ) = restore( 0, reason => 'x' );
like( $tool->input_schema->{properties}{reason}{description}, qr/commit message/i,
    'restore_section reason is described as the commit message' );
like( $tool->description, qr/commit/i, 'the tool description says the restore is committed' );

done_testing;
