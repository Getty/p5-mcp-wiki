use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use File::Spec;
use MCP::Wiki::Document;

subtest 'Document basic operations' => sub {
    my $dir = tempdir;

    my $test_file = File::Spec->catfile($dir, 'test.md');
    Path::Tiny::path($test_file)->spew_utf8(<<'MARKDOWN');
# Introduction

This is the intro.

## Background

Some background.
MARKDOWN

    my $doc = MCP::Wiki::Document->new(
        file_path   => $test_file,
        wiki_root => "$dir",
    );

    ok($doc->content, 'has content');

    my @toc = $doc->get_toc;
    is(scalar(@toc), 2, 'two TOC entries');
    is($toc[0]->heading, 'Introduction');
    is($toc[1]->heading, 'Background');
};

subtest 'get_paragraph returns section content' => sub {
    my $dir = tempdir;

    my $test_file = File::Spec->catfile($dir, 'test.md');
    Path::Tiny::path($test_file)->spew_utf8(<<'MARKDOWN');
# Intro

Some intro content here.

## Section One

Section one content.
MARKDOWN

    my $doc = MCP::Wiki::Document->new(
        file_path   => $test_file,
        wiki_root => "$dir",
    );

    my $para = $doc->get_paragraph('Intro');
    ok($para, 'got paragraph');
    like($para->{content}, qr/intro/i, 'content contains intro');

    $para = $doc->get_paragraph('Intro#Section One');
    ok($para, 'got nested paragraph');
    like($para->{content}, qr/Section one/, 'content has section one');
};

subtest 'a section is its body, the heading line is never part of it' => sub {
    my $dir  = tempdir;
    my $file = File::Spec->catfile($dir, 'page.md');
    my $md   = "# Intro\nintro text\n## Alpha\nalpha text\n\n## Beta\nbeta text\n";
    Path::Tiny::path($file)->spew_utf8($md);
    my $doc = MCP::Wiki::Document->new(file_path => $file, wiki_root => "$dir");

    is($doc->get_paragraph('Intro#Alpha')->{content}, "alpha text\n", 'get returns the body only');
    is($doc->get_paragraph('Intro')->{content}, 'intro text', 'a parent section ends at its first child');

    $doc->set_paragraph('Intro#Alpha', "NEW\n");
    is(Path::Tiny::path($file)->slurp_utf8,
        "# Intro\nintro text\n## Alpha\nNEW\n\n## Beta\nbeta text\n",
        'set replaces the body; heading and following section stay');
};

subtest 'get_paragraph -> set_paragraph is idempotent' => sub {
    my $dir = tempdir;
    my $md  = "# Intro\nintro text\n## Alpha\nalpha text\n\n## Empty\n## Beta\nbeta text\n";
    for my $trailing ('', "\n") {
        my $file = File::Spec->catfile($dir, 'page.md');
        Path::Tiny::path($file)->spew_utf8($md . $trailing);
        my $doc = MCP::Wiki::Document->new(file_path => $file, wiki_root => "$dir");
        my $name = $trailing eq '' ? 'no final newline' : 'final newline';
        for my $path (map { $_->heading_path } $doc->get_toc) {
            $doc->set_paragraph($path, $doc->get_paragraph($path)->{content});
            is(Path::Tiny::path($file)->slurp_utf8, $md . $trailing, "$path unchanged ($name)");
        }
    }
};

subtest 'set_paragraph can empty a section and fill an empty one' => sub {
    my $dir  = tempdir;
    my $file = File::Spec->catfile($dir, 'page.md');
    Path::Tiny::path($file)->spew_utf8("# A\nbody\n# B\n# C\nc\n");
    my $doc = MCP::Wiki::Document->new(file_path => $file, wiki_root => "$dir");
    $doc->set_paragraph('A', '');
    $doc->set_paragraph('B', 'filled');
    is(Path::Tiny::path($file)->slurp_utf8, "# A\n# B\nfilled\n# C\nc\n", 'both edits land in their own section');
};

done_testing;