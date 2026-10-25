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
    my $head = eval { $repo->head } or return;
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

# ---- create + two updates on the same section
my $page = $dir->child('page.md');
my @disk;

my $res = call( create_page => { page => 'page.md', content => "# Doc\n## Sec\nbody zero\n## Other\nother stays\n" } );
ok( !$res->{died} && !$res->{isError}, 'create_page succeeds' ) or diag( $res->{died} // $res->{content}[0]{text} );
push @disk, $page->slurp_utf8;

my @hash_after = ( head_hash() );
for my $n (qw( one two )) {
    $res = call( update_paragraph => { page => 'page.md', heading_path => 'Doc#Sec', content => "body $n" } );
    ok( !$res->{died} && !$res->{isError}, "update_paragraph ($n) succeeds" ) or diag( $res->{died} // $res->{content}[0]{text} );
    push @disk,       $page->slurp_utf8;
    push @hash_after, head_hash();
}

my @chain = commits();
is( scalar @chain, 3, 'three commits reachable from HEAD' ) or diag("warnings: @warnings");

SKIP: {
    skip 'no commit chain', 11 unless @chain == 3;

    is( scalar( () = $chain[0]->parents ), 0, 'first commit is parentless (unborn branch)' );
    is( ( $chain[1]->parents )[0]->id, $chain[0]->id, 'second commit has the first as parent' );
    is( ( $chain[2]->parents )[0]->id, $chain[1]->id, 'third commit has the second as parent' );

    for my $i ( 0 .. 2 ) {
        is( blob_text_at( $chain[$i], 'page.md' ), $disk[$i], "commit $i holds the page as it was on disk then" );
    }
    ok( length $chain[0]->message, 'commit message is non-empty' );
    for my $i ( 0 .. 2 ) {
        my $author = $chain[$i]->author;
        is( $author->name . ' <' . $author->email . '>', 'MCP::Wiki <mcp-wiki@localhost>',
            "commit $i falls back to the MCP::Wiki signature when no identity is configured" );
    }
    is( blob_text_at( $chain[2], 'page.md' ), $page->slurp_utf8, 'HEAD matches the work tree' );
}

# ---- history
$res = call( get_section_history => { page => 'page.md', heading_path => 'Doc#Sec' } );
ok( !$res->{died} && !$res->{isError}, 'get_section_history answers without error' )
    or diag( $res->{died} // $res->{content}[0]{text} );
if ( $res->{content} && !$res->{isError} ) {
    my %seen = map { $_->{hash} => 1 } @{ data_of($res)->{commits} };
    ok( $seen{ $hash_after[1] } && $seen{ $hash_after[2] }, 'history lists the update commits' )
        or diag( 'wanted ' . join( ',', map { $_ // 'undef' } @hash_after[ 1, 2 ] ) . ' got ' . join( ',', sort keys %seen ) );
}

# ---- restore to the commit after the first update
$res = call(
    restore_section => {
        page => 'page.md', heading_path => 'Doc#Sec', commit_hash => ( $hash_after[1] // 'missing' ),
    }
);
ok( !$res->{died} && !$res->{isError}, 'restore_section succeeds' ) or diag( $res->{died} // $res->{content}[0]{text} );
{
    my $now = $page->slurp_utf8;
    like( $now, qr/^body one$/m, 'restored body is back on disk' );
    unlike( $now, qr/body two/, 'the newer body is gone' );
    like( $now, qr/^other stays$/m, 'other sections are unchanged' );
}

# ---- unknown commit
$res = call( restore_section => { page => 'page.md', heading_path => 'Doc#Sec', commit_hash => 'deadbeef' x 5 } );
ok( !$res->{died}, 'restore with unknown commit does not die' ) or diag( $res->{died} );
ok( $res->{isError}, 'restore with unknown commit answers isError' );

# ---- non-ASCII
$res = call( create_page => { page => 'u.md', content => "# Top\n## Über Größe\nÄrger 日本\n" } );
ok( !$res->{died} && !$res->{isError}, 'create non-ASCII page' );
my $created = head_hash();
$res = call( update_paragraph => { page => 'u.md', heading_path => 'Top#Über Größe', content => 'Neu' } );
ok( !$res->{died} && !$res->{isError}, 'update non-ASCII section' );

$res = call( get_section_history => { page => 'u.md', heading_path => 'Top#Über Größe' } );
ok( !$res->{died} && !$res->{isError}, 'history for the non-ASCII heading answers' ) or diag( $res->{died} // $res->{content}[0]{text} );
ok( $res->{content} && !$res->{isError} && @{ data_of($res)->{commits} } > 0, 'history finds the non-ASCII section' );

$res = call( restore_section => { page => 'u.md', heading_path => 'Top#Über Größe', commit_hash => ( $created // 'missing' ) } );
ok( !$res->{died} && !$res->{isError}, 'restore of the non-ASCII section succeeds' ) or diag( $res->{died} // $res->{content}[0]{text} );
{
    my $raw  = $dir->child('u.md')->slurp_raw;
    my $text = eval { decode( 'UTF-8', $raw, FB_CROAK ) };
    ok( defined $text, 'file is valid UTF-8' );
    like( $text // '', qr/^## Über Größe$/m, 'heading intact' );
    like( $text // '', qr/^Ärger 日本$/m, 'restored body intact, not double-encoded' );
}

done_testing;
