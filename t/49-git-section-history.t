use strict;
use warnings;
use utf8;
use Test::More;
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


# Commits made through the tools, one per step:
#   c1 creates page.md with Intro#Alpha (v1) and Intro#Beta
#   c2 creates other.md                    (another page)
#   c3 changes Intro#Beta                  (another section of the same page)
#   c4 changes Intro#Alpha to v2
#   c5 changes Intro#Alpha to v3
my %c;
sub step {
    my ( $label, $name, $args ) = @_;
    my $res = call( $name, $args );
    ok( !$res->{died} && !$res->{isError}, "$label succeeds" ) or diag( $res->{died} // $res->{content}[0]{text} );
    $c{$label} = head_hash();
}

step( c1 => create_page => { page => 'page.md', content => "# Intro\n## Alpha\nv1\n## Beta\nb1\n" } );
step( c2 => create_page => { page => 'other.md', content => "# Other\n## Alpha\nunrelated\n" } );
step( c3 => update_paragraph => { page => 'page.md', heading_path => 'Intro#Beta', content => 'b2' } );
step( c4 => update_paragraph => { page => 'page.md', heading_path => 'Intro#Alpha', content => 'v2' } );
step( c5 => update_paragraph => { page => 'page.md', heading_path => 'Intro#Alpha', content => 'v3' } );

is( scalar( () = commits() ), 5, 'five commits' ) or diag("warnings: @warnings");
is( scalar( keys %c ), 5, 'five distinct step labels' );
ok( !grep( { !defined } values %c ), 'every step produced a commit' );

my $res = call( get_section_history => { page => 'page.md', heading_path => 'Intro#Alpha' } );
ok( !$res->{died} && !$res->{isError}, 'get_section_history answers' ) or diag( $res->{died} // $res->{content}[0]{text} );
my @listed = $res->{structuredContent} ? @{ $res->{structuredContent}{commits} } : ();

is_deeply( [ map { $_->{hash} } @listed ], [ $c{c5}, $c{c4}, $c{c1} ],
    'only the commits that created or changed the section, newest first' );
is( $res->{structuredContent}{count}, 3, 'count agrees' ) if $res->{structuredContent};

for my $entry (@listed) {
    is_deeply( [ sort keys %$entry ],
        [ sort qw( hash message author email time heading line_start line_end ) ],
        'entry keys are unchanged' );
}

# Beta: created in c1, changed in c3; the Alpha commits do not concern it
$res = call( get_section_history => { page => 'page.md', heading_path => 'Intro#Beta' } );
is_deeply( [ map { $_->{hash} } @{ $res->{structuredContent}{commits} // [] } ], [ $c{c3}, $c{c1} ],
    'Beta: its own change and its creation, not the Alpha commits' );

# ---- restore on a CRLF page keeps it pure CRLF
{
    my $original = "# Doc\r\n## Alpha\r\nv1\r\n## Beta\r\nb\r\n";
    step( k1 => create_page => { page => 'crlf.md', content => $original } );
    step( k2 => update_paragraph => { page => 'crlf.md', heading_path => 'Doc#Alpha', content => 'v2' } );
    my $file = $dir->child('crlf.md');
    like( $file->slurp_raw, qr/v2\r\n/, 'the update itself keeps CRLF' );

    my $res = call( restore_section => { page => 'crlf.md', heading_path => 'Doc#Alpha', commit_hash => $c{k1} // 'missing' } );
    ok( !$res->{died} && !$res->{isError}, 'restore_section on a CRLF page succeeds' ) or diag( $res->{died} // $res->{content}[0]{text} );
    my $raw = $file->slurp_raw;
    unlike( $raw, qr/(?<!\r)\n/, 'no bare LF in the restored page' );
    unlike( $raw, qr/\r\r/, 'no doubled CR in the restored page' );
    is( $raw, $original, 'the section is back and the rest is byte-identical' );
}

done_testing;
