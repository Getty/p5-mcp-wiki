package MCP::Wiki::Document;
# ABSTRACT: Wiki page document operations

use strict;
use warnings;
use Moo;
use Carp qw( croak );
use Digest::SHA qw( sha256_hex );
use Encode ();
use Path::Tiny;
use MCP::Wiki::TOC::Entry;
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

=method get_toc

    my @entries = $doc->get_toc;

Returns the L<MCP::Wiki::TOC::Parser> entries of the page, each with its
C<hash> (see L</SECTION HASHES>).

=cut

sub get_toc {
    my ($self) = @_;
    my ($text, undef, undef, $bytes) = $self->_read_page;
    my $lines = $self->_raw_lines($bytes);
    return map {
        MCP::Wiki::TOC::Entry->new(%{ $_->as_hash }, hash => $self->_section_hash($lines, $_))
    } MCP::Wiki::TOC::Parser->parse_content($text);
}

=method get_page

    my $page = $doc->get_page;    # { content => ..., hash => ... }

Returns the whole page: C<content> is its text with LF line endings, also on a
CRLF page, and a leading byte order mark kept; C<hash> is the SHA-256 of all
its bytes on disk, see L</SECTION HASHES>.

=cut

sub get_page {
    my ($self) = @_;
    my ($text, undef, undef, $bytes) = $self->_read_page;
    return { content => $text, hash => sha256_hex($bytes) };
}

=method get_paragraph

    my $para = $doc->get_paragraph('Introduction#Background');

Returns the section addressed by C<heading_path> as a hashref (C<heading>,
C<heading_path>, C<content>, C<line_start>, C<line_end>, C<hash>), or nothing when no
such heading exists. C<content> is the body of the section, without its
heading line, always with LF line endings, also on a CRLF page (one whose
first line ends in CRLF).

The heading_path C<""> addresses the preamble, the text before the first
heading, front matter included; a page without any heading is all preamble.
Its C<heading> and C<heading_path> are empty, C<line_start> is 1 and
C<line_end> the last line before the first heading (0 for an empty preamble).
A byte order mark is not part of its C<content>.

=cut

sub get_paragraph {
    my ($self, $heading_path) = @_;
    my ($text, undef, undef, $bytes) = $self->_read_page;

    my $at = $self->_locate($text, $heading_path) or return;

    # The body: the heading line (line_start) is not part of it
    my @lines = split /\n/, $at->{text};
    my $body = join("\n", @lines[$at->{body_from} .. $at->{line_end} - 1]);

    return {
        heading      => $at->{heading},
        heading_path => $heading_path,
        content      => $body,
        line_start   => $at->{line_start},
        line_end     => $at->{line_end},
        hash         => $self->_range_hash($self->_raw_lines($bytes), $at->{line_start}, $at->{line_end}),
    };
}

=method set_paragraph

    my $hash = $doc->set_paragraph('Introduction#Background', $new_body,
        expected_hash => $hash_from_get_paragraph);

Replaces the body of the section, leaving its heading line and every other
section untouched. Takes what L</get_paragraph> returns as C<content>, so the
two are inverse. On a CRLF page the whole page is written back with CRLF line
endings, whichever line endings C<$new_body> uses. Dies, leaving the file
untouched, when the heading does not exist or the page is not valid UTF-8
(see L</read_for_update>).

With C<expected_hash>, the C<hash> an earlier L</get_paragraph> or L</get_toc>
showed for the section, it also dies when the section is not as it was then
("changed since read"). The check and the write work on one read of the page.
Returns the new hash of the section.

=cut

sub set_paragraph {
    my ($self, $heading_path, $new_content, %opt) = @_;
    $self->_valid_expected_hash($opt{expected_hash});
    my ($text, $eol, $bytes) = $self->_snapshot_for_update;

    my $at = $self->_locate($text, $heading_path)
        or die "Heading not found: $heading_path";
    $self->_check_expected_hash($opt{expected_hash},
        $self->_range_hash($self->_raw_lines($bytes), $at->{line_start}, $at->{line_end}),
        $heading_path eq '' ? 'The text before the first heading' : "Section $heading_path");

    # Keep trailing empty fields (-1): the blank line before the next heading
    # and the file's final newline survive a get_paragraph -> set_paragraph trip
    my @new_lines = split /\n/, $at->{text}, -1;

    # The new body joins the page's LF text: CRLF in it would come out as CRCRLF
    $new_content =~ s/\r\n/\n/g if $eol eq "\r\n";

    # Replace the body of the section; the heading line itself stays
    splice @new_lines, $at->{body_from}, $at->{line_end} - $at->{body_from},
        split /\n/, $new_content, -1;

    my $new_text = $at->{bom}.join("\n", @new_lines);
    $self->write_text($new_text, $eol);

    return $self->_hash_of($new_text, $eol, $heading_path);
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
    my ($text, $eol) = $self->_snapshot_for_update;
    return ($text, $eol);
}

# read_for_update plus the page's bytes, for the hashes of the same read
sub _snapshot_for_update {
    my ($self) = @_;
    my ($text, $eol, $utf8, $bytes) = $self->_read_page;
    croak 'Page '.$self->_page_name.' is not valid UTF-8: refusing to write it,'
        .' which would replace its invalid bytes with U+FFFD'
        unless $utf8;
    return ($text, $eol, $bytes);
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

    $text = $self->_encode($text, $eol);

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
    my ($text, $utf8, $bytes) = $self->_slurp;
    my $eol = $text =~ /\A[^\n]*\r\n/ ? "\r\n" : "\n";
    $text =~ s/\r\n/\n/g if $eol eq "\r\n";
    return ($text, $eol, $utf8, $bytes);
}

# The bytes write_text puts on disk for LF text: its LF turned into $eol,
# encoded as UTF-8, the exact inverse of the decode in _slurp.
sub _encode {
    my ($self, $text, $eol) = @_;
    $text =~ s/\n/\r\n/g if $eol eq "\r\n";
    utf8::encode($text);
    return $text;
}

# The one read of the page's bytes. Returns the decoded text, whether the
# bytes are valid UTF-8 (well-formed, no surrogates, nothing above U+10FFFF;
# noncharacters are valid) and the bytes themselves. Valid text comes from utf8::decode, which
# write_text inverts with utf8::encode, so an unchanged page is written back
# byte for byte. Anything else is decoded leniently, every malformed sequence
# becoming U+FFFD: readable, but never to be written back.
sub _slurp {
    my ($self) = @_;
    my $bytes = Path::Tiny::path($self->file_path)->slurp_raw;
    my $text  = $bytes;
    return ($text, 1, $bytes)
        if utf8::decode($text) && $text !~ /[\x{D800}-\x{DFFF}]|[^\x{0}-\x{10FFFF}]/;
    return (Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT | Encode::LEAVE_SRC), 0, $bytes);
}

# The lines of a page's bytes, each with its line terminator as on disk. The
# i-th element is line i of the parsed text: reading CRLF as LF and cutting at
# every LF leave the line count alone.
sub _raw_lines {
    my ($self, $bytes) = @_;
    return [ $bytes =~ /[^\n]*\n|[^\n]+/g ];
}

# Where the section is: a hashref with its heading ('' for the preamble),
# line_start and line_end (1-based, inclusive, the heading line included),
# body_from (index of the first body line in the lines of "text"), the "text"
# those lines come from and the "bom" that text lost, or nothing when there is
# no such section. The preamble, heading_path "", runs from line 1 to the line
# before the first heading, or to the last line of a page without headings; as
# its text starts the page, a byte order mark is cut from it and handed back
# in "bom", for the caller to put in front again.
sub _locate {
    my ($self, $text, $heading_path) = @_;

    if ($heading_path eq '') {
        my ($first) = MCP::Wiki::TOC::Parser->parse_content($text);
        my $bom  = $text =~ s/\A\x{FEFF}// ? "\x{FEFF}" : '';
        my @all  = split /\n/, $text;
        my $last = $first ? $first->line_start - 1 : scalar @all;
        return { heading => '', line_start => 1, line_end => $last, body_from => 0,
            text => $text, bom => $bom };
    }

    my $entry = $self->_find_entry($text, $heading_path) or return;
    return { heading => $entry->heading, line_start => $entry->line_start,
        line_end => $entry->line_end, body_from => $entry->line_start, text => $text, bom => '' };
}

# The hash of a section: SHA-256 over the bytes of its lines on disk, from the
# heading line to its line_end, which is the range set_paragraph replaces
# (plus the heading).
sub _section_hash {
    my ($self, $lines, $entry) = @_;
    return $self->_range_hash($lines, $entry->line_start, $entry->line_end);
}

# The hash of lines $from to $to (1-based, inclusive) of the raw lines.
sub _range_hash {
    my ($self, $lines, $from, $to) = @_;
    return sha256_hex(join '', @{$lines}[$from - 1 .. $to - 1]);
}

# The hash a section has in LF text that is written with $eol, found by its
# heading_path; nothing when the text has no such section.
sub _hash_of {
    my ($self, $text, $eol, $heading_path) = @_;
    my $at = $self->_locate($text, $heading_path) or return;
    return $self->_range_hash($self->_raw_lines($self->_encode($text, $eol)),
        $at->{line_start}, $at->{line_end});
}

sub _valid_expected_hash {
    my ($self, $expected) = @_;
    return unless defined $expected;
    croak 'expected_hash must be a SHA-256 as 64 hex characters, as get_toc and'
        .' get_paragraph show it'
        unless !ref $expected && $expected =~ /\A[0-9a-fA-F]{64}\z/;
    return;
}

# Dies when the hash the caller read is not the hash of what is on disk now.
sub _check_expected_hash {
    my ($self, $expected, $actual, $what) = @_;
    return unless defined $expected;
    croak $what.' changed since read: its hash is not the expected one, nothing was'
        .' written. Read it again and redo the change.'
        unless lc $expected eq $actual;
    return;
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

=head1 SECTION HASHES

The C<hash> of a section is the SHA-256, as lower-case hex, of its bytes as
they are on disk: the lines from its heading line to the line before the next
heading, each with its line ending, so a CRLF page hashes its CRLFs and a final
newline counts. That is the heading line plus the range L</set_paragraph>
replaces. Subsections are not part of it. It is meant for optimistic
concurrency: whoever read a section passes its hash back as C<expected_hash>
and the write is refused when the section changed meanwhile. The check and the
write use one read of the page, but the document takes no lock: a change
landing between that read and the write is not seen.

=head1 SYNOPSIS

    use MCP::Wiki::Document;

    my $doc = MCP::Wiki::Document->new(
        file_path => '/wiki/example.md',
        wiki_root => '/wiki',
    );

    my @toc = $doc->get_toc;
    my $para = $doc->get_paragraph('Introduction#Background');

=cut