package MCP::Wiki::Git;
# ABSTRACT: Git integration for wiki page history

use strict;
use warnings;
use Moo;
use Path::Tiny;

=attr wiki_root

Root directory of the wiki (must be a git repo)

=cut
has wiki_root => (
    is => 'ro',
    required => 1,
);

=attr repo

Path to the git repository

=cut
has repo => (
    is => 'lazy',
);

sub _build_repo {
    my ($self) = @_;
    my $git_dir = $self->wiki_root . '/.git';

    die "Not a git repository: $git_dir" unless -d $git_dir;

    # Try to load Git::Raw
    eval { require Git::Raw };
    if ($@) {
        die "Git::Raw is required for git integration: $@";
    }

    return Git::Raw::Repository->open($self->wiki_root);
}

sub auto_commit {
    my ($self, $file_path, $message) = @_;

    my $repo = $self->repo;
    my $index = $repo->index;
    $index->read;

    $index->add($file_path);
    $index->write;

    my $author = Git::Raw::Signature->now('MCP::Wiki', 'mcp-wiki@localhost');
    $repo->create_commit(
        $repo->head->target->id,
        $author,
        $author,
        $message,
        $repo->head->target->tree->id,
        [$index->get($file_path)],
    );

    return 1;
}

sub get_head_hash {
    my ($self) = @_;
    return $self->repo->head->target->id;
}

1;

__END__

=head1 SYNOPSIS

    use MCP::Wiki::Git;

    my $git = MCP::Wiki::Git->new(wiki_root => '/path/to/wiki');
    $git->auto_commit('example.md', 'Update example page');

=head1 DESCRIPTION

Git integration for wiki pages. Provides auto-commit functionality and
access to git history for section tracking.

Requires L<Git::Raw>.

=cut