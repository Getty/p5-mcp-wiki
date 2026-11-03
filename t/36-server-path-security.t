#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir path );
use MCP::Wiki::Server;

# Every tool must stay inside the wiki root the server was started with. The
# client is a language model reading untrusted wiki content, so neither an
# argument nor a page name may move a read, a write or a delete elsewhere.

my $SECRET = 'top secret';
my $can_symlink = eval { symlink( '', '' ); 1 };

# Fresh tree per subtest:
#
#   $base/wiki/          the wiki root
#     page.md, data.txt, sub/inner.md
#     alias.md    -> page.md                    (symlink staying inside)
#     leak.md     -> ../elsewhere/notes.md      (file symlink leaving)
#     out         -> ../elsewhere               (directory symlink leaving)
#     dangling.md -> ../elsewhere/not-yet.md    (target does not exist yet)
#     twin        -> ../wiki-evil               (directory symlink to the sibling)
#     fake.md     -> data.txt                   (markdown name, other file)
#     gitlink     -> .git                       (directory symlink into the repository)
#     gitnote.md  -> .git/notes.md              (file symlink into the repository)
#     .git/config, .git/notes.md, .git/hooks/   stand-in for the wiki's repository
#     sub/.GIT/x.md                             the same name in another case
#   $base/elsewhere/     unrelated directory
#   $base/wiki-evil/     sibling sharing the root's name as a prefix
sub fixture {
    my $base = tempdir;
    my $wiki = $base->child('wiki');
    my $else = $base->child('elsewhere');
    my $evil = $base->child('wiki-evil');
    my $git   = $wiki->child('.git');
    my $upper = $wiki->child( 'sub', '.GIT' );
    $_->mkpath for $wiki, $wiki->child('sub'), $else, $evil, $git->child('hooks'), $upper;

    $wiki->child('page.md')->spew_utf8("# Page\n\ninside\n");
    $wiki->child('data.txt')->spew_utf8("# Data\n\n$SECRET\n");
    $git->child('config')->spew_utf8("# note\n[core]\n\tbare = false\n");
    $git->child('notes.md')->spew_utf8("# Gitnote\n\n$SECRET\n");
    $upper->child('x.md')->spew_utf8("# Upper\n\n$SECRET\n");
    $wiki->child( 'sub', 'inner.md' )->spew_utf8("# Inner\n\nnested\n");
    $else->child('notes.md')->spew_utf8("# Secret\n\n$SECRET\n");
    $else->child('notes.txt')->spew_utf8("$SECRET\n");
    $evil->child('x.md')->spew_utf8("# Evil\n\n$SECRET\n");

    if ($can_symlink) {
        symlink 'page.md',                 $wiki->child('alias.md')    or die "symlink: $!";
        symlink '../elsewhere/notes.md',   $wiki->child('leak.md')     or die "symlink: $!";
        symlink '../elsewhere',            $wiki->child('out')         or die "symlink: $!";
        symlink '../elsewhere/not-yet.md', $wiki->child('dangling.md') or die "symlink: $!";
        symlink '../wiki-evil',            $wiki->child('twin')        or die "symlink: $!";
        symlink 'data.txt',                $wiki->child('fake.md')     or die "symlink: $!";
        symlink '.git',                    $wiki->child('gitlink')     or die "symlink: $!";
        symlink '.git/notes.md',           $wiki->child('gitnote.md')  or die "symlink: $!";
    }

    my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );
    return {
        base   => $base,
        wiki   => $wiki,
        else   => $else,
        evil   => $evil,
        git    => $git,
        upper  => $upper,
        server => $server,
    };
}

sub tool {
    my ( $server, $name ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    die "no such tool: $name" unless $tool;
    return $tool;
}

# Returns ( $result, $text ). Tools registered through _add_tool turn a die into
# an isError result "<tool> failed: ...", so a handler that dies instead of
# rejecting deliberately looks like a rejection here; callers compare $text
# where the reason matters. The DIED branch only fires if a die escapes anyway.
sub call {
    my ( $server, $name, $args ) = @_;
    my $tool   = tool( $server, $name );
    my $result = eval { $tool->code->( $tool, $args ) };
    return ( undef, "DIED: $@" ) unless $result;
    return ( $result, $result->{content}[0]{text} );
}

# Names and contents of everything no tool call may touch: the directories
# outside the wiki root, the repository directories inside it and the one file
# in the wiki that is not a page.
sub protected_state {
    my ($f) = @_;
    my $data  = $f->{wiki}->child('data.txt');
    my @state = ( $data . '=' . ( -e $data ? $data->slurp_raw : '<gone>' ) );
    for my $dir ( $f->{else}, $f->{evil}, $f->{git}, $f->{upper} ) {
        my $iter = $dir->iterator( { recurse => 1 } );
        while ( my $path = $iter->() ) {
            push @state, $path . '=' . ( $path->is_file ? $path->slurp_raw : '<dir>' );
        }
    }
    return join "\n", sort @state;
}

sub rejected_ok {
    my ( $f, $name, $args, $label ) = @_;
    my $before = protected_state($f);
    my ( $result, $text ) = call( $f->{server}, $name, $args );
    ok( $result && $result->{isError}, "$label: $name is rejected" )
        or diag($text);
    unlike( $text, qr/\Q$SECRET\E/, "$label: $name leaks no protected content" );
    is( protected_state($f), $before, "$label: $name leaves everything protected untouched" );
    return $text;
}

sub accepted_ok {
    my ( $f, $name, $args, $label ) = @_;
    my ( $result, $text ) = call( $f->{server}, $name, $args );
    ok( $result && !$result->{isError}, "$label: $name succeeds" )
        or diag($text);
    return $text;
}

# The history tools only read git objects, but they take the same page argument
# and must answer the same way. Git::Raw is optional, so a stand-in records
# whether the request got as far as the repository.
{
    package Local::RecordingHistory;
    sub new { return bless { calls => [] }, shift }
    sub calls { return @{ $_[0]{calls} } }

    sub get_section_commits {
        my ( $self, @args ) = @_;
        push @{ $self->{calls} }, [ get_section_commits => @args ];
        return;
    }

    sub restore_section {
        my ( $self, @args ) = @_;
        push @{ $self->{calls} }, [ restore_section => @args ];
        return { conflict => 1 };
    }
}

sub with_history {
    my ($f) = @_;
    my $history = Local::RecordingHistory->new;
    $f->{server} = MCP::Wiki::Server->new(
        wiki_root   => $f->{wiki}->stringify,
        git_history => $history,
    );
    return $history;
}

subtest 'no tool offers root_dir' => sub {
    my $f = fixture();
    for my $tool ( @{ $f->{server}->server->tools } ) {
        ok(
            !exists $tool->input_schema->{properties}{root_dir},
            $tool->name . ' has no root_dir in its input schema'
        );
    }
};

subtest 'root_dir argument is refused' => sub {
    my $f = fixture();
    my %root = ( root_dir => $f->{else}->stringify );

    # read
    rejected_ok( $f, 'list_pages', {%root}, 'foreign root_dir' );
    rejected_ok( $f, 'get_toc', { page => 'notes.md', %root }, 'foreign root_dir' );
    rejected_ok( $f, 'get_paragraph',
        { page => 'notes.md', heading_path => 'Secret', %root }, 'foreign root_dir' );

    # write
    rejected_ok( $f, 'create_page', { page => 'new.md', content => 'x', %root },
        'foreign root_dir' );
    rejected_ok( $f, 'update_paragraph',
        { page => 'notes.md', heading_path => 'Secret', content => 'gone', %root },
        'foreign root_dir' );
    rejected_ok( $f, 'rename_page', { from => 'notes.md', to => 'moved.md', %root },
        'foreign root_dir' );

    # delete
    rejected_ok( $f, 'delete_page', { page => 'notes.md',  %root }, 'foreign root_dir' );
    rejected_ok( $f, 'delete_page', { page => 'notes.txt', %root }, 'foreign root_dir' );

    # A request naming another root must not be carried out against this one
    # either: page.md exists in both places a client might have meant.
    $f->{else}->child('page.md')->spew_utf8("# Other\n");
    rejected_ok( $f, 'delete_page', { page => 'page.md', %root }, 'same page name' );
    ok( -e $f->{wiki}->child('page.md'), 'page of the same name inside the wiki survives' );

    my $text = rejected_ok( $f, 'list_pages',
        { root_dir => $f->{wiki}->child('sub')->stringify }, 'root_dir inside the wiki' );
    like( $text, qr/root_dir/, 'error names the refused argument' );
};

subtest 'parent directory traversal' => sub {
    my $f = fixture();

    # read
    rejected_ok( $f, 'get_toc', { page => '../elsewhere/notes.md' }, 'traversal' );
    rejected_ok( $f, 'get_paragraph',
        { page => '../elsewhere/notes.md', heading_path => 'Secret' }, 'traversal' );
    rejected_ok( $f, 'get_toc', { page => 'sub/../../elsewhere/notes.md' }, 'nested traversal' );

    # write
    rejected_ok( $f, 'create_page', { page => '../elsewhere/new.md', content => 'x' },
        'traversal' );
    rejected_ok( $f, 'create_page', { page => 'nope/../../elsewhere/new.md', content => 'x' },
        'traversal through a missing directory' );
    rejected_ok( $f, 'create_page', { page => '../brand-new/new.md', content => 'x' },
        'traversal into a missing directory' );
    ok( !-e $f->{base}->child('brand-new'), 'no directory is created outside the root' );
    rejected_ok( $f, 'update_paragraph',
        { page => '../elsewhere/notes.md', heading_path => 'Secret', content => 'gone' },
        'traversal' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => '../elsewhere/moved.md' },
        'traversal as target' );
    ok( -e $f->{wiki}->child('page.md'), 'page is not moved out of the wiki' );
    rejected_ok( $f, 'rename_page', { from => '../elsewhere/notes.md', to => 'stolen.md' },
        'traversal as source' );
    ok( !-e $f->{wiki}->child('stolen.md'), 'nothing is moved into the wiki' );

    # delete
    rejected_ok( $f, 'delete_page', { page => '../elsewhere/notes.md' },  'traversal' );
    rejected_ok( $f, 'delete_page', { page => '../elsewhere/notes.txt' }, 'traversal' );
};

subtest 'sibling directory sharing the root name as prefix' => sub {
    my $f = fixture();

    # read
    rejected_ok( $f, 'get_toc', { page => '../wiki-evil/x.md' }, 'prefix sibling' );
    rejected_ok( $f, 'get_paragraph', { page => '../wiki-evil/x.md', heading_path => 'Evil' },
        'prefix sibling' );

    # write
    rejected_ok( $f, 'create_page', { page => '../wiki-evil/new.md', content => 'x' },
        'prefix sibling' );
    rejected_ok( $f, 'update_paragraph',
        { page => '../wiki-evil/x.md', heading_path => 'Evil', content => 'gone' },
        'prefix sibling' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => '../wiki-evil/moved.md' },
        'prefix sibling as target' );
    rejected_ok( $f, 'rename_page', { from => '../wiki-evil/x.md', to => 'stolen.md' },
        'prefix sibling as source' );

    # delete
    rejected_ok( $f, 'delete_page', { page => '../wiki-evil/x.md' }, 'prefix sibling' );

    # Reached through a symlink there is no ".." step to trip over: the resolved
    # path starts with the root's own characters and only the path boundary
    # tells the two directories apart.
    SKIP: {
        skip 'symlinks not available', 21 unless $can_symlink;
        $f = fixture();
        rejected_ok( $f, 'get_toc', { page => 'twin/x.md' }, 'symlinked prefix sibling' );
        rejected_ok( $f, 'get_paragraph', { page => 'twin/x.md', heading_path => 'Evil' },
            'symlinked prefix sibling' );
        rejected_ok( $f, 'create_page', { page => 'twin/new.md', content => 'x' },
            'symlinked prefix sibling' );
        rejected_ok( $f, 'update_paragraph',
            { page => 'twin/x.md', heading_path => 'Evil', content => 'gone' },
            'symlinked prefix sibling' );
        rejected_ok( $f, 'rename_page', { from => 'page.md', to => 'twin/moved.md' },
            'symlinked prefix sibling as target' );
        rejected_ok( $f, 'rename_page', { from => 'twin/x.md', to => 'stolen.md' },
            'symlinked prefix sibling as source' );
        rejected_ok( $f, 'delete_page', { page => 'twin/x.md' }, 'symlinked prefix sibling' );
    }
};

subtest 'symlink leaving the wiki root' => sub {
    plan skip_all => 'symlinks not available' unless $can_symlink;
    my $f = fixture();

    # read
    my ($listing) = call( $f->{server}, 'list_pages', {} );
    is_deeply( [ grep { m{^(?:out|twin)/} } @{ $listing->{structuredContent}{pages} } ],
        [], 'list_pages does not descend through a directory symlink' );
    rejected_ok( $f, 'get_toc', { page => 'leak.md' },      'file symlink' );
    rejected_ok( $f, 'get_toc', { page => 'out/notes.md' }, 'directory symlink' );
    rejected_ok( $f, 'get_paragraph', { page => 'leak.md', heading_path => 'Secret' },
        'file symlink' );
    rejected_ok( $f, 'get_paragraph', { page => 'out/notes.md', heading_path => 'Secret' },
        'directory symlink' );

    # write
    rejected_ok( $f, 'update_paragraph',
        { page => 'leak.md', heading_path => 'Secret', content => 'gone' }, 'file symlink' );
    rejected_ok( $f, 'update_paragraph',
        { page => 'out/notes.md', heading_path => 'Secret', content => 'gone' },
        'directory symlink' );
    rejected_ok( $f, 'create_page', { page => 'out/new.md', content => 'x' },
        'directory symlink' );
    rejected_ok( $f, 'create_page', { page => 'out/deep/er/new.md', content => 'x' },
        'missing directories behind a directory symlink' );
    rejected_ok( $f, 'create_page', { page => 'dangling.md', content => 'x' },
        'dangling symlink' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => 'out/moved.md' },
        'directory symlink as target' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => 'dangling.md' },
        'dangling symlink as target' );
    ok( -e $f->{wiki}->child('page.md'), 'page is not moved out of the wiki' );
    rejected_ok( $f, 'rename_page', { from => 'out/notes.md', to => 'stolen.md' },
        'directory symlink as source' );
    ok( !-e $f->{wiki}->child('stolen.md'), 'nothing is moved into the wiki' );

    # delete
    rejected_ok( $f, 'delete_page', { page => 'leak.md' },      'file symlink' );
    rejected_ok( $f, 'delete_page', { page => 'out/notes.md' }, 'directory symlink' );
    ok( -l $f->{wiki}->child('leak.md'), 'the symlink itself is left alone' );
};

subtest 'pages inside the wiki root keep working' => sub {
    my $f = fixture();

    like( accepted_ok( $f, 'get_toc', { page => 'sub/inner.md' }, 'subdirectory' ),
        qr/"heading":\s*"Inner"/, 'page in a subdirectory is read' );
    like( accepted_ok( $f, 'get_toc', { page => 'sub/../page.md' }, 'dot-dot inside the root' ),
        qr/"heading":\s*"Page"/, 'a path that only wanders inside the root is read' );

    accepted_ok( $f, 'create_page', { page => 'unter/tief/neu.md', content => "# Neu\n" },
        'missing subdirectories' );
    is( $f->{wiki}->child( 'unter', 'tief', 'neu.md' )->slurp_utf8, "# Neu\n",
        'page is created together with its directories' );

    accepted_ok( $f, 'rename_page', { from => 'page.md', to => 'archiv/alt/page.md' },
        'rename into missing subdirectories' );
    ok( -e $f->{wiki}->child( 'archiv', 'alt', 'page.md' ), 'page is moved' );
    ok( !-e $f->{wiki}->child('page.md'), 'old name is gone' );

    accepted_ok( $f, 'delete_page', { page => 'sub/inner.md' }, 'subdirectory' );
    ok( !-e $f->{wiki}->child( 'sub', 'inner.md' ), 'page is deleted' );

    my ($listing) = call( $f->{server}, 'list_pages', {} );
    my %listed = map { $_ => 1 } @{ $listing->{structuredContent}{pages} };
    ok( $listed{'archiv/alt/page.md'} && $listed{'unter/tief/neu.md'},
        'list_pages reports the pages relative to the root' )
        or diag( explain [ sort keys %listed ] );
    ok( !$listed{'page.md'} && !$listed{'sub/inner.md'},
        'renamed and deleted pages are no longer listed' );
    is_deeply( [ grep { m{^/} || m{(?:^|/)\.\.(?:/|$)} } keys %listed ],
        [], 'no listed page points outside the root' );
};

subtest 'symlinks staying inside the wiki root keep working' => sub {
    plan skip_all => 'symlinks not available' unless $can_symlink;
    my $f = fixture();

    like( accepted_ok( $f, 'get_toc', { page => 'alias.md' }, 'inner symlink' ),
        qr/"heading":\s*"Page"/, 'symlink to a page inside the root is read' );

    # The root may itself be reached through a symlink.
    my $link = $f->{base}->child('wiki-link');
    symlink $f->{wiki}, $link or die "symlink: $!";
    my $server = MCP::Wiki::Server->new( wiki_root => "$link" );
    my ( $result, $text ) = call( $server, 'get_toc', { page => 'sub/inner.md' } );
    ok( $result && !$result->{isError}, 'wiki_root given as a symlink works' ) or diag($text);
    ( $result, $text ) = call( $server, 'get_toc', { page => '../elsewhere/notes.md' } );
    ok( $result && $result->{isError}, 'and is still a boundary' ) or diag($text);
};

subtest 'only markdown files are pages' => sub {
    my $f       = fixture();
    my $history = with_history($f);

    # read
    rejected_ok( $f, 'get_toc', { page => 'data.txt' }, 'non-markdown file' );
    rejected_ok( $f, 'get_paragraph', { page => 'data.txt', heading_path => 'Data' },
        'non-markdown file' );
    rejected_ok( $f, 'get_section_history', { page => 'data.txt', heading_path => 'Data' },
        'non-markdown file' );

    # write
    rejected_ok( $f, 'create_page', { page => 'notes', content => 'x' }, 'name without extension' );
    rejected_ok( $f, 'create_page', { page => 'notes.txt', content => 'x' }, 'non-markdown name' );
    rejected_ok( $f, 'create_page', { page => 'bin/run.sh', content => 'x' },
        'non-markdown name in a new directory' );
    ok( !-e $f->{wiki}->child($_), "$_ is not created" ) for qw( notes notes.txt bin );
    rejected_ok( $f, 'update_paragraph',
        { page => 'data.txt', heading_path => 'Data', content => 'gone' }, 'non-markdown file' );
    rejected_ok( $f, 'restore_section',
        { page => 'data.txt', heading_path => 'Data', commit_hash => 'abc' },
        'non-markdown file' );
    rejected_ok( $f, 'rename_page', { from => 'data.txt', to => 'data.md' },
        'non-markdown source' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => 'page.txt' },
        'non-markdown target' );
    ok( -e $f->{wiki}->child('page.md'), 'page is not renamed to a non-markdown name' );

    # delete
    rejected_ok( $f, 'delete_page', { page => 'data.txt' }, 'non-markdown file' );

    is( scalar $history->calls, 0, 'no rejected request reaches the repository' );

    # The name is no way around it: what counts is the file a call would act on.
    SKIP: {
        skip 'symlinks not available', 9 unless $can_symlink;
        rejected_ok( $f, 'get_paragraph', { page => 'fake.md', heading_path => 'Data' },
            'markdown-named symlink to another file' );
        rejected_ok( $f, 'update_paragraph',
            { page => 'fake.md', heading_path => 'Data', content => 'gone' },
            'markdown-named symlink to another file' );
        rejected_ok( $f, 'delete_page', { page => 'fake.md' },
            'markdown-named symlink to another file' );
    }

    accepted_ok( $f, 'create_page', { page => 'LOUD.MD', content => "# Loud\n" },
        'extension in upper case' );
    ok( -e $f->{wiki}->child('LOUD.MD'), 'extension is matched without regard to case' );
};

subtest 'nothing below .git is a page' => sub {
    my $f       = fixture();
    my $history = with_history($f);

    # read
    rejected_ok( $f, 'get_toc', { page => '.git/notes.md' }, 'repository' );
    rejected_ok( $f, 'get_paragraph', { page => '.git/notes.md', heading_path => 'Gitnote' },
        'repository' );
    rejected_ok( $f, 'get_paragraph', { page => '.git/config', heading_path => 'note' },
        'repository config' );
    rejected_ok( $f, 'get_section_history',
        { page => '.git/notes.md', heading_path => 'Gitnote' }, 'repository' );

    # write
    rejected_ok( $f, 'create_page', { page => '.git/hooks/pre-commit', content => 'x' },
        'repository hook' );
    rejected_ok( $f, 'create_page', { page => '.git/hooks/pre-commit.md', content => 'x' },
        'repository hook with a page name' );
    rejected_ok( $f, 'create_page', { page => '.git/new.md', content => 'x' }, 'repository' );
    rejected_ok( $f, 'update_paragraph',
        { page => '.git/config', heading_path => 'note', content => "[core]\n\tfsmonitor = x" },
        'repository config' );
    rejected_ok( $f, 'update_paragraph',
        { page => '.git/notes.md', heading_path => 'Gitnote', content => 'gone' },
        'repository' );
    rejected_ok( $f, 'restore_section',
        { page => '.git/notes.md', heading_path => 'Gitnote', commit_hash => 'abc' },
        'repository' );
    rejected_ok( $f, 'rename_page', { from => 'page.md', to => '.git/moved.md' },
        'repository as target' );
    ok( -e $f->{wiki}->child('page.md'), 'page is not moved into the repository' );
    rejected_ok( $f, 'rename_page', { from => '.git/notes.md', to => 'stolen.md' },
        'repository as source' );
    ok( !-e $f->{wiki}->child('stolen.md'), 'nothing is moved out of the repository' );

    # delete
    rejected_ok( $f, 'delete_page', { page => '.git/notes.md' }, 'repository' );
    rejected_ok( $f, 'delete_page', { page => '.git/config' },   'repository config' );

    # Other spellings, deeper levels and detours name the same thing.
    rejected_ok( $f, 'get_toc', { page => 'sub/.GIT/x.md' }, 'upper case' );
    rejected_ok( $f, 'update_paragraph',
        { page => 'sub/.GIT/x.md', heading_path => 'Upper', content => 'gone' }, 'upper case' );
    rejected_ok( $f, 'delete_page', { page => 'sub/.GIT/x.md' }, 'upper case' );
    rejected_ok( $f, 'create_page', { page => '.GIT/new.md',  content => 'x' }, 'upper case, new' );
    rejected_ok( $f, 'create_page', { page => '.Git/new.md',  content => 'x' }, 'mixed case, new' );
    rejected_ok( $f, 'create_page', { page => 'sub/.git/new.md', content => 'x' }, 'nested, new' );
    rejected_ok( $f, 'create_page', { page => 'neu/.git/hooks/x.md', content => 'x' },
        'below a new directory' );
    ok( !-e $f->{wiki}->child($_), "$_ is not created" ) for qw( .GIT .Git sub/.git neu );
    rejected_ok( $f, 'get_toc',     { page => 'sub/../.git/notes.md' }, 'detour' );
    rejected_ok( $f, 'delete_page', { page => './.git//notes.md' },     'padded name' );

    is( scalar $history->calls, 0, 'no rejected request reaches the repository' );

    # A symlink in the wiki must not be a second door into the repository.
    SKIP: {
        skip 'symlinks not available', 31 unless $can_symlink;

        # read
        rejected_ok( $f, 'get_toc', { page => 'gitlink/notes.md' }, 'directory symlink' );
        rejected_ok( $f, 'get_paragraph', { page => 'gitnote.md', heading_path => 'Gitnote' },
            'file symlink' );

        # write
        rejected_ok( $f, 'create_page', { page => 'gitlink/hooks/pre-commit.md', content => 'x' },
            'directory symlink' );
        rejected_ok( $f, 'update_paragraph',
            { page => 'gitnote.md', heading_path => 'Gitnote', content => 'gone' },
            'file symlink' );
        rejected_ok( $f, 'rename_page', { from => 'page.md', to => 'gitlink/moved.md' },
            'directory symlink as target' );
        rejected_ok( $f, 'rename_page', { from => 'gitnote.md', to => 'stolen.md' },
            'file symlink as source' );

        # delete
        rejected_ok( $f, 'delete_page', { page => 'gitlink/notes.md' }, 'directory symlink' );
        rejected_ok( $f, 'delete_page', { page => 'gitnote.md' },       'file symlink' );

        # The other way round: a .git that is itself a symlink resolves to a
        # path without the name in it and is still the repository.
        my $store = $f->{wiki}->child('store');
        $_->mkpath for $store, $f->{wiki}->child('mod');
        $store->child('x.md')->spew_utf8("# Stored\n\n$SECRET\n");
        symlink '../store', $f->{wiki}->child( 'mod', '.git' ) or die "symlink: $!";
        rejected_ok( $f, 'get_paragraph', { page => 'mod/.git/x.md', heading_path => 'Stored' },
            'symlinked .git' );
        rejected_ok( $f, 'delete_page', { page => 'mod/.git/x.md' }, 'symlinked .git' );
        ok( -e $store->child('x.md'), 'file behind a symlinked .git survives' );
    }
};

subtest 'list_pages lists exactly the pages the other tools accept' => sub {
    my $f = fixture();

    # Not listed: data.txt (no page), everything below .git and .GIT, and the
    # symlinks leading out of the wiki, into the repository or to a file that
    # is no page. alias.md points to a page inside and stays.
    my ( $result, $text ) = call( $f->{server}, 'list_pages', {} );
    my @expected = $can_symlink
        ? ( 'alias.md', 'page.md', 'sub/inner.md' )
        : ( 'page.md', 'sub/inner.md' );
    is_deeply( $result->{structuredContent}{pages}, \@expected, 'only addressable pages' )
        or diag($text);
    is( $result->{structuredContent}{count}, scalar @expected, 'count matches' );

    for my $page (@expected) {
        accepted_ok( $f, 'get_toc', { page => $page }, "listed page $page" );
    }

    # The repository is skipped, not walked and filtered: a directory in it
    # that cannot be read does not get in the way.
    SKIP: {
        skip 'running as root, permissions do not bite', 2 unless $>;
        my $hooks = $f->{git}->child('hooks');
        chmod 0000, $hooks or die "chmod: $!";
        ( $result, $text ) = call( $f->{server}, 'list_pages', {} );
        chmod 0755, $hooks or die "chmod: $!";
        ok( $result && !$result->{isError}, 'list_pages does not enter .git' ) or diag($text);
        is_deeply( $result->{structuredContent}{pages}, \@expected, 'and lists the same pages' );
    }
};

subtest 'the prefix of list_pages is held to the same boundary' => sub {
    my $f = fixture();

    rejected_ok( $f, 'list_pages', { prefix => '..' },                   'root parent' );
    rejected_ok( $f, 'list_pages', { prefix => '../elsewhere' },         'directory outside' );
    rejected_ok( $f, 'list_pages', { prefix => '../wiki-evil' },         'sibling sharing the root name' );
    rejected_ok( $f, 'list_pages', { prefix => 'sub/../..' },            'dot-dot detour' );
    rejected_ok( $f, 'list_pages', { prefix => '.git' },                 'repository' );
    rejected_ok( $f, 'list_pages', { prefix => 'sub/.GIT' },             'repository in another case' );
    rejected_ok( $f, 'list_pages', { prefix => 'page.md' },              'a page is no directory' );
    if ($can_symlink) {
        rejected_ok( $f, 'list_pages', { prefix => 'out' },       'directory symlink leaving' );
        rejected_ok( $f, 'list_pages', { prefix => 'twin' },      'directory symlink to the sibling' );
        rejected_ok( $f, 'list_pages', { prefix => 'gitlink' },   'directory symlink into the repository' );
    }
    my ($result) = call( $f->{server}, 'list_pages', { prefix => 'sub' } );
    is_deeply( $result->{structuredContent}{pages}, ['sub/inner.md'], 'a directory inside is listed' );
};

subtest 'page must name something below the root' => sub {
    my $f = fixture();

    rejected_ok( $f, 'get_toc',     { page => '.' },      'root itself' );
    rejected_ok( $f, 'get_toc',     { page => '' },       'empty name' );
    rejected_ok( $f, 'get_toc',     { page => 'sub/..' }, 'root by detour' );
    rejected_ok( $f, 'delete_page', { page => '.' },      'root itself' );
    rejected_ok( $f, 'get_toc',     { page => 'missing/gone.md' }, 'missing page' );
    ok( -d $f->{wiki}, 'wiki root is still there' );
};

subtest 'history tools use the same boundary' => sub {
    my $f       = fixture();
    my $history = with_history($f);

    rejected_ok( $f, 'get_section_history',
        { page => 'notes.md', heading_path => 'Secret', root_dir => $f->{else}->stringify },
        'foreign root_dir' );
    rejected_ok( $f, 'get_section_history',
        { page => '../elsewhere/notes.md', heading_path => 'Secret' }, 'traversal' );
    rejected_ok( $f, 'get_section_history',
        { page => '../wiki-evil/x.md', heading_path => 'Evil' }, 'prefix sibling' );
    rejected_ok( $f, 'restore_section',
        {
            page         => 'notes.md',
            heading_path => 'Secret',
            commit_hash  => 'abc',
            root_dir     => $f->{else}->stringify,
        },
        'foreign root_dir'
    );
    rejected_ok( $f, 'restore_section',
        { page => '../elsewhere/notes.md', heading_path => 'Secret', commit_hash => 'abc' },
        'traversal' );
    is( scalar $history->calls, 0, 'no rejected request reaches the repository' );

    accepted_ok( $f, 'get_section_history', { page => 'page.md', heading_path => 'Page' },
        'page inside the root' );
    is( scalar $history->calls, 1, 'a valid request does' );
};

# Tools that take a page and nothing else that matters here: every spelling of
# a page the wiki must refuse is tried on each of them, and a plain page works.
my %PAGE_TOOLS = (
    get_page       => sub { +{ page => $_[0] } },
    write_page     => sub { +{ page => $_[0], content => "# Gone\n" } },
    add_section    => sub { +{ page => $_[0], heading => 'Gone' } },
    delete_section => sub { +{ page => $_[0], heading_path => 'Secret' } },
    rename_heading => sub { +{ page => $_[0], heading_path => 'Secret', heading => 'Gone' } },
);

subtest 'every page name a tool refuses, refused by the later tools too' => sub {
    my @bad = (
        [ '../elsewhere/notes.md'            => 'traversal' ],
        [ 'sub/../../elsewhere/notes.md'     => 'nested traversal' ],
        [ '../wiki-evil/x.md'                => 'prefix sibling' ],
        [ 'data.txt'                         => 'non-markdown file' ],
        [ '.git/notes.md'                    => 'repository' ],
        [ '.git/config'                      => 'repository config' ],
        [ 'sub/.GIT/x.md'                    => 'repository in upper case' ],
        [ 'sub/../.git/notes.md'             => 'detour into the repository' ],
        ( $can_symlink ? (
            [ 'leak.md'         => 'file symlink leaving' ],
            [ 'out/notes.md'    => 'directory symlink leaving' ],
            [ 'twin/x.md'       => 'symlinked prefix sibling' ],
            [ 'fake.md'         => 'markdown name for another file' ],
            [ 'gitnote.md'      => 'file symlink into the repository' ],
            [ 'gitlink/notes.md' => 'directory symlink into the repository' ],
        ) : () ),
    );
    for my $name ( sort keys %PAGE_TOOLS ) {
        my $f = fixture();
        rejected_ok( $f, $name, $PAGE_TOOLS{$name}->( $_->[0] ), $_->[1] ) for @bad;
        rejected_ok( $f, $name, { %{ $PAGE_TOOLS{$name}->('page.md') }, root_dir => $f->{else}->stringify },
            'foreign root_dir' );
        accepted_ok( $f, $name, $PAGE_TOOLS{$name}->('page.md'), 'page inside the root' )
            if $name eq 'get_page';
    }
    my $f = fixture();
    accepted_ok( $f, 'write_page', { page => 'page.md', content => "# New\n" }, 'page inside the root' );
    accepted_ok( $f, 'add_section', { page => 'sub/inner.md', heading => 'More' }, 'page in a subdirectory' );
    accepted_ok( $f, 'rename_heading', { page => 'sub/inner.md', heading_path => 'Inner', heading => 'Renamed' },
        'page in a subdirectory' );
    accepted_ok( $f, 'delete_section', { page => 'sub/inner.md', heading_path => 'Renamed' }, 'page in a subdirectory' );
};

subtest 'search_pages reads only what list_pages offers' => sub {
    my $f = fixture();
    $f->{wiki}->child('hit.md')->spew_utf8("# Hit\n$SECRET inside\n");

    my ( $result, $text ) = call( $f->{server}, 'search_pages', { query => $SECRET } );
    ok( $result && !$result->{isError}, 'a search succeeds' ) or diag($text);
    is_deeply( [ map { $_->{page} } @{ $result->{structuredContent}{matches} } ], ['hit.md'],
        'it finds the wiki page only, not data.txt, .git, .GIT or the pages outside' );

    for my $prefix ( '../elsewhere', '../wiki-evil', '..', '.git', 'sub/.GIT', 'sub/../../elsewhere', './.git/hooks',
        ( $can_symlink ? ( 'out', 'twin', 'gitlink', 'out/' ) : () ) ) {
        my $text = rejected_ok( $f, 'search_pages', { query => 'secret', prefix => $prefix }, "prefix $prefix" );
    }
    rejected_ok( $f, 'search_pages', { query => 'secret', root_dir => $f->{else}->stringify }, 'foreign root_dir' );
    accepted_ok( $f, 'search_pages', { query => 'inside', prefix => 'sub' }, 'prefix inside the root' );
};

done_testing;
