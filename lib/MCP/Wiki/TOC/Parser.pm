package MCP::Wiki::TOC::Parser;
# ABSTRACT: Markdown TOC extraction - pure Perl implementation

use strict;
use warnings;
use MCP::Wiki::TOC::Entry;
use Path::Tiny;

=head1 DESCRIPTION

A pure-Perl, line-based parser for ATX headings (C<#> to C<######> at the
start of a line). Lines between C<```> fence lines and lines indented by four
spaces are skipped.

It is not a CommonMark parser: setext headings, C<~~~> fences, front matter
and HTML comments are not recognized. Getting CommonMark accuracy would mean
replacing this parser. Since every entry's C<heading_path> depends on which
lines count as headings, such a replacement changes the addresses of existing
sections.

=cut

my $IN_CODE_BLOCK;

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

    $IN_CODE_BLOCK = 0;
    my @lines = split /\n/, $content;
    my @headings;  # [line_number, level, heading_text]

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];

        # Check for code block boundaries
        if ($line =~ /^\s*```/) {
            $IN_CODE_BLOCK = !$IN_CODE_BLOCK;
            next;
        }
        next if $IN_CODE_BLOCK;

        # Skip indented code (4+ spaces at line start)
        next if $line =~ /^    /;

        # Match ATX-style headings: 1-6 # characters
        if ($line =~ /^(#{1,6})\s+(.+?)\s*#*\s*$/) {
            my $level = length($1);  # number of # chars
            my $heading_text = $2;

            push @headings, [$i + 1, $level, $heading_text];  # 1-indexed line
        }
    }

    # Convert to TOC entries with line ranges
    my @entries;
    my @stack;    # [level, heading] of the open ancestors, carried across headings
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
        my $heading_path = $class->_build_heading_path(\@stack, $level, $heading);

        # Content preview
        my ($preview, $char_count) = $class->_extract_section(\@lines, $line_start, $line_end);

        # URL-safe anchor
        my $anchor = $class->_make_anchor($heading);

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
paths are kept as they are, not made unique.

=cut

sub _build_heading_path {
    my ($class, $stack, $level, $heading) = @_;

    # Entering a level closes every open heading of the same or a deeper level.
    # $stack holds the ancestors left by the previous heading, so each heading
    # costs one push and at most as many pops as were pushed before.
    pop @$stack while @$stack && $stack->[-1][0] >= $level;
    push @$stack, [$level, $heading];

    return join('#', map { $_->[1] } @$stack);
}

sub _make_anchor {
    my ($class, $heading) = @_;
    my $anchor = lc $heading;
    $anchor =~ s/[^a-z0-9]+/-/g;
    $anchor =~ s/^-|-$//g;
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