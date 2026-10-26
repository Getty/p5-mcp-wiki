package MCP::Wiki::TOC::Parser;
# ABSTRACT: Markdown TOC extraction - pure Perl implementation

use strict;
use warnings;
use MCP::Wiki::TOC::Entry;
use Path::Tiny;

=head1 DESCRIPTION

A pure-Perl, line-based parser for ATX headings. It is not a CommonMark parser
and builds no document tree, but it follows the CommonMark rules for the lines
that decide whether a heading-shaped line is a heading.

=head1 HEADING RECOGNITION

A line is a heading when, outside everything listed as skipped below, it has up
to three spaces, one to six C<#>, whitespace and text. A closing run of C<#>
after whitespace is not part of the text; a heading without text is none.

Skipped, so that a heading-shaped line inside it counts for nothing:

=over 4

=item *

A leading YAML front matter block: C<---> on the first line up to the next line
that is C<---> or C<...>. Without such a closing line the first line is
ordinary text.

=item *

A leading byte order mark (U+FEFF) is ignored for the parse: C<\x{FEFF}# Title>
is the heading C<Title>.

=item *

Fenced code blocks of C<```> or C<~~~>. The opening fence is indented by at
most three spaces; a backtick fence has no backtick in its info string
(C<```inline```> opens nothing). The closing fence uses the same character, is
at least as long as the opener, is indented by at most three spaces and is
followed by whitespace only. A fence without a closer runs to the end.

=item *

Lines indented by four or more spaces outside a fence: indented code, neither
a heading nor a fence.

=item *

HTML comment blocks: a line of up to three spaces and C<< <!-- >> up to the
line that contains C<< --> >>.

=back

Setext headings (underlined with C<===> or C<--->) are not supported.

Since every entry's C<heading_path> depends on which lines count as headings,
a change to these rules changes the addresses of existing sections.

=head1 HEADING PATHS

An entry's C<heading_path> joins the heading texts of its open ancestors and
its own with C<#>. Within a segment C<\> is written C<\\> and C<#> is written
C<\#>, so the separator is never ambiguous: the H1 C<A#B> is C<A\#B>, the pair
C<A> > C<B> is C<A#B>. A text that ends in C<[digits]> has its C<[> written
C<\[>. L</split_heading_path> undoes all of it.

The first heading with a given path keeps it. The second and every later one
gets an occurrence suffix on its last segment: with C<# Page>, C<## Notes>,
C<## Other>, C<## Notes> the sections are C<Page#Notes>, C<Page#Other> and
C<Page#Notes[2]>, then C<Page#Notes[3]> for a third. The suffix stays in the
path of the section's children (C<Page#Notes[2]#Sub>). Every lookup works on
whole paths, so C<get_paragraph>, C<update_paragraph> and the history tools
reach the later duplicates; History numbers the headings of each revision by
the same rule, so a duplicate is followed through the history by its number.

=cut

sub parse_file {
    my ($class, $file_path) = @_;
    my $content = Path::Tiny::path($file_path)->slurp_utf8;
    return $class->parse_content($content);
}

=method parse_file

    my @entries = MCP::Wiki::TOC::Parser->parse_file('wiki/page.md');

Reads the file as UTF-8 and returns what L</parse_content> returns for its
text. Dies when the file cannot be read.

=cut

sub parse_content {
    my ($class, $content) = @_;
    my ($lines, $headings) = $class->_scan($content);
    my @lines    = @$lines;
    my @headings = @$headings;  # [line_number, level, heading_text]

    # Convert to TOC entries with line ranges
    my @entries;
    my @stack;    # [level, heading] of the open ancestors, carried across headings
    my %seen;     # path => how many headings have had it so far
    my %anchors;  # every anchor handed out so far
    for my $i (0 .. $#headings) {
        my ($line_start, $level, $heading) = @{$headings[$i]};

        # Determine line_end: next heading - 1, or end of content
        my $line_end;
        if ($i < $#headings) {
            $line_end = $headings[$i + 1][0] - 1;
        } else {
            $line_end = scalar(@lines);
        }

        # Build heading_path (chain of ancestor headings)
        my $heading_path = $class->_build_heading_path(\@stack, \%seen, $level, $heading);

        # Content preview
        my ($preview, $char_count) = $class->_extract_section(\@lines, $line_start, $line_end);

        # URL-safe anchor
        my $anchor = $class->_make_anchor(\%anchors, $heading);

        push @entries, MCP::Wiki::TOC::Entry->new(
            level           => $level,
            heading         => $heading,
            anchor          => $anchor,
            heading_path    => $heading_path,
            line_start      => $line_start,
            line_end        => $line_end,
            content_preview => $preview,
            char_count      => $char_count,
        );
    }

    return @entries;
}

=method parse_content

    my @entries = MCP::Wiki::TOC::Parser->parse_content($markdown);

Returns one L<MCP::Wiki::TOC::Entry> per heading of C<$markdown>, in document
order, or an empty list when it has none. A section runs from its heading line
to the line before the next heading of any level; the last one ends at the
last line of C<$markdown>, trailing empty lines not counted. Line numbers are
1-based and belong to this one parse.

Each entry's C<heading_path> joins the headings of its open ancestors and its
own with C<#>: a heading closes every open heading of the same or a deeper
level, so C<# A>, C<### C>, C<## B> give C<A>, C<A#C> and C<A#B>. Duplicate
paths are made unique by an occurrence suffix, see L</HEADING PATHS>.

=cut

# The line scan behind parse_content and body_problem: the lines, the headings
# found ([line_number, level, text]) and what is still open at the end (a code
# fence or an HTML comment that never closes), if anything. Without
# front_matter a leading --- block is ordinary text.
sub _scan {
    my ($class, $content, %opt) = @_;
    my $front_matter = exists $opt{front_matter} ? $opt{front_matter} : 1;
    my $open_comment = 0;

    # A byte order mark is no part of the first line's text. Only the parse
    # drops it; Document keeps it in the page, so a write leaves it in place.
    $content =~ s/\A\x{FEFF}//;
    my @lines = split /\n/, $content;
    my @headings;  # [line_number, level, heading_text]

    my $i = 0;

    # Leading YAML front matter: --- on the first line up to the next --- or ...
    if ($front_matter && @lines && $lines[0] =~ /^---[ \t]*$/) {
        for my $j (1 .. $#lines) {
            if ($lines[$j] =~ /^(?:---|\.\.\.)[ \t]*$/) {
                $i = $j + 1;
                last;
            }
        }
    }

    my $fence;    # [char, length] of the open fenced code block
    for (; $i <= $#lines; $i++) {
        my $line = $lines[$i];

        if ($fence) {
            # The closer: same char, at least as long, up to 3 spaces, nothing after
            $fence = undef
                if $line =~ /^ {0,3}(`+|~+)[ \t]*$/
                    && substr($1, 0, 1) eq $fence->[0]
                    && length($1) >= $fence->[1];
            next;
        }

        # Indented code (4+ spaces) is neither a heading nor a fence
        next if $line =~ /^    /;

        if ($line =~ /^ {0,3}(`{3,}|~{3,})(.*)$/) {
            my ($run, $info) = ($1, $2);
            # A backtick fence has no backtick in its info string
            unless (substr($run, 0, 1) eq '`' && $info =~ /`/) {
                $fence = [substr($run, 0, 1), length $run];
                next;
            }
        }

        # HTML comment block: up to the line holding -->
        if ($line =~ /^ {0,3}<!--(.*)$/) {
            my $rest = $1;
            next if $rest =~ /-->/;
            my $j = $i + 1;
            $j++ while $j <= $#lines && $lines[$j] !~ /-->/;
            $open_comment = 1 if $j > $#lines;
            $i = $j;
            next;
        }

        # ATX headings: 1-6 #, 0-3 spaces before, a closing # run only after a space
        if ($line =~ /^ {0,3}(#{1,6})(?:[ \t]+(.*))?$/) {
            my ($level, $text) = (length $1, $2 // '');
            $text =~ s/(?:^|[ \t]+)#+[ \t]*$//;
            $text =~ s/^[ \t]+|[ \t]+$//g;
            next unless length $text;
            push @headings, [$i + 1, $level, $text];  # 1-indexed line
        }
    }

    my $open = $fence ? 'a code fence' : $open_comment ? 'an HTML comment' : undef;
    return (\@lines, \@headings, $open);
}

=method body_problem

    my $problem = MCP::Wiki::TOC::Parser->body_problem($text);
    my $problem = MCP::Wiki::TOC::Parser->body_problem($text, front_matter => 1);

Says whether C<$text>, meant as the body of one section, would change the
structure of the page it is written into: returns a short description of the
first problem, or nothing when the text is safe. The problems are a line that
is a heading by the rules of L</HEADING RECOGNITION> (the section would be
split or a new one created), and a code fence or an HTML comment still open at
the end (it would swallow every later heading). A heading inside a closed
fence or comment is no heading, so it is fine. The text is read as starting
outside of everything, as a section body does; C<front_matter> says it starts
a page, where a leading front matter block is skipped (the preamble).

=cut

sub body_problem {
    my ($class, $text, %opt) = @_;
    my ($lines, $headings, $open) = $class->_scan($text, front_matter => $opt{front_matter} ? 1 : 0);
    return 'a heading line (line '.$headings->[0][0].': '.$lines->[$headings->[0][0] - 1].')'
        if @$headings;
    return $open.' that is never closed' if $open;
    return;
}

sub _build_heading_path {
    my ($class, $stack, $seen, $level, $heading) = @_;

    # Entering a level closes every open heading of the same or a deeper level.
    # $stack holds the ancestors left by the previous heading, so each heading
    # costs one push and at most as many pops as were pushed before.
    pop @$stack while @$stack && $stack->[-1][0] >= $level;
    my $segment = $class->escape_segment($heading);
    my $path    = join('#', (map { $_->[1] } @$stack), $segment);

    # The 2nd and later heading with the same path get an occurrence suffix.
    # The segment keeps it on the stack, so the children of the 2nd "Notes"
    # are "Page#Notes[2]#..." and not a second "Page#Notes#...".
    my $n = ++$seen->{$path};
    if ($n > 1) {
        $segment .= "[$n]";
        $path    .= "[$n]";
    }
    push @$stack, [$level, $segment];

    return $path;
}

=method escape_segment

    my $segment = MCP::Wiki::TOC::Parser->escape_segment('C#');    # C\#

Returns heading text as one segment of a C<heading_path>: C<\> becomes C<\\>,
C<#> becomes C<\#>, and a text that itself ends in C<[digits]> gets that C<[>
escaped (C<\[>), so an occurrence suffix (see L</HEADING PATHS>) can never be
mistaken for heading text.

=cut

sub escape_segment {
    my ($class, $text) = @_;
    $text =~ s/([\\#])/\\$1/g;
    $text =~ s/\[(\d+\])$/\\[$1/;
    return $text;
}

=method split_heading_path

    my ($segments, $occurrence) = MCP::Wiki::TOC::Parser->split_heading_path('A\#B#Notes[2]');
    # (['A#B', 'Notes'], 2)

The inverse of the path construction: splits at every unescaped C<#>, removes
the escapes and cuts the occurrence suffix off the last segment. C<$occurrence>
is 1 without a suffix.

=cut

sub split_heading_path {
    my ($class, $path) = @_;
    my @segments = ([]);    # per segment: [char, was_escaped] pairs
    while ($path =~ /\G(?:\\(.)|(#)|(.))/gs) {
        if    (defined $2) { push @segments, [] }
        elsif (defined $1) { push @{$segments[-1]}, [$1, 1] }
        else               { push @{$segments[-1]}, [$3, 0] }
    }

    my $occurrence = 1;
    my $tail = join '', map { $_->[1] ? "\0" : $_->[0] } @{$segments[-1]};
    if ($tail =~ /\[(\d+)\]\z/) {
        $occurrence = $1;
        splice @{$segments[-1]}, -length("[$1]");
    }

    return ([ map { join '', map { $_->[0] } @$_ } @segments ], $occurrence);
}

# GitHub-style: lower case, everything but letters, digits, spaces, "-" and "_"
# dropped, each space a "-". The 2nd and later equal anchor gets -1, -2, ...
# ($used holds every anchor handed out so far, a suffixed one included).
sub _make_anchor {
    my ($class, $used, $heading) = @_;
    my $anchor = lc $heading;
    $anchor =~ s/[^\p{L}\p{N} _-]//g;
    $anchor =~ s/ /-/g;

    if ($used->{$anchor}++) {
        my $n = 1;
        $n++ while $used->{"$anchor-$n"};
        $used->{"$anchor-$n"} = 1;
        $anchor .= "-$n";
    }
    return $anchor;
}

sub _extract_section {
    my ($class, $lines, $line_start, $line_end) = @_;
    my @section = @{$lines}[$line_start - 1 .. $line_end - 1];
    my $content = join("\n", @section);
    my $char_count = length($content);

    my $preview = $content;
    if (length($preview) > 100) {
        $preview = substr($preview, 0, 100) . '...';
    }

    return ($preview, $char_count);
}

1;