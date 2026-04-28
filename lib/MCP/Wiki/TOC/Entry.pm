package MCP::Wiki::TOC::Entry;
# ABSTRACT: Single TOC entry with heading path and line range

use Moo;
use Types::Standard qw( Int Str Maybe );

=attr level

Heading level (1-6)

=cut
has level => (
    is => 'ro',
    required => 1,
);

=attr heading

The heading text without the # prefix

=cut
has heading => (
    is => 'ro',
    required => 1,
);

=attr anchor

URL-safe anchor (derived from heading)

=cut
has anchor => (
    is => 'ro',
    required => 1,
);

=attr heading_path

Full path of nested headings (e.g. "Introduction#Background")

=cut
has heading_path => (
    is => 'ro',
    required => 1,
);

=attr line_start

Starting line number (1-indexed, inclusive)

=cut
has line_start => (
    is => 'ro',
    required => 1,
);

=attr line_end

Ending line number (1-indexed, inclusive)

=cut
has line_end => (
    is => 'ro',
    required => 1,
);

=attr content_preview

First ~100 chars of the section content

=cut
has content_preview => (
    is => 'ro',
    required => 1,
);

=attr char_count

Total character count of the section

=cut
has char_count => (
    is => 'ro',
    required => 1,
);

sub as_hash {
    my ($self) = @_;
    return {
        level           => $self->level,
        heading         => $self->heading,
        anchor          => $self->anchor,
        heading_path    => $self->heading_path,
        line_start      => $self->line_start,
        line_end        => $self->line_end,
        content_preview=> $self->content_preview,
        char_count      => $self->char_count,
    };
}

1;