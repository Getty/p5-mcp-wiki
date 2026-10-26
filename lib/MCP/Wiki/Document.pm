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
(see L</read_for_update>), and when C<$new_body> would change the structure of
the page: it holds a heading line, or leaves a code fence or an HTML comment
open (see L<MCP::Wiki::TOC::Parser/body_problem>; a heading inside a closed
fence is fine). Sections are added with L</add_section> instead.

With C<expected_hash>, the C<hash> an earlier L</get_paragraph> or L</get_toc>
showed for the section, it also dies when the section is not as it was then
("changed since read"). The check and the write work on one read of the page.
Returns the new hash of the section.

=cut

sub set_paragraph {
    my ($self, $heading_path, $new_content, %opt) = @_;
    $self->_valid_expected_hash($opt{expected_hash});
    $self->_check_body($new_content =~ s/\r\n/\n/gr, front_matter => $heading_path eq '');
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

=method set_page

    my $hash = $doc->set_page($text, expected_hash => $page_hash);

Replaces the whole page with C<$text> (LF line endings; on a CRLF page it is
written with CRLF) and returns the new hash of the page. With C<expected_hash>,
the C<hash> L</get_page> showed, it dies instead when the page is not as it was
then, and writes nothing. Dies, leaving the page as it is, when the page is not
valid UTF-8 (see L</read_for_update>).

=cut

sub set_page {
    my ($self, $content, %opt) = @_;
    croak 'Page content required' unless defined $content && !ref $content;
    $self->_valid_expected_hash($opt{expected_hash});
    my ($text, $eol, $bytes) = $self->_snapshot_for_update;
    $self->_check_expected_hash($opt{expected_hash}, sha256_hex($bytes), 'The page');

    $content =~ s/\r\n/\n/g if $eol eq "\r\n";
    $self->write_text($content, $eol);
    return sha256_hex($self->_encode($content, $eol));
}

=method add_section

    my $new = $doc->add_section(
        heading => 'Faq', content => $body, parent => 'Guide', before => 'Guide#Usage',
    );
    # { heading_path => 'Guide#Faq', level => 2, hash => ... }

Inserts a new section: a heading of the level below its C<parent> (a
C<heading_path>; empty or missing is the top level, level 1) and the optional
C<content> as its body. Without C<before> it becomes the last child of
C<parent>, after the whole subtree of the parent; C<before> is the
C<heading_path> of a direct child of C<parent> to insert in front of instead.
No other section changes, not by a byte (their hashes stay): when a heading
follows the new section, one blank line ends it, as part of the new section;
the only edit elsewhere is the line ending of a last line that lacked one.
C<delete_section> of the new section restores the page as it was.

Dies, writing nothing, when the parent or C<before> does not exist, when
C<before> is no direct child of the parent, when the level would be 7 or a
sibling in front of which it goes is of a deeper level (it would become that
sibling's parent and change its address), when C<heading> is empty, spans lines
or would not be read back as that heading, when C<content> would change the
structure of the page (see L<MCP::Wiki::TOC::Parser/body_problem>), or when the
change would alter the C<heading_path> of any existing section (a new heading
equal to a sibling in front of which it goes). Returns the new
C<heading_path>, its C<level> and the C<hash> of the new section.

=cut

sub add_section {
    my ($self, %a) = @_;
    my $heading     = $self->_clean_heading($a{heading});
    my $parent_path = $a{parent} // '';
    my $before      = defined $a{before} && length $a{before} ? $a{before} : undef;

    my $content = $a{content};
    if (defined $content) {
        $content =~ s/\r\n/\n/g;
        $content =~ s/\n+\z//;
        $self->_check_body($content);
    }

    my ($text, $eol) = $self->_snapshot_for_update;
    my @entries = MCP::Wiki::TOC::Parser->parse_content($text);
    my %by_path = map { $_->heading_path => $_ } @entries;

    my ($parent, $level);
    if (length $parent_path) {
        $parent = $by_path{$parent_path} or die "Heading not found: $parent_path";
        $level  = $parent->level + 1;
        die "Cannot add a section below '$parent_path': it is level 6 and there is no level 7\n"
            if $level > 6;
    }
    else {
        $level = 1;
    }
    my $where = length $parent_path ? "'$parent_path'" : 'the top level';

    # The lines of the page without the terminator of the last one; the block
    # goes in front of the line with index $pos
    my @lines  = split /\n/, $text, -1;
    my $had_nl = @lines && $lines[-1] eq '';
    pop @lines if $had_nl;

    # By default at the end of the page, but in front of its trailing blank
    # lines: they stay where they are, after the last section
    my $pos = @lines;
    $pos-- while $pos > 0 && $lines[$pos - 1] !~ /\S/;

    if (defined $before) {
        my $sibling = $by_path{$before} or die "Heading not found: $before";
        die "Cannot insert before '$before': it is no direct child of $where\n"
            unless $self->_is_child($parent_path, $before);
        die "Cannot insert a level $level heading before '$before': that is level "
            .$sibling->level.", so it would become a child of the new section and change its"
            ." address\n" if $level < $sibling->level;
        $pos = $sibling->line_start - 1;
    }
    elsif ($parent) {
        # After the whole subtree: up to the next heading that is not deeper
        my ($next) = grep { $_->line_start > $parent->line_start && $_->level <= $parent->level } @entries;
        $pos = $next->line_start - 1 if $next;
    }

    my @block = ('#' x $level.' '.$heading,
        (defined $content && length $content ? split(/\n/, $content, -1) : ()));
    # No other section changes by a byte: the separating blank line, if the
    # new section is followed by a heading, is the new section's own last line
    push @block, '' if $pos < @lines && $lines[$pos] =~ /\S/;
    splice @lines, $pos, 0, @block;
    my $new_text = join("\n", @lines).($had_nl || !length $text ? "\n" : '');

    # What was written has to read back as the section that was meant, and
    # leave every other address alone
    my @now = MCP::Wiki::TOC::Parser->parse_content($new_text);
    my ($added) = grep { $_->line_start == $pos + 1 } @now;
    die "The heading '$heading' would not be read as a heading of level $level at that place"
        ." (it lies inside a code block, comment or front matter, or is not valid heading text)\n"
        unless $added && $added->heading eq $heading && $added->level == $level;
    my @others = grep { $_ != $added } @now;
    die "Adding '$heading' there would change the address of an existing section"
        ." (a section of the same name comes after it); add it at the end of '$parent_path'"
        ." or give it another name\n"
        unless @others == @entries
            && !grep { $others[$_]->heading_path ne $entries[$_]->heading_path
                || $others[$_]->level != $entries[$_]->level } 0 .. $#entries;

    $self->write_text($new_text, $eol);
    return {
        heading_path => $added->heading_path,
        level        => $level,
        hash         => $self->_entry_hash($new_text, $eol, $added),
    };
}

=method delete_section

    my $removed = $doc->delete_section('Guide#Setup', expected_hash => $hash);

Removes the section: its heading, its body and all its subsections. With
C<expected_hash>, the C<hash> of the section itself (its subsections are not
part of it), it dies instead when the section is not as it was then. The
preamble (C<heading_path> C<"">) is no section and cannot be deleted. Returns
the C<heading_path>s that are gone, the section's first.

=cut

sub delete_section {
    my ($self, $heading_path, %opt) = @_;
    $self->_valid_expected_hash($opt{expected_hash});
    die "The preamble (the text before the first heading) is no section and has no heading"
        ." to delete; empty it with update_paragraph\n" if $heading_path eq '';

    my ($text, $eol, $bytes) = $self->_snapshot_for_update;
    my @entries = MCP::Wiki::TOC::Parser->parse_content($text);
    my ($i) = grep { $entries[$_]->heading_path eq $heading_path } 0 .. $#entries;
    die "Heading not found: $heading_path" unless defined $i;
    my $entry = $entries[$i];
    $self->_check_expected_hash($opt{expected_hash},
        $self->_section_hash($self->_raw_lines($bytes), $entry), "Section $heading_path");

    # The section runs on through every deeper heading
    my $j = $i + 1;
    $j++ while $j <= $#entries && $entries[$j]->level > $entry->level;
    my $last = $j <= $#entries ? $entries[$j]->line_start - 1 : $entries[-1]->line_end;

    my @lines = split /\n/, $text, -1;
    splice @lines, $entry->line_start - 1, $last - $entry->line_start + 1;
    $self->write_text(join("\n", @lines), $eol);

    return [ map { $_->heading_path } @entries[$i .. $j - 1] ];
}

=method rename_heading

    my $new = $doc->rename_heading('Guide#Setup', 'Install', expected_hash => $hash);
    # { heading_path => 'Guide#Install', previous_heading_path => 'Guide#Setup', hash => ... }

Changes the text of a heading and keeps its level; the line is rewritten as a
plain ATX heading. The C<heading_path> of the section changes, and so do those
of its subsections; a new text equal to a sibling's shifts the occurrence
suffixes of the duplicates (see L<MCP::Wiki::TOC::Parser/HEADING PATHS>).
C<expected_hash> is the hash of the section. Dies, writing nothing, when the
section does not exist (the preamble has no heading), when the text is empty,
spans lines or would not be read back as that heading. Returns the new
C<heading_path>, the C<previous_heading_path> and the new C<hash> of the section.

=cut

sub rename_heading {
    my ($self, $heading_path, $new_heading, %opt) = @_;
    $self->_valid_expected_hash($opt{expected_hash});
    die "The preamble (the text before the first heading) has no heading to rename\n" if $heading_path eq '';
    my $heading = $self->_clean_heading($new_heading);

    my ($text, $eol, $bytes) = $self->_snapshot_for_update;
    my $entry = $self->_find_entry($text, $heading_path) or die "Heading not found: $heading_path";
    $self->_check_expected_hash($opt{expected_hash},
        $self->_section_hash($self->_raw_lines($bytes), $entry), "Section $heading_path");

    my @lines = split /\n/, $text, -1;
    $lines[$entry->line_start - 1] = '#' x $entry->level.' '.$heading;
    my $new_text = join "\n", @lines;

    my @now = MCP::Wiki::TOC::Parser->parse_content($new_text);
    my ($renamed) = grep { $_->line_start == $entry->line_start } @now;
    die "The heading '$heading' would not be read back as that heading (it is not valid heading text)\n"
        unless $renamed && $renamed->heading eq $heading && $renamed->level == $entry->level;

    $self->write_text($new_text, $eol);
    return {
        heading_path          => $renamed->heading_path,
        previous_heading_path => $heading_path,
        hash                  => $self->_entry_hash($new_text, $eol, $renamed),
    };
}

=method search

    my @hits = $doc->search('needle', 10);

Returns the lines that contain the text, ignoring case, in page order, at most
the given number (all without one). Each hit is a hashref: C<line> (1-based),
C<heading_path> of the section the line is in (empty before the first heading)
and a C<snippet>, the line without surrounding whitespace, cut to about 160
characters around the match.

=cut

sub search {
    my ($self, $query, $limit) = @_;
    my ($text) = $self->_read_page;
    my @entries = MCP::Wiki::TOC::Parser->parse_content($text);
    my $re      = qr/\Q$query\E/i;
    my @lines   = split /\n/, $text;

    my (@hits, $e);
    $e = -1;
    for my $n (1 .. @lines) {
        $e++ while $e < $#entries && $entries[$e + 1]->line_start <= $n;
        next unless $lines[$n - 1] =~ $re;
        push @hits, {
            line         => $n,
            heading_path => $e < 0 ? '' : $entries[$e]->heading_path,
            snippet      => $self->_snippet($lines[$n - 1], $-[0]),
        };
        last if defined $limit && @hits >= $limit;
    }
    return @hits;
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

# A line without surrounding whitespace, cut to 160 characters around the
# match at $at, with "..." where it was cut.
sub _snippet {
    my ($self, $line, $at) = @_;
    $at -= length($1) if $line =~ s/\A(\s+)//;
    $line =~ s/\s+\z//;
    return $line if length $line <= 160;
    my $from = $at > 60 ? $at - 60 : 0;
    $from = length($line) - 160 if $from > length($line) - 160;
    return ($from > 0 ? '...' : '').substr($line, $from, 160)
        .($from + 160 < length $line ? '...' : '');
}

# Heading text as it goes into a heading line: trimmed, on one line, not empty.
sub _clean_heading {
    my ($self, $heading) = @_;
    die "Heading text required\n" unless defined $heading && !ref $heading;
    $heading =~ s/\A\s+|\s+\z//g;
    die "A heading must have text\n" unless length $heading;
    die "A heading must be on one line: it contains a line break\n" if $heading =~ /[\r\n]/;
    return $heading;
}

# Dies when text meant as a section body would change the page's structure.
sub _check_body {
    my ($self, $content, %opt) = @_;
    my $problem = MCP::Wiki::TOC::Parser->body_problem($content, %opt) // return;
    die "Content contains $problem and would change the structure of the page;"
        ." add a section with add_section and rename a heading with rename_heading\n";
}

# True when $path is a direct child of $parent ("" is the top level): $path is
# the parent's path plus exactly one more segment.
sub _is_child {
    my ($self, $parent, $path) = @_;
    my $rest = $path;
    if (length $parent) {
        return 0 unless index($path, $parent.'#') == 0;
        $rest = substr($path, length($parent) + 1);
    }
    my ($segments) = MCP::Wiki::TOC::Parser->split_heading_path($rest);
    return @$segments == 1 ? 1 : 0;
}

# The hash of an entry of LF text that is written with $eol.
sub _entry_hash {
    my ($self, $text, $eol, $entry) = @_;
    return $self->_section_hash($self->_raw_lines($self->_encode($text, $eol)), $entry);
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