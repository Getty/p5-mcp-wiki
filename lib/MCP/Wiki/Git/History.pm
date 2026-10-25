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
# It is the LF text Document::_read_page works on: a page whose first line
# ends in CRLF has its CRLFs turned into LF, any other page is used as it is.
sub _page_text_at {
    my ($self, $commit, $page) = @_;

    my $entry = $commit->tree->entry_bypath(encode('UTF-8', $page)) or return;
    my $blob = $entry->object;
    return unless $blob->is_blob;

    my $text = decode('UTF-8', $blob->content);
    $text =~ s/\r\n/\n/g if $text =~ /\A[^\n]*\r\n/;
    return $text;
}

# The repository's configured identity, or MCP::Wiki's own: a commit must not
# fail because no user.name is set.
sub _signature {
    my ($self) = @_;
    return eval { Git::Raw::Signature->default($self->repo) }
        // Git::Raw::Signature->now('MCP::Wiki', 'mcp-wiki@localhost');
}

# The section's TOC entry in the page as of $commit, and its text: the heading
# line and what follows up to the blank lines that end the section, which is
# what restore_section brings back. Nothing when the page or heading is absent.
sub _section_at {
    my ($self, $commit, $page, $heading_path) = @_;

    my $content = $self->_page_text_at($commit, $page);
    return unless defined $content;

    my ($entry) = grep { $_->heading_path eq $heading_path }
        $self->_get_parser->parse_content($content);
    return unless $entry;

    my @lines = (split /\n/, $content)[$entry->line_start - 1 .. $entry->line_end - 1];
    my ($text) = $self->_split_trailing_blank_lines(@lines);

    return ($entry, join("\n", @$text));
}

=method get_section_commits

    my @commits = $git->get_section_commits('page.md', 'Introduction#Background');

Walks the history from HEAD, newest first, and returns one hashref per commit
that created or changed the section: the page has a section with that heading
path there, and the first parent has none or one with a different text (heading
line and text up to the blank lines that end the section, which a restore
brings back). Commits touching other pages or other sections are left out.
Each hashref holds C<hash>, C<message>, C<author>, C<email>, C<time>,
C<heading>, C<line_start>, C<line_end>. Returns nothing while the branch has no
commits. Dies when the page does not exist in the working tree.

=cut
sub get_section_commits {
    my ($self, $page, $heading_path) = @_;

    my $repo = $self->repo;
    # On disk the name is bytes, like the root
    my $page_path = Path::Tiny::path($self->wiki_root)->child(encode('UTF-8', $page));

    die "File not found: $page" unless -e $page_path;

    # Walk commit history for this file
    my @commits;
    my $head = $self->_head_commit or return;
    my $walker = $repo->walker;
    $walker->push($head);

    while (my $commit = $walker->next) {
        my ($heading_entry, $text) = $self->_section_at($commit, $page, $heading_path);
        next unless $heading_entry;

        # Listed only where the section is new or its text differs from the
        # first parent's
        my ($parent) = $commit->parents;
        if ($parent) {
            my (undef, $before) = $self->_section_at($parent, $page, $heading_path);
            next if defined $before && $before eq $text;
        }

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
section including its heading line, and the blank lines that ended it, as LF
text), C<heading>, C<line_start>, C<line_end>.
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

C<current_content> is LF text, as L<MCP::Wiki::Document> reads a page, and
C<content> is LF text too; the historic page is read with the same line-ending
rule. Everything outside the section comes back byte for byte, the final
newline and blank lines at the end of the page included. The blank lines that
end the section, between its text and the next heading, stay as they are now:
only the heading line and the text before them are restored.

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

    # Split with -1: the final newline and blank lines at the end of the page
    # are trailing empty fields, and the join has to give them back
    my @lines = split /\n/, $current_content, -1;
    my $start = $current_entry->line_start - 1;
    my @current = @lines[$start .. $current_entry->line_end - 1];

    # The restored text, followed by the blank lines that end the section now
    my ($restored) = $self->_split_trailing_blank_lines(split /\n/, $hist->{content}, -1);
    my (undef, $gap) = $self->_split_trailing_blank_lines(@current);
    splice @lines, $start, scalar @current, @$restored, @$gap;

    my $new_content = join("\n", @lines);

    return {
        success       => 1,
        content       => $new_content,
        restored_from => $commit_hash,
        heading       => $heading_path,
    };
}

# Splits a section's lines into its text and the blank lines that end it; a
# section's heading line is never blank, so the text is never empty.
sub _split_trailing_blank_lines {
    my ($self, @lines) = @_;
    my @blank;
    unshift @blank, pop @lines while @lines && $lines[-1] !~ /\S/;
    return (\@lines, \@blank);
}

sub _get_parser {
    require MCP::Wiki::TOC::Parser;
    return 'MCP::Wiki::TOC::Parser';
}

=method auto_commit

    $git->auto_commit('page.md', 'Fix typo in introduction', reason => 'User reported typo');
    $git->auto_commit([ 'old.md', 'new/name.md' ], 'Renamed page');

Stages the path, or each path in an array reference, as the working tree has
it: a file that exists is added, one that is gone is removed from the index.
A rename therefore stages both names, a delete the deleted one. Then it
commits the index on top of HEAD; on a branch without commits it makes the
first one. The commit message is the C<reason> when one with visible text is
given, else C<$message>; never both. Author and
committer are the repository's configured identity, or
C<< MCP::Wiki <mcp-wiki@localhost> >> when none is set. Returns
C<< { success => 1, hash => $id, message => $commit_message } >>, or
C<< { success => 0, message => 'No changes to commit' } >> when the index
matches HEAD. Dies on any git error.

=cut
sub auto_commit {
    my ($self, $paths, $message, %opts) = @_;

    # A reason, when given, is the whole commit message
    my $reason = $opts{reason};
    my $commit_message = defined $reason && $reason =~ /\S/ ? $reason : $message;

    my $repo = $self->repo;
    my $index = $repo->index;
    $index->read;

    # Stage each path as the working tree has it, then turn the index into
    # the tree to commit
    my $root = Path::Tiny::path($self->wiki_root);
    for my $path (ref $paths eq 'ARRAY' ? @$paths : $paths) {
        die "auto_commit needs a path" unless defined $path && length $path;
        my $file = $root->child(encode('UTF-8', $path));
        if (-e $file || -l $file) {
            $index->add(encode('UTF-8', $path));
        }
        else {
            $index->remove(encode('UTF-8', $path));
        }
    }
    $index->write;
    my $tree = $index->write_tree;

    # HEAD is the parent; on an unborn branch there is none
    my $parent = $self->_head_commit;
    if ($parent && $parent->tree->id eq $tree->id) {
        return { success => 0, message => 'No changes to commit' };
    }

    # Create commit
    my $author = $self->_signature;

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
nothing about sections is recorded in git. Page text is UTF-8, and a page
from history is read with L<MCP::Wiki::Document>'s line-ending rule: a CRLF
page becomes LF text.

=cut