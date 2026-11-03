#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Path::Tiny qw( tempdir );

# A wiki that is not the top of its repository: a subdirectory of it, or a
# linked worktree. Commits and history address pages relative to the
# repository, the tools keep addressing them relative to the wiki.
# Opt-in against the real Git::Raw, hermetic like t/42.
my $home;
BEGIN {
    $home = tempdir;
    $ENV{HOME}                = "$home";
    $ENV{XDG_CONFIG_HOME}     = "$home";
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    delete @ENV{qw( GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR )};
}

# MCP::Server must be loaded before Git::Raw (see t/42)
use MCP::Wiki::Server;

BEGIN {
    plan skip_all => 'Git::Raw not installed (opt-in test against the real API)'
        unless eval { require Git::Raw; 1 };
}

sub tool_caller {
    my ($server) = @_;
    return sub {
        my ( $name, $args ) = @_;
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        BAIL_OUT("no tool $name") unless $tool;
        my $res;
        eval { $res = $tool->code->( $tool, $args ); 1 } or return { died => $@ };
        return $res;
    };
}

sub head_blob {
    my ( $repo, $path ) = @_;
    my $entry = $repo->head->peel('commit')->tree->entry_bypath($path) or return;
    return $entry->object->content;
}

sub commit_count {
    my ($repo) = @_;
    my $walker = Git::Raw::Walker->create($repo);
    $walker->push( $repo->head->peel('commit') );
    my $n = 0;
    $n++ while $walker->next;
    return $n;
}

# -- a wiki in a subdirectory of a repository --------------------------------
{
    my $top  = tempdir;
    my $repo = Git::Raw::Repository->init( "$top", 0 );
    my $wiki = $top->child( 'docs', 'wiki' );
    $wiki->mkpath;
    $top->child('README')->spew_utf8("not part of the wiki\n");

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $server = MCP::Wiki::Server->new( wiki_root => "$wiki", use_git => 1 );
    my $call   = tool_caller($server);
    is_deeply( \@warnings, [], 'subdirectory: the repository is found above the wiki, no warning' );
    ok( $server->git_history, 'subdirectory: there is a history' );

    my $res = $call->( create_page => { page => 'sub/page.md', content => "# Doc\n## Sec\nbody zero\n" } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: create_page succeeds' )
        or diag( $res->{died} // $res->{content}[0]{text} );
    is( commit_count($repo), 1, 'subdirectory: the write is committed' );
    is( head_blob( $repo, 'docs/wiki/sub/page.md' ), "# Doc\n## Sec\nbody zero\n",
        'subdirectory: the page sits under the wiki root inside the repository' );
    ok( !head_blob( $repo, 'sub/page.md' ), 'subdirectory: and not at the top of the repository' );
    ok( !head_blob( $repo, 'README' ), 'subdirectory: files outside the wiki are not committed' );

    $res = $call->( update_paragraph => { page => 'sub/page.md', heading_path => 'Doc#Sec', content => 'body one' } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: update_paragraph succeeds' );
    my $second = $repo->head->peel('commit')->id;

    $res = $call->( get_section_history => { page => 'sub/page.md', heading_path => 'Doc#Sec' } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: get_section_history answers' )
        or diag( $res->{died} // $res->{content}[0]{text} );
    is( scalar @{ $res->{structuredContent}{commits} // [] }, 2,
        'subdirectory: both commits are in the section history, addressed by the page name' );

    $res = $call->( restore_section => {
        page => 'sub/page.md', heading_path => 'Doc#Sec', commit_hash => $second } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: restore_section finds the page in history' )
        or diag( $res->{died} // $res->{content}[0]{text} );

    $res = $call->( rename_page => { from => 'sub/page.md', to => 'moved.md' } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: rename_page succeeds' );
    ok( head_blob( $repo, 'docs/wiki/moved.md' ), 'subdirectory: the new name is committed' );
    ok( !head_blob( $repo, 'docs/wiki/sub/page.md' ), 'subdirectory: and the old one removed' );

    $res = $call->( delete_page => { page => 'moved.md' } );
    ok( !$res->{died} && !$res->{isError}, 'subdirectory: delete_page succeeds' );
    ok( !head_blob( $repo, 'docs/wiki/moved.md' ), 'subdirectory: the delete is committed' );
    is_deeply( \@warnings, [], 'subdirectory: no warning on any write' );
}

# -- a wiki that is a linked worktree ----------------------------------------
SKIP: {
    skip 'this Git::Raw has no worktrees', 9 unless Git::Raw::Worktree->can('add');

    my $main_dir = tempdir;
    my $main     = Git::Raw::Repository->init( "$main_dir", 0 );
    $main_dir->child('seed.md')->spew_utf8("# Seed\ntext\n");
    my $index = $main->index;
    $index->add('seed.md');
    $index->write;
    my $sig = Git::Raw::Signature->new( 'T', 't@localhost', 0, 0 );
    Git::Raw::Commit->create( $main, 'seed', $sig, $sig, [], $index->write_tree );

    my $linked_dir = tempdir;
    my $linked     = $linked_dir->child('wt');
    Git::Raw::Worktree->add( $main, 'wt', "$linked" );
    ok( $linked->child('.git')->is_file, 'worktree: the linked worktree has a .git file, no directory' );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $server = MCP::Wiki::Server->new( wiki_root => "$linked", use_git => 1 );
    my $call   = tool_caller($server);
    is_deeply( \@warnings, [], 'worktree: the repository is found, no warning' );
    ok( $server->git_history, 'worktree: there is a history' );

    my $res = $call->( create_page => { page => 'wt.md', content => "# Wt\ntext\n" } );
    ok( !$res->{died} && !$res->{isError}, 'worktree: create_page succeeds' )
        or diag( $res->{died} // $res->{content}[0]{text} );
    my $wt_repo = Git::Raw::Repository->open("$linked");
    is( commit_count($wt_repo), 2, 'worktree: the write is committed on top of the seed' );
    ok( head_blob( $wt_repo, 'wt.md' ), 'worktree: the page is in the commit' );
    ok( head_blob( $wt_repo, 'seed.md' ), 'worktree: and so is what the branch had' );

    $res = $call->( get_section_history => { page => 'wt.md', heading_path => 'Wt' } );
    ok( !$res->{died} && !$res->{isError}, 'worktree: get_section_history answers' )
        or diag( $res->{died} // $res->{content}[0]{text} );
    is_deeply( \@warnings, [], 'worktree: no warning on any write' );
}

done_testing;
