#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use MCP::Wiki::TOC::Parser;

sub anchors { map { $_->anchor } MCP::Wiki::TOC::Parser->parse_content(join "\n", @_, '') }

is_deeply [anchors('# Über Größe', '# 日本語 🚀', '# Hello World! How Are You?', '# snake_case-kebab')],
    ['über-größe', '日本語-', 'hello-world-how-are-you', 'snake_case-kebab'],
    'GitHub-style: Unicode letters kept, punctuation dropped, each space a hyphen';

is_deeply [anchors('# A & B', '# Ünï  cödé')], ['a--b', 'ünï--cödé'],
    'a dropped character leaves its neighbouring spaces, which stay hyphens';

is_deeply [anchors('# Notes', '## Notes', '## Notes', '# Other', '# Notes')],
    ['notes', 'notes-1', 'notes-2', 'other', 'notes-3'],
    'equal anchors get -1, -2, ...';

is_deeply [anchors('# a', '# a', '# a-1', '# a')], ['a', 'a-1', 'a-1-1', 'a-2'],
    'a suffixed anchor is never handed out twice';

is_deeply [anchors('# 🚀', '# 🚀')], ['', '-1'], 'a heading of symbols only has an empty anchor';

done_testing;
