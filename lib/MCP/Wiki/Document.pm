package MCP::Wiki::Document;
# ABSTRACT: Wiki page document operations

use strict;
use warnings;
use Moo;
use Carp qw( croak );
use Encode ();
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

Required. Root directory of the wiki. The document uses it only to name the
page in error messages and does no path validation of its own: it works on
C<file_path> as given. Keeping that path inside the wiki is the caller's job;
L<MCP::Wiki::Server> resolves every page name before it builds a document.

=cut
has wiki_root => (
    is => 'ro',
    required => 1,
);

=method content

    my $text = $doc->content;

Returns the page decoded as UTF-8, as it is on disk. A page that is not valid
UTF-8 can still be read: every malformed byte sequence comes back as U+FFFD.

=cut

sub content {
    my ($self) = @_;
    my ($text) = $self->_slurp;
    return $text;
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
endings, whichever line endings C<$new_body> uses. Dies, leaving the file
untouched, when the heading does not exist or the page is not valid UTF-8
(see L</read_for_update>).

=cut

sub set_paragraph {
    my ($self, $heading_path, $new_content) = @_;
    my ($text, $eol) = $self->read_for_update;

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

    $self->write_text(join("\n", @new_lines), $eol);

    return 1;
}

=method read_for_update

    my ($text, $eol) = $doc->read_for_update;

Reads the page once for a change: returns its text with LF line endings and
the line ending to hand to L</write_text> (C<"\r\n"> for a CRLF page, else
C<"\n">). Dies when the page is not valid UTF-8: its text has lost the bytes
U+FFFD stands for, so writing it back would destroy them.

=cut

sub read_for_update {
    my ($self) = @_;
    my ($text, $eol, $utf8) = $self->_read_page;
    croak 'Page '.$self->_page_name.' is not valid UTF-8: refusing to write it,'
        .' which would replace its invalid bytes with U+FFFD'
        unless $utf8;
    return ($text, $eol);
}

=method write_text

    $doc->write_text($text, $eol);

Replaces the page with C<$text>, text with LF line endings as
L</read_for_update> returns it, written as UTF-8 with every LF turned into
C<$eol>. The page keeps its permission bits. Dies, leaving the page as it
is, when the page is read-only. Every write of a document goes through here.

=cut

sub write_text {
    my ($self, $text, $eol) = @_;
    my $page = Path::Tiny::path($self->file_path);

    # spew renames a new file over the page, which works whatever the page's
    # mode: a page we may not write has to be refused here
    my $mode = (stat $page)[2];
    croak 'Page '.$self->_page_name.' is read-only: refusing to write it'
        if defined $mode && !-w _;

    $text =~ s/\n/\r\n/g if $eol eq "\r\n";
    utf8::encode($text);    # the exact inverse of the decode in _slurp

    # Under umask 077 the new file starts out owner-only, so it is never
    # readable by more than the page was while it takes its place; then it
    # gets the page's mode back. A page gone since it was read is written anew.
    my $umask   = defined $mode ? umask 077 : undef;
    my $written = eval { $page->spew_raw($text); 1 };
    umask $umask if defined $umask;
    die $@ unless $written;

    if (defined $mode) {
        chmod $mode & 07777, "$page"
            or croak 'Page '.$self->_page_name.' was written, but its mode could not be restored: '.$!;
    }

    return 1;
}

# One read of the page per operation: returns the text every section
# operation works on, the line ending the page is written back with, and
# whether the page is valid UTF-8. A page whose first line ends in CRLF is a
# CRLF page: its CRLFs become LF here and LF again becomes CRLF in write_text.
# Every other page (no newline at all included) is used exactly as read and
# written with LF.
sub _read_page {
    my ($self) = @_;
    my ($text, $utf8) = $self->_slurp;
    my $eol = $text =~ /\A[^\n]*\r\n/ ? "\r\n" : "\n";
    $text =~ s/\r\n/\n/g if $eol eq "\r\n";
    return ($text, $eol, $utf8);
}

# The one read of the page's bytes. Returns the decoded text and whether the
# bytes are valid UTF-8 (well-formed, no surrogates, nothing above U+10FFFF;
# noncharacters are valid). Valid text comes from utf8::decode, which
# write_text inverts with utf8::encode, so an unchanged page is written back
# byte for byte. Anything else is decoded leniently, every malformed sequence
# becoming U+FFFD: readable, but never to be written back.
sub _slurp {
    my ($self) = @_;
    my $bytes = Path::Tiny::path($self->file_path)->slurp_raw;
    my $text  = $bytes;
    return ($text, 1)
        if utf8::decode($text) && $text !~ /[\x{D800}-\x{DFFF}]|[^\x{0}-\x{10FFFF}]/;
    return (Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT | Encode::LEAVE_SRC), 0);
}

# The page as the wiki names it, for error messages. The Server hands in the
# path as on disk, in bytes; utf8::decode turns a name that is valid UTF-8 into
# text and leaves any other one as it is, a name given as text included.
sub _page_name {
    my ($self) = @_;
    my $name = Path::Tiny::path($self->file_path)->relative($self->wiki_root)->stringify;
    utf8::decode($name);
    return $name;
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