#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use MCP::Wiki::TOC::Parser;

sub paths { map { $_->heading_path } MCP::Wiki::TOC::Parser->parse_content(join "\n", @_, '') }

is_deeply [paths('# A', '~~~', '# not a heading', '~~~', '## Child')], ['A', 'A#Child'],
    '~~~ fence hides a heading-shaped line';
is_deeply [paths('# A', '````', '```', '# inner', '````', '## B')], ['A', 'A#B'],
    'a longer fence is not closed by a shorter one';
is_deeply [paths('# A', '~~~~', '~~~', '# inner', '~~~~', '## B')], ['A', 'A#B'],
    'same for ~~~~';
is_deeply [paths('# A', '```', '~~~', '# inner', '```', '## B')], ['A', 'A#B'],
    'a ~~~ line does not close a ``` fence';
is_deeply [paths('# A', '   ```', '# in', '   ```', '## B')], ['A', 'A#B'],
    'a fence may be indented up to 3 spaces';
is_deeply [paths('# A', '    ```', '## B')], ['A', 'A#B'],
    'an indented-code line with ``` toggles nothing';
is_deeply [paths('# A', '```inline``` text', '## B')], ['A', 'A#B'],
    'a backtick in a backtick fence info string: no fence';
is_deeply [paths('# A', '~~~ info `x`', '# in', '~~~', '## B')], ['A', 'A#B'],
    'a ~~~ info string may contain backticks';
is_deeply [paths('# A', '```', '# in', '``` x', '## B', '```', '# C')], ['A', 'C'],
    'a closing fence takes no text: the fence stays open';
is_deeply [paths('# A', '```', '# in')], ['A'], 'an unterminated fence runs to the end';

is_deeply [paths('---', '# yaml comment', 'a: b', '---', '# Title', '## Sub')], ['Title', 'Title#Sub'],
    'leading front matter is skipped';
is_deeply [paths('---', 'a: b', '...', '# Title')], ['Title'], 'front matter may end in ...';
is_deeply [paths('---', '# Not closed', 'text')], ['Not closed'],
    'a --- first line without a closer is no front matter';
is_deeply [paths('# T', '---', '# Later', '---')], ['T', 'Later', ],
    'a --- block after the first line is no front matter' ;

is_deeply [paths('# A', '<!--', '# hidden', '-->', '## B')], ['A', 'A#B'], 'HTML comment block skipped';
is_deeply [paths('# A', '<!-- # hidden -->', '## B')], ['A', 'A#B'], 'one-line HTML comment';
is_deeply [paths('# A', '<!-- x', '## hidden --> tail', '## B')], ['A', 'A#B'],
    'the comment ends on the line holding -->';

is_deeply [paths('# A', ' ## One', '   ### Three', '    #### Four')], ['A', 'A#One', 'A#One#Three'],
    'ATX headings with 1-3 spaces are recognised, 4 are code';
is_deeply [paths('Setext', '======')], [], 'setext headings are not supported';

subtest 'update_paragraph keeps a ~~~ fence and front matter intact' => sub {
    require Path::Tiny;
    require MCP::Wiki::Document;
    my $dir  = Path::Tiny->tempdir;
    my $file = $dir->child('p.md');
    $file->spew_utf8("---\n# yaml\n---\n# A\n~~~\n# code\n~~~\n## Child\nold\n");
    my $doc = MCP::Wiki::Document->new(file_path => "$file", wiki_root => "$dir");
    $doc->set_paragraph('A', "~~~\n# code\n~~~\nnew");
    is $file->slurp_utf8, "---\n# yaml\n---\n# A\n~~~\n# code\n~~~\nnew\n## Child\nold\n",
        'the page keeps its front matter, closing fence and the child section';
    is $doc->get_paragraph('A#Child')->{content}, 'old', 'the real child is A#Child';
};

done_testing;
