package MCP::Wiki::Document;
# ABSTRACT: Wiki page document operations

use strict;
use warnings;
use Moo;
use Path::Tiny;
use MCP::Wiki::TOC::Parser;

=attr file_path

Required. Path to the markdown file the document reads and writes.

=cut
has file_path => (
    is => 'ro',
    required => 1,
);

=attr wiki_root

Required. Root directory of the wiki. The document does not read it and does
no path validation of its own: it works on C<file_path> as given. Keeping
that path inside the wiki is the caller's job; L<MCP::Wiki::Server> resolves
every page name before it builds a document.

=cut
has wiki_root => (
    is => 'ro',
    required => 1,
);

sub content {
    my ($self) = @_;
    return Path::Tiny::path($self->file_path)->slurp_utf8;
}

sub get_toc {
    my ($self) = @_;
    return MCP::Wiki::TOC::Parser->parse_content($self->content);
}

=method get_paragraph

    my $para = $doc->get_paragraph('Introduction#Background');

Returns the section addressed by C<heading_path> as a hashref (C<heading>,
C<heading_path>, C<content>, C<line_start>, C<line_end>), or nothing when no
such heading exists. C<content> is the body of the section, without its
heading line.

=cut

sub get_paragraph {
    my ($self, $heading_path) = @_;
    my @entries = $self->get_toc;

    # Find entry by heading_path
    my ($entry) = grep { $_->heading_path eq $heading_path } @entries;
    return unless $entry;

    # The section is the body: the heading line (line_start) is not part of it
    my @lines = split /\n/, $self->content;
    my $section = join("\n", @lines[$entry->line_start .. $entry->line_end - 1]);

    return {
        heading      => $entry->heading,
        heading_path => $entry->heading_path,
        content      => $section,
        line_start   => $entry->line_start,
        line_end     => $entry->line_end,
    };
}

=method set_paragraph

    $doc->set_paragraph('Introduction#Background', $new_body);

Replaces the body of the section, leaving its heading line and every other
section untouched. Takes what L</get_paragraph> returns as C<content>, so the
two are inverse. Dies when the heading does not exist.

=cut

sub set_paragraph {
    my ($self, $heading_path, $new_content) = @_;
    my @entries = $self->get_toc;

    my ($entry) = grep { $_->heading_path eq $heading_path } @entries;
    unless ($entry) {
        die "Heading not found: $heading_path";
    }

    # Keep trailing empty fields (-1): the blank line before the next heading
    # and the file's final newline survive a get_paragraph -> set_paragraph trip
    my @new_lines = split /\n/, $self->content, -1;

    # Replace the body of the section; the heading line itself stays
    splice @new_lines, $entry->line_start, $entry->line_end - $entry->line_start,
        split /\n/, $new_content, -1;

    Path::Tiny::path($self->file_path)->spew_utf8(join("\n", @new_lines));

    return 1;
}

1;

__END__

=head1 SYNOPSIS

    use MCP::Wiki::Document;

    my $doc = MCP::Wiki::Document->new(
        file_path => '/wiki/example.md',
        wiki_root => '/wiki',
    );

    my @toc = $doc->get_toc;
    my $para = $doc->get_paragraph('Introduction#Background');

=cut