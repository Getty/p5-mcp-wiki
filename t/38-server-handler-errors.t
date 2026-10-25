use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# Every tool handler answers a failure with an isError result that names the
# problem; no exception may escape the handler (it would surface to the model
# as an opaque JSON-RPC -32603 "Internal error").

{
    package Local::DyingHistory;
    sub new { return bless {}, shift }
    sub get_section_commits { die "boom-commits-17\n" }
    sub restore_section     { die "boom-restore-23\n" }
    sub auto_commit         { return }
}

my $wiki = tempdir;
$wiki->child('page.md')->spew_utf8("# Intro\nintro text\n## Alpha\nalpha\n");

my $server = MCP::Wiki::Server->new(
    wiki_root   => "$wiki",
    use_git     => 1,
    git_history => Local::DyingHistory->new,
);

# Calls a tool by name; a die is caught and reported, not propagated.
sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res;
    my $ok = eval { $res = $tool->code->( $tool, $args ); 1 };
    return ( $ok, $res, $ok ? undef : $@ );
}

sub expect_error {
    my ( $label, $name, $args, $re ) = @_;
    my ( $ok, $res, $err ) = call( $name, $args );
    ok( $ok, "$label: handler does not die" ) or diag("died with: $err");
    return unless $ok;
    ok( $res->{isError}, "$label: isError is set" );
    like( $res->{content}[0]{text} // '', $re, "$label: message names the problem" );
}

# delete_page on a directory named like a page
$wiki->child('dir.md')->mkpath;
expect_error( 'delete_page on a directory', 'delete_page', { page => 'dir.md' }, qr/directory/i );
ok( $wiki->child('dir.md')->is_dir, 'the directory is still there' );

# History tools with a stand-in whose methods die
expect_error( 'get_section_history', 'get_section_history',
    { page => 'page.md', heading_path => 'Intro' }, qr/boom-commits-17/ );

expect_error( 'restore_section', 'restore_section',
    { page => 'page.md', heading_path => 'Intro#Alpha', commit_hash => 'abc123' }, qr/boom-restore-23/ );
is( $wiki->child('page.md')->slurp_utf8, "# Intro\nintro text\n## Alpha\nalpha\n",
    'a failed restore leaves the page untouched' );

# Unreadable page
SKIP: {
    skip 'permission checks are meaningless as root', 4 if $> == 0;
    my $secret = $wiki->child('secret.md');
    $secret->spew_utf8("# Hidden\ntext\n");
    chmod 0000, "$secret";
    skip 'file is still readable', 4 if -r "$secret";

    expect_error( 'get_toc on unreadable page', 'get_toc', { page => 'secret.md' }, qr/permission denied/i );
    expect_error( 'get_paragraph on unreadable page', 'get_paragraph',
        { page => 'secret.md', heading_path => 'Hidden' }, qr/permission denied/i );
    chmod 0600, "$secret";
}

done_testing;
