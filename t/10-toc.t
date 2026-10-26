use strict;
use warnings;
use Test::More;
use Path::Tiny;
use MCP::Wiki::TOC::Parser;
use MCP::Wiki::TOC::Entry;

subtest 'parse_content extracts headings' => sub {
    my $md = <<'MARKDOWN';
# Introduction

This is the intro.

## Background

Some background info.

## Installation

Step one.
Step two.
MARKDOWN

    my @entries = MCP::Wiki::TOC::Parser->parse_content($md);

    is(scalar(@entries), 3, 'three headings found');

    is($entries[0]->level, 1, 'H1 level');
    is($entries[0]->heading, 'Introduction', 'H1 heading');
    is($entries[0]->heading_path, 'Introduction', 'H1 path');
    ok($entries[0]->line_start, 'H1 has line_start');
    ok($entries[0]->line_end >= $entries[0]->line_start, 'line_end >= line_start');

    is($entries[1]->level, 2, 'H2 level');
    is($entries[1]->heading, 'Background', 'H2 heading');
    is($entries[1]->heading_path, 'Introduction#Background', 'H2 path with parent');

    is($entries[2]->level, 2, 'H2 level');
    is($entries[2]->heading, 'Installation', 'H2 heading');
};

subtest 'heading anchors are url-safe' => sub {
    my $md = "# Hello World! How Are You?";

    my @entries = MCP::Wiki::TOC::Parser->parse_content($md);

    is($entries[0]->anchor, 'hello-world-how-are-you', 'lowercase, spaces to hyphens');
};

subtest 'ignores headings in code blocks' => sub {
    my $md = <<'MARKDOWN';
# Real Heading

```
# Not a heading
```

## Another Real Heading
MARKDOWN

    my @entries = MCP::Wiki::TOC::Parser->parse_content($md);

    is(scalar(@entries), 2, 'only real headings found');
    is($entries[0]->heading, 'Real Heading');
    is($entries[1]->heading, 'Another Real Heading');
};

subtest 'as_hash returns correct structure' => sub {
    my $md = "# Test";

    my @entries = MCP::Wiki::TOC::Parser->parse_content($md);
    my $hash = $entries[0]->as_hash;

    ok(exists $hash->{level}, 'has level');
    ok(exists $hash->{heading}, 'has heading');
    ok(exists $hash->{anchor}, 'has anchor');
    ok(exists $hash->{heading_path}, 'has heading_path');
    ok(exists $hash->{line_start}, 'has line_start');
    ok(exists $hash->{line_end}, 'has line_end');
    ok(exists $hash->{content_preview}, 'has content_preview');
    ok(exists $hash->{char_count}, 'has char_count');
};

subtest 'heading_path is the chain of ancestors, not of siblings' => sub {
    my $md = join "\n",
        '# Intro', '## Alpha', '## Beta', '### Deep', '## Gamma', '# Other', '## Alpha', '';
    my @paths = map { $_->heading_path } MCP::Wiki::TOC::Parser->parse_content($md);
    is_deeply(\@paths, [
        'Intro', 'Intro#Alpha', 'Intro#Beta', 'Intro#Beta#Deep',
        'Intro#Gamma', 'Other', 'Other#Alpha',
    ], 'siblings are dropped when a level is re-entered');
};

subtest 'heading_path survives skipped levels' => sub {
    my @paths = map { $_->heading_path }
        MCP::Wiki::TOC::Parser->parse_content("# A\n### C\n## B\n");
    is_deeply(\@paths, ['A', 'A#C', 'A#B'], 'a skipped level does not leak');
};

# Pins the exact addresses and ranges of a varied document, so that rebuilding
# the heading_path construction (e.g. for speed) cannot change them unnoticed.
# heading_path is a stored address; line ranges are 1-based and inclusive.
subtest 'heading_path, level and line range are pinned for a varied document' => sub {
    my $md = <<'MARKDOWN';
preamble before any heading
# Alpha
text
### Skipped
## Back
#### Deep
##### Deeper
###### Deepest
## Dup
### Child
## Dup
```
# in fence
## also fenced
```
    # indented, not a heading
# C#
## Trail ##
### Tight###
# Alpha
## Dup
### Child
#### Deep
## Child
# After fence
MARKDOWN

    # [ heading_path, level, line_start, line_end ]
    my @expected = (
        [ 'Alpha',                          1,  2,  3 ],
        [ 'Alpha#Skipped',                  3,  4,  4 ],
        [ 'Alpha#Back',                     2,  5,  5 ],
        [ 'Alpha#Back#Deep',                4,  6,  6 ],
        [ 'Alpha#Back#Deep#Deeper',         5,  7,  7 ],
        [ 'Alpha#Back#Deep#Deeper#Deepest', 6,  8,  8 ],
        [ 'Alpha#Dup',                      2,  9,  9 ],
        [ 'Alpha#Dup#Child',                3, 10, 10 ],
        [ 'Alpha#Dup[2]',                  2, 11, 16 ],
        [ 'C\#',                            1, 17, 17 ],
        [ 'C\##Trail',                      2, 18, 18 ],
        [ 'C\##Trail#Tight\#\#\#',      3, 19, 19 ],
        [ 'Alpha[2]',                         1, 20, 20 ],
        [ 'Alpha[2]#Dup',                    2, 21, 21 ],
        [ 'Alpha[2]#Dup#Child',             3, 22, 22 ],
        [ 'Alpha[2]#Dup#Child#Deep',           4, 23, 23 ],
        [ 'Alpha[2]#Child',                  2, 24, 24 ],
        [ 'After fence',                    1, 25, 25 ],
    );

    my @entries = MCP::Wiki::TOC::Parser->parse_content($md);
    my @got = map { [ $_->heading_path, $_->level, $_->line_start, $_->line_end ] } @entries;

    is_deeply(\@got, \@expected, 'every entry: heading_path, level, line_start, line_end');
};

done_testing;