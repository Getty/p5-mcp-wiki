package MCP::Wiki::Git::History;
# ABSTRACT: Section history tracking via heading paths

use strict;
use warnings;
use Moo;
use Path::Tiny;
use Encode qw( decode encode );

=attr wiki_root

Root directory of the wiki (must be a git repo)

=cut
has wiki_root => (
    is => 'ro',
    required => 1,
);

=attr repo

Git::Raw repository object

=cut
has repo => (
    is => 'lazy',
);

sub _build_repo {
    my ($self) = @_;
    my $git_dir = $self->wiki_root . '/.git';

    die "Not a git repository: $git_dir" unless -d $git_dir;
    die "Git::Raw is required for git history" unless eval { require Git::Raw; 1 };

    return Git::Raw::Repository->open($self->wiki_root);
}

# Git::Raw takes and returns bytes. Strings cross that boundary encoded as
# UTF-8 on the way in and decoded on the way out, so everything on this side
# is characters: heading paths match, and nothing is encoded twice.

# The commit HEAD points to, or nothing on an unborn branch (no commits yet).
sub _head_commit {
    my ($self) = @_;

    my $head = eval { $self->repo->head };
    unless ($head) {
        my $err = $@;
        return if ref $err eq 'Git::Raw::Error' && $err->code == Git::Raw::Error->EUNBORNBRANCH;
        die $err;
    }

    return $head->peel('commit');
}

# The page's text as of $commit, or nothing when the commit has no such file.
sub _page_text_at {
    my ($self, $commit, $page) = @_;

    my $entry = $commit->tree->entry_bypath(encode('UTF-8', $page)) or return;
    my $blob = $entry->object;
    return unless $blob->is_blob;

    return decode('UTF-8', $blob->content);
}

# The repository's configured identity, or MCP::Wiki's own: a commit must not
# fail because no user.name is set.
sub _signature {
    my ($self) = @_;
    return eval { Git::Raw::Signature->default($self->repo) }
        // Git::Raw::Signature->now('MCP::Wiki', 'mcp-wiki@localhost');
}

=method get_section_commits

    my @commits = $git->get_section_commits('page.md', 'Introduction#Background');

Walks the history from HEAD, newest first, and returns one hashref per commit
in which the page has a section with that heading path: C<hash>, C<message>,
C<author>, C<email>, C<time>, C<heading>, C<line_start>, C<line_end>. Returns
nothing while the branch has no commits. Dies when the page does not exist in
the working tree.

=cut
sub get_section_commits {
    my ($self, $page, $heading_path) = @_;

    my $repo = $self->repo;
    my $page_path = Path::Tiny::path($self->wiki_root)->child($page);

    die "File not found: $page" unless -e $page_path;

    # Walk commit history for this file
    my @commits;
    my $head = $self->_head_commit or return;
    my $walker = $repo->walker;
    $walker->push($head);

    while (my $commit = $walker->next) {
        # Try to find the file in this commit
        my $content = $self->_page_text_at($commit, $page);
        next unless defined $content;

        # Parse TOC to find if heading_path exists
        my $parser = $self->_get_parser;
        my @toc = $parser->parse_content($content);

        my ($heading_entry) = grep { $_->heading_path eq $heading_path } @toc;
        next unless $heading_entry;

        push @commits, {
            hash       => $commit->id,
            message    => decode('UTF-8', $commit->message),
            author     => decode('UTF-8', $commit->author->name),
            email      => decode('UTF-8', $commit->author->email),
            time       => $commit->time,
            heading    => $heading_entry->heading,
            line_start => $heading_entry->line_start,
            line_end   => $heading_entry->line_end,
        };
    }

    return @commits;
}

=method get_section_content_at_commit

    my $section = $git->get_section_content_at_commit(
        'page.md',
        'Introduction#Background',
        'abc123def456'
    );

Returns the section as it was in that commit, as a hashref: C<content> (the
section including its heading line), C<heading>, C<line_start>, C<line_end>.
The commit may be given by an abbreviated hash. Dies when the commit, the page
in it or the heading in that page does not exist.

=cut
sub get_section_content_at_commit {
    my ($self, $page, $heading_path, $commit_hash) = @_;

    my $repo = $self->repo;
    my $commit = Git::Raw::Commit->lookup($repo, $commit_hash);

    die "Commit not found: $commit_hash" unless $commit;

    my $content = $self->_page_text_at($commit, $page);
    die "File not in commit: $page" unless defined $content;

    # Find the section
    my $parser = $self->_get_parser;
    my @toc = $parser->parse_content($content);

    my ($heading_entry) = grep { $_->heading_path eq $heading_path } @toc;
    die "Heading not found: $heading_path" unless $heading_entry;

    # Extract section content
    my @lines = split /\n/, $content;
    my $section = join("\n", @lines[$heading_entry->line_start - 1 .. $heading_entry->line_end - 1]);

    return {
        content     => $section,
        heading     => $heading_entry->heading,
        line_start  => $heading_entry->line_start,
        line_end    => $heading_entry->line_end,
    };
}

=method restore_section

    my $result = $git->restore_section(
        'page.md',
        'Introduction#Background',
        'abc123def456',
        { current_content => $current_md },
    );

Replaces the section in C<current_content> with the section as it was in that
commit and returns
C<< { success => 1, content => $new_document, restored_from => $hash, heading => $heading_path } >>.
C<content> is the whole document; nothing is written or committed. Dies when
C<current_content> is missing or empty, when the heading does not exist in it,
and in every case L</get_section_content_at_commit> dies.

=cut
sub restore_section {
    my ($self, $page, $heading_path, $commit_hash, $opts) = @_;

    my $hist = $self->get_section_content_at_commit($page, $heading_path, $commit_hash);

    my $current_content = $opts->{current_content}
        or die "current_content required for restore";

    # Get current TOC and the section we want to restore
    my $parser = $self->_get_parser;
    my @current_toc = $parser->parse_content($current_content);

    my ($current_entry) = grep { $_->heading_path eq $heading_path } @current_toc;
    die "Heading not found in current content: $heading_path" unless $current_entry;

    # Build new content with restored section
    my @lines = split /\n/, $current_content;
    splice @lines, $current_entry->line_start - 1, $current_entry->line_end - $current_entry->line_start + 1,
        split /\n/, $hist->{content};

    my $new_content = join("\n", @lines);

    return {
        success       => 1,
        content       => $new_content,
        restored_from => $commit_hash,
        heading       => $heading_path,
    };
}

sub _get_parser {
    require MCP::Wiki::TOC::Parser;
    return 'MCP::Wiki::TOC::Parser';
}

=method auto_commit

    $git->auto_commit('page.md', 'Fix typo in introduction', reason => 'User reported typo');

Stages the file, which must exist in the working tree, and commits the index
on top of HEAD; on a branch without commits it makes the first one. Author and
committer are the repository's configured identity, or
C<< MCP::Wiki <mcp-wiki@localhost> >> when none is set. Returns
C<< { success => 1, hash => $id, message => $commit_message } >>, or
C<< { success => 0, message => 'No changes to commit' } >> when the index
matches HEAD. Dies on any git error.

=cut
sub auto_commit {
    my ($self, $file_path, $message, %opts) = @_;

    my $reason = $opts{reason};
    my $final_message = $reason // $message;

    my $repo = $self->repo;
    my $index = $repo->index;
    $index->read;

    # Stage the file and turn the index into the tree to commit
    $index->add(encode('UTF-8', $file_path));
    $index->write;
    my $tree = $index->write_tree;

    # HEAD is the parent; on an unborn branch there is none
    my $parent = $self->_head_commit;
    if ($parent && $parent->tree->id eq $tree->id) {
        return { success => 0, message => 'No changes to commit' };
    }

    # Create commit
    my $author = $self->_signature;
    my $commit_message = $reason ? "$final_message\n\nReason: $reason" : $final_message;

    # Without an update_ref argument, Commit->create moves HEAD (and so the
    # branch it points to) to the new commit
    my $new_commit = Git::Raw::Commit->create(
        $repo,
        encode('UTF-8', $commit_message),
        $author,
        $author,
        [ $parent // () ],
        $tree,
    );

    return {
        success => 1,
        hash    => $new_commit->id,
        message => $commit_message,
    };
}

1;

__END__

=head1 SYNOPSIS

    use MCP::Wiki::Git::History;

    my $git = MCP::Wiki::Git::History->new(wiki_root => '/path/to/wiki');

    # Get section history
    my @commits = $git->get_section_commits('page.md', 'Intro#Background');

    # Restore section from old commit
    my $result = $git->restore_section(
        'page.md',
        'Intro#Background',
        'abc123',
        { current_content => $current_md }
    );

=head1 DESCRIPTION

Reads and writes a wiki's history in the git repository at C<wiki_root>
through L<Git::Raw>, which is loaded on first use. A section is found in each
commit by its heading path: the page as it was in that commit is parsed again,
nothing about sections is recorded in git. Page text is UTF-8.

=cut