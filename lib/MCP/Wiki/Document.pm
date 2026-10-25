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
    my ($text) = $self->_read_page;
    return MCP::Wiki::TOC::Parser->parse_content($text);
}

=method get_paragraph

    my $para = $doc->get_paragraph('Introduction#Background');

Returns the section addressed by C<heading_path> as a hashref (C<heading>,
C<heading_path>, C<content>, C<line_start>, C<line_end>), or nothing when no
such heading exists. C<content> is the body of the section, without its
heading line, always with LF line endings, also on a CRLF page (one whose
first line ends in CRLF).

=cut

sub get_paragraph {
    my ($self, $heading_path) = @_;
    my ($text) = $self->_read_page;

    my $entry = $self->_find_entry($text, $heading_path);
    return unless $entry;

    # The section is the body: the heading line (line_start) is not part of it
    my @lines = split /\n/, $text;
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
two are inverse. On a CRLF page the whole page is written back with CRLF line
endings, whichever line endings C<$new_body> uses. Dies when the heading does
not exist.

=cut

sub set_paragraph {
    my ($self, $heading_path, $new_content) = @_;
    my ($text, $eol) = $self->_read_page;

    my $entry = $self->_find_entry($text, $heading_path);
    unless ($entry) {
        die "Heading not found: $heading_path";
    }

    # Keep trailing empty fields (-1): the blank line before the next heading
    # and the file's final newline survive a get_paragraph -> set_paragraph trip
    my @new_lines = split /\n/, $text, -1;

    # The new body joins the page's LF text: CRLF in it would come out as CRCRLF
    $new_content =~ s/\r\n/\n/g if $eol eq "\r\n";

    # Replace the body of the section; the heading line itself stays
    splice @new_lines, $entry->line_start, $entry->line_end - $entry->line_start,
        split /\n/, $new_content, -1;

    $self->_write_page(join("\n", @new_lines), $eol);

    return 1;
}

# One read of the page per operation: returns the text every section
# operation works on and the line ending the page is written back with.
# A page whose first line ends in CRLF is a CRLF page: its CRLFs become LF
# here and LF again becomes CRLF in _write_page. Every other page (no newline
# at all included) is used exactly as read and written with LF.
sub _read_page {
    my ($self) = @_;
    my $text = $self->content;
    my $eol  = $text =~ /\A[^\n]*\r\n/ ? "\r\n" : "\n";
    $text =~ s/\r\n/\n/g if $eol eq "\r\n";
    return ($text, $eol);
}

# Writes text produced by _read_page and the section operations back to the
# page, restoring the line ending _read_page found.
sub _write_page {
    my ($self, $text, $eol) = @_;
    $text =~ s/\n/\r\n/g if $eol eq "\r\n";
    Path::Tiny::path($self->file_path)->spew_utf8($text);
    return;
}

# The entry's line range is only valid for the text it was parsed from:
# callers read the page once and cut that same string, never a second read.
sub _find_entry {
    my ($self, $content, $heading_path) = @_;
    my ($entry) = grep { $_->heading_path eq $heading_path }
        MCP::Wiki::TOC::Parser->parse_content($content);
    return $entry;
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