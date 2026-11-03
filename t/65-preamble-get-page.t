#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Digest::SHA qw( sha256_hex );
use Path::Tiny qw( tempdir );
use MCP::Wiki::Document;
use MCP::Wiki::Server;

# The text before the first heading is the preamble, addressed by the
# heading_path "" in get_paragraph and update_paragraph; a page without any
# heading is all preamble. get_page returns the whole page with its hash.

my $dir = tempdir;

sub doc {
    my ($name, $bytes) = @_;
    $dir->child($name)->spew_raw($bytes);
    return MCP::Wiki::Document->new(file_path => "$dir/$name", wiki_root => "$dir");
}
# A call that dies reports itself as a failure of the test, not of the file
sub set { my ($doc, @a) = @_; my $r = eval { $doc->set_paragraph(@a) }; diag $@ if $@; return $r }
sub getp { my ($doc, $hp) = @_; return scalar($doc->get_paragraph($hp)) // {} }
sub disk { $dir->child($_[0])->slurp_raw }

subtest 'Document: the preamble of a page with headings' => sub {
    my $doc = doc('p.md', "---\ntitle: x\n---\nintro\n\n# A\nbody\n");
    my $p = getp($doc, '');
    ok scalar($doc->get_paragraph('')), 'the heading_path "" is found';
    is $p->{content}, "---\ntitle: x\n---\nintro\n", 'front matter and text, up to the first heading';
    is $p->{heading_path}, '', 'its path is empty';
    is $p->{heading}, '', 'it has no heading';
    is $p->{line_start}, 1, 'starts at line 1';
    is $p->{line_end}, 5, 'ends before the first heading';
    is $p->{hash}, sha256_hex("---\ntitle: x\n---\nintro\n\n"), 'hash of those lines on disk';
    is getp($doc, 'A')->{content}, 'body', 'the sections are as before';

    set($doc, '', "new intro\n");
    is disk('p.md'), "new intro\n\n# A\nbody\n", 'set_paragraph replaces the preamble only';
    set($doc, '', getp($doc, '')->{content});
    is disk('p.md'), "new intro\n\n# A\nbody\n", 'get then set changes nothing';

    my $h = getp($doc, '')->{hash};
    set($doc, '', 'x');
    eval { $doc->set_paragraph('', 'y', expected_hash => $h) };
    like $@, qr/changed since read/, 'expected_hash guards the preamble too';
    is disk('p.md'), "x\n# A\nbody\n", 'and nothing is written';
    my $new = set($doc, '', 'z', expected_hash => getp($doc, '')->{hash});
    is $new, getp($doc, '')->{hash}, 'the matching hash writes and returns the new one';
};

subtest 'Document: a page without headings is all preamble' => sub {
    my $doc = doc('plain.md', "just text\nmore\n");
    is_deeply [$doc->get_toc], [], 'no entries';
    is getp($doc, '')->{content}, "just text\nmore", 'the whole text';
    set($doc, '', "other\n");
    is disk('plain.md'), "other\n\n", 'replaced';
    $doc = doc('plain2.md', "just text\n");
    set($doc, '', getp($doc, '')->{content});
    is disk('plain2.md'), "just text\n", 'get then set is byte-identical';

    $doc = doc('empty.md', '');
    is getp($doc, '')->{content}, '', 'an empty page has an empty preamble';
    set($doc, '', 'filled');
    is disk('empty.md'), 'filled', 'which can be filled';
};

subtest 'Document: byte order mark and CRLF' => sub {
    my $doc = doc('bom.md', "\xef\xbb\xbf# T\nbody\n");
    is getp($doc, '')->{content}, '', 'a mark in front of the first heading is no preamble text';
    set($doc, '', "pre\n");
    is disk('bom.md'), "\xef\xbb\xbfpre\n\n# T\nbody\n", 'the mark stays first in the file';
    is getp($doc, 'T')->{content}, 'body', 'the heading is still found';

    $doc = doc('crlf.md', "intro\r\n\r\n# A\r\nbody\r\n");
    is getp($doc, '')->{content}, "intro\n", 'LF in the content';
    set($doc, '', "a\nb\n");
    is disk('crlf.md'), "a\r\nb\r\n\r\n# A\r\nbody\r\n", 'written back with CRLF';
};

subtest 'Document: get_page' => sub {
    my $doc = doc('g.md', "intro\n\n# A\nbody\n");
    my $page = eval { $doc->get_page } // {};
    is $page->{content}, "intro\n\n# A\nbody\n", 'the whole text';
    is $page->{hash}, sha256_hex("intro\n\n# A\nbody\n"), 'hash of all bytes';
    $doc = doc('gc.md', "# A\r\nx\r\n");
    $page = eval { $doc->get_page } // {};
    is $page->{content}, "# A\nx\n", 'LF in the content';
    is $page->{hash}, sha256_hex("# A\r\nx\r\n"), 'CRLF in the hash';
};

subtest 'the tools' => sub {
    $dir->child('t.md')->spew_utf8("intro text\n\n# A\n\nbody\n");
    my $server = MCP::Wiki::Server->new(wiki_root => "$dir");
    my @events;
    $server->on_change(sub { push @events, $_[0] });
    my $call = sub {
        my ($name, $args) = @_;
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        return { isError => 1, content => [{ text => "no tool $name" }] } unless $tool;
        return $tool->code->($tool, $args);
    };

    my $res = $call->(get_page => { page => 't.md' });
    ok !$res->{isError}, 'get_page answers' or diag $res->{content}[0]{text};
    is $res->{structuredContent}{content}, "intro text\n\n# A\n\nbody\n", 'with the whole page';
    is $res->{structuredContent}{hash}, sha256_hex("intro text\n\n# A\n\nbody\n"), 'and its hash';
    is $res->{structuredContent}{page}, 't.md', 'and its name';
    ok $call->(get_page => { page => 'nope.md' })->{isError}, 'a missing page is an error';
    ok $call->(get_page => { page => '../x.md' })->{isError}, 'so is a page outside the root';

    $res = $call->(get_paragraph => { page => 't.md', heading_path => '' });
    ok !$res->{isError}, 'get_paragraph takes ""' or diag $res->{content}[0]{text};
    is $res->{structuredContent}{content}, "intro text\n", 'and returns the preamble';

    $res = $call->(update_paragraph => { page => 't.md', heading_path => '', content => "changed\n", reason => 'r' });
    ok !$res->{isError}, 'update_paragraph takes ""' or diag $res->{content}[0]{text};
    is $dir->child('t.md')->slurp_utf8, "changed\n\n# A\n\nbody\n", 'and replaces the preamble';
    is_deeply [ @{ $events[0] }{qw( type page heading_path reason )} ], [qw( update t.md ), '', 'r'], 'with an update event';

    $res = $call->(get_paragraph => { page => 't.md', heading_path => 'Nope' });
    ok $res->{isError}, 'an unknown path is still an error';

    my ($gp) = grep { $_->name eq 'get_page' } @{ $server->server->tools };
    ok $gp && $gp->annotations->{readOnlyHint}, 'get_page is read-only';
    for my $name (qw( get_paragraph update_paragraph )) {
        my ($t) = grep { $_->name eq $name } @{ $server->server->tools };
        like $t->input_schema->{properties}{heading_path}{description}, qr/preamble/i,
            "$name says what \"\" is";
    }
};

done_testing;
