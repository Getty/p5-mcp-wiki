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

use Encode qw( decode FB_CROAK );

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


sub head_message {
    my @c = commits();
    my $m = @c ? decode( 'UTF-8', $c[-1]->message ) : '';
    $m =~ s/\s+\z//;
    return $m;
}

sub ok_call {
    my ( $name, $args ) = @_;
    my $res = call( $name, $args );
    ok( !$res->{died} && !$res->{isError}, "$name succeeds" ) or diag( $res->{died} // $res->{content}[0]{text} );
}


sub ok_call_ {
    my ( $name, $args ) = @_;
    my $res = call( $name, $args );
    ok( !$res->{died} && !$res->{isError}, "$name succeeds" ) or diag( $res->{died} // $res->{content}[0]{text} );
}

for my $case ( [ 'plain', 'x.md', 'y.md' ], [ 'non-ASCII', 'sub/älter.md', 'sub/neu-日本.md' ] ) {
    my ( $label, $from, $to ) = @$case;
    ok_call_( create_page => { page => $from, content => "# T\nbody\n" } );
    my $before = scalar( () = commits() );
    ok_call_( rename_page => { from => $from, to => $to } );
    is( scalar( () = commits() ), $before + 1, "$label: the rename is committed" );
    my $m = head_message();
    like( $m, qr/\Q$from\E/, "$label: the generated message names the old page" );
    like( $m, qr/\Q$to\E/,   "$label: the generated message names the new page" );
}

# (rename_page takes no reason and its event carries none, so there is no
# with-reason case; the reason-wins rule is t/51's.)

done_testing;
