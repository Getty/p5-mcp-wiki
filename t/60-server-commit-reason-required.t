#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# With commit_reason_required every tool that writes refuses a call without a
# non-empty reason and says so in its description; reading tools are not
# affected. Without the option `reason` stays optional.

{
    package Local::FakeHistory;
    sub new { return bless {}, shift }
    sub restore_section {
        my ( $self, $page, $hp, $hash, $opts ) = @_;
        return { success => 1, content => $opts->{current_content}, restored_from => $hash };
    }
}

sub fixture {
    my (%opt) = @_;
    my $wiki = tempdir;
    $wiki->child('a.md')->spew_utf8("# A\n\nbody\n");
    $wiki->child('b.md')->spew_utf8("# B\n\nbody\n");
    my $server = MCP::Wiki::Server->new(
        wiki_root => "$wiki", git_history => Local::FakeHistory->new, %opt );
    my @events;
    $server->on_change( sub { push @events, $_[0] } );
    my $call = sub {
        my ( $name, $args ) = @_;
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        BAIL_OUT("no tool $name") unless $tool;
        return $tool->code->( $tool, $args );
    };
    return ( $wiki, $server, $call, \@events );
}

my %write = (
    create_page      => { page => 'new.md', content => "# N\n" },
    update_paragraph => { page => 'a.md', heading_path => 'A', content => 'changed' },
    rename_page      => { from => 'a.md', to => 'c.md' },
    delete_page      => { page => 'b.md' },
    restore_section  => { page => 'a.md', heading_path => 'A', commit_hash => 'abc1234' },
    write_page       => { page => 'a.md', content => "# A\n\nnew\n" },
    add_section      => { page => 'a.md', parent => 'A', heading => 'Added' },
    delete_section   => { page => 'b.md', heading_path => 'B' },
    rename_heading   => { page => 'a.md', heading_path => 'A', heading => 'Renamed' },
);

# -- required
for my $name ( sort keys %write ) {
    subtest "$name with commit_reason_required" => sub {
        my ( $wiki, $server, $call, $events ) = fixture( commit_reason_required => 1 );
        my %before = map { $_->basename => $_->slurp_utf8 } $wiki->children;

        for my $bad ( [ 'no reason' => {} ], [ 'undef reason' => { reason => undef } ],
                      [ 'empty reason' => { reason => '' } ], [ 'blank reason' => { reason => " \n\t" } ] ) {
            my $res = $call->( $name, { %{ $write{$name} }, %{ $bad->[1] } } );
            ok( $res->{isError}, "$bad->[0]: refused" );
            like( $res->{content}[0]{text}, qr/reason is required/i, "$bad->[0]: the message says why" );
        }
        is_deeply( { map { $_->basename => $_->slurp_utf8 } $wiki->children }, \%before, 'nothing changed' );
        is( scalar @$events, 0, 'no event fired' );

        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        like( $tool->description, qr/reason is required/i, 'the description says a reason is required' );

        my $res = $call->( $name, { %{ $write{$name} }, reason => 'because' } );
        ok( !$res->{isError}, 'with a reason it works' ) or diag $res->{content}[0]{text};
        is( scalar @$events, 1, 'the event fires' );
    };
}

# -- optional
for my $name ( sort keys %write ) {
    subtest "$name without the option" => sub {
        my ( $wiki, $server, $call, $events ) = fixture();
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        unlike( $tool->description, qr/reason is required/i, 'the description does not demand a reason' );
        my $res = $call->( $name, $write{$name} );
        ok( !$res->{isError}, 'works without a reason' ) or diag $res->{content}[0]{text};
    };
}

# -- reading tools, schemas
{
    my ( $wiki, $server, $call ) = fixture( commit_reason_required => 1 );
    for my $name (qw( list_pages get_toc get_paragraph get_page search_pages )) {
        my $res = $call->( $name, { page => 'a.md', heading_path => 'A', query => 'body' } );
        ok( !$res->{isError}, "$name needs no reason" ) or diag $res->{content}[0]{text};
    }
    for my $tool ( grep { $_->name =~ /^(?:rename_page|delete_page|write_page|add_section|delete_section|rename_heading)$/ } @{ $server->server->tools } ) {
        is( $tool->input_schema->{properties}{reason}{type}, 'string', $tool->name . ' takes a reason' );
        ok( !grep( { $_ eq 'reason' } @{ $tool->input_schema->{required} // [] } ),
            $tool->name . ': reason stays out of "required" (the refusal is a tool result)' );
    }
}

done_testing;
