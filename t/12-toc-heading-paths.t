use strict;
use warnings;
use Test::More;
use MCP::Wiki::TOC::Parser;

my $P = 'MCP::Wiki::TOC::Parser';

sub entries { $P->parse_content(join "\n", @_, '') }
sub paths   { map { $_->heading_path } entries(@_) }
sub texts   { map { $_->heading } entries(@_) }

# closing sequence: CommonMark, only after whitespace
is_deeply [texts('# C#', '## F#', '### C ##', '#### Tight###', '##### x #  ', '###### ##')],
    ['C#', 'F#', 'C', 'Tight###', 'x'],
    'a closing # run needs a space before it; a heading of only # has no text';

# the separator and the escape are escaped in paths
is_deeply [paths('# A#B')], ['A\#B'], '# in heading text is escaped';
is_deeply [paths('# A\\B')], ['A\\\\B'], 'a backslash is escaped';
my @p = paths('# A#B', '# A', '## B');
is_deeply \@p, ['A\#B', 'A', 'A#B'], 'H1 "A#B" and the pair "A" > "B" no longer collide';
is_deeply [paths('# C#', '## Sub')], ['C\#', 'C\##Sub'], 'C# keeps its name';
is_deeply [paths('# Foo[2]')], ['Foo\[2]'], 'text ending in [digits] is escaped';
is_deeply [paths('# Foo[2] x', '# [x]')], ['Foo[2] x', '[x]'], 'only a trailing [digits] is';

# split_heading_path inverts the construction
for my $text ('A#B', 'A\\B', 'Foo[2]', 'a\\', 'x\\#y', 'plain', '#', '[1]') {
    my $seg = $P->escape_segment($text);
    is_deeply [$P->split_heading_path($seg)], [[$text], 1], "round trip: $text";
}
is_deeply [$P->split_heading_path('A\\#B#C[2]')], [['A#B', 'C'], 2], 'split with suffix';
is_deeply [$P->split_heading_path('A\\\\[3]')], [['A\\'], 3], 'suffix after an escaped backslash';
is_deeply [$P->split_heading_path('A\\[3]')], [['A[3]'], 1], 'an escaped [ is no suffix';

done_testing;
