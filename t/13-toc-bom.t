#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny;
use MCP::Wiki::TOC::Parser;
use MCP::Wiki::Document;

my @e = MCP::Wiki::TOC::Parser->parse_content("\x{FEFF}# Title\nintro\n## Sub\n");
is_deeply [map { $_->heading_path } @e], ['Title', 'Title#Sub'], 'a BOM does not hide the first heading';
is $e[0]->heading, 'Title', 'the heading text carries no BOM';
is $e[0]->line_start, 1, 'line numbers are unchanged';

@e = MCP::Wiki::TOC::Parser->parse_content("\x{FEFF}---\n# yaml\n---\n# T\n");
is_deeply [map { $_->heading_path } @e], ['T'], 'front matter is found behind a BOM';

# the page keeps its BOM through a get -> set round trip
my $dir  = Path::Tiny->tempdir;
my $file = $dir->child('bom.md');
my $raw  = "\xEF\xBB\xBF# Title\nintro\n## Sub\nbody\n";
$file->spew_raw($raw);
my $doc = MCP::Wiki::Document->new(file_path => "$file", wiki_root => "$dir");
is $doc->get_paragraph('Title')->{content}, 'intro', 'the intro is addressable';
$doc->set_paragraph('Title', $doc->get_paragraph('Title')->{content});
is $file->slurp_raw, $raw, 'get -> set leaves the page byte for byte as it was';
$doc->set_paragraph('Title#Sub', 'new');
is $file->slurp_raw, "\xEF\xBB\xBF# Title\nintro\n## Sub\nnew\n", 'a real edit keeps the BOM';

done_testing;
