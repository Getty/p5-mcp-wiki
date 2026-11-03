#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use MCP::Wiki::Server;

# Git::Raw is optional and not installed everywhere. restore_section of
# MCP::Wiki::Git::History hands back the complete new document in {content};
# this stand-in does the same without a repository.
{
    package Local::FakeHistory;
    sub new { return bless { calls => [] }, shift }
    sub calls { return @{ $_[0]{calls} } }

    sub restore_section {
        my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
        push @{ $self->{calls} }, [ $page, $heading_path, $commit_hash ];
        my $doc = $opts->{current_content};
        $doc =~ s/^new alpha$/old alpha/m;
        return { success => 1, content => $doc, restored_from => $commit_hash };
    }
}

my $wiki = tempdir;
my $page = $wiki->child('page.md');
$page->spew_utf8("# Intro\nintro text\n## Alpha\nnew alpha\n## Beta\nbeta text");

my $history = Local::FakeHistory->new;
my $server  = MCP::Wiki::Server->new( wiki_root => "$wiki", git_history => $history );
my ($tool)  = grep { $_->name eq 'restore_section' } @{ $server->server->tools };

my @events;
$server->on_change( sub { push @events, $_[0] } );

my $result = $tool->code->(
    $tool,
    { page => 'page.md', heading_path => 'Intro#Alpha', commit_hash => 'abc123' }
);
ok( !$result->{isError}, 'restore_section succeeds' )
    or diag( $result->{content}[0]{text} );

is( $page->slurp_utf8,
    "# Intro\nintro text\n## Alpha\nold alpha\n## Beta\nbeta text",
    'the document History returned is written as it is, not patched in once more' );

is_deeply( [ $history->calls ], [ [ 'page.md', 'Intro#Alpha', 'abc123' ] ], 'History was asked once' );
is( decode_json( $result->{content}[0]{text} )->{restored_from}, 'abc123', 'restored_from is reported' );
is_deeply( [ map { $_->{type} } @events ], ['restore'], 'one restore event fires after the write' );

done_testing;
