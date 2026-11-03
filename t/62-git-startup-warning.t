#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# A git mode that cannot be honoured (no repository around the wiki, or no
# Git::Raw) is told once, at startup. The server goes on without history and
# commits, and no write or history call warns again. Holds with and without
# Git::Raw installed.

my $dir = tempdir;

my @warnings;
my $server = do {
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    MCP::Wiki::Server->new( wiki_root => "$dir", use_git => 1 );
};

is( scalar @warnings, 1, 'one warning at startup' );
like( $warnings[0], qr/git/i, 'it names git' );
like( $warnings[0], qr/without history and commits/, 'and what that means' );
like( $warnings[0], qr/Git::Raw is required|Not a git repository/, 'and why' );
is( $server->git_history, undef, 'there is no history' );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    return $tool->code->( $tool, $args );
}

{
    @warnings = ();
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $res = call( create_page => { page => 'a.md', content => "# A\ntext\n" } );
    ok( !$res->{isError}, 'a write still works' );
    $res = call( update_paragraph => { page => 'a.md', heading_path => 'A', content => "new\n" } );
    ok( !$res->{isError}, 'and the next one' );
    $res = call( get_section_history => { page => 'a.md', heading_path => 'A' } );
    ok( $res->{isError}, 'the history tools answer that there is none' );
    like( $res->{content}[0]{text}, qr/not available/, 'in those words' );
    is_deeply( \@warnings, [], 'no write or history call warns again' );
}

# No git mode, no warning
{
    my @quiet;
    local $SIG{__WARN__} = sub { push @quiet, @_ };
    MCP::Wiki::Server->new( wiki_root => "$dir" );
    is_deeply( \@quiet, [], 'without use_git there is nothing to warn about' );
}

done_testing;
