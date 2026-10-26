package MCP::Wiki::TOC::Entry;
# ABSTRACT: Single TOC entry with heading path and line range

our $VERSION = '0.002';

use Moo;
use namespace::clean;

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

GitHub-style anchor derived from the heading: lower case, everything except
letters (any script), digits, spaces, C<-> and C<_> dropped, each space a
C<->. The second and later equal anchor of a page gets C<-1>, C<-2> ...

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

The first 100 characters of the section, heading line included, followed by
C<...> when the section is longer.

=cut
has content_preview => (
    is => 'ro',
    required => 1,
);

=attr char_count

Number of characters in the section, heading line included.

=cut
has char_count => (
    is => 'ro',
    required => 1,
);

=attr hash

Optional. SHA-256 of the section's bytes as they are on disk, as lower-case
hex: its heading line and everything up to the line before the next heading,
line endings included. The parser knows nothing about bytes and leaves it
empty; L<MCP::Wiki::Document> fills it in.

=cut
has hash => (
    is => 'ro',
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
        (defined $self->hash ? (hash => $self->hash) : ()),
    };
}

=method as_hash

    my $hash = $entry->as_hash;

Returns the entry as a plain hashref with the keys C<level>, C<heading>,
C<anchor>, C<heading_path>, C<line_start>, C<line_end>, C<content_preview>
and C<char_count>, each holding the attribute of that name, plus C<hash> when
the entry has one. This is the wire
form of a TOC entry: the C<get_toc> tool of L<MCP::Wiki::Server> answers with
a list of these.

Both C<content_preview> and C<char_count> cover the section with its heading
line, its lines joined by LF and without a final newline. C<char_count>
counts characters, not bytes; C<content_preview> is the first 100 of them,
followed by C<...> when the section is longer.

=cut

1;