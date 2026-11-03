#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# update_paragraph replaces a body and nothing else: content that would change
# the structure of the page is refused (a heading line outside a closed code
# fence or comment, a fence or comment left open), with a pointer to
# add_section.

my $dir = tempdir;
my $PAGE = join '', map {"$_\n"} '# Intro', '', 'intro text', '', '## Alpha', 'alpha text', '', '## Beta', 'beta text';
$dir->child('p.md')->spew_utf8($PAGE);

my $server = MCP::Wiki::Server->new( wiki_root => "$dir" );
my @events;
$server->on_change( sub { push @events, $_[0] } );
sub update {
    my ( $hp, $content ) = @_;
    my ($tool) = grep { $_->name eq 'update_paragraph' } @{ $server->server->tools };
    return $tool->code->( $tool, { page => 'p.md', heading_path => $hp, content => $content } );
}
sub reset_page { $dir->child('p.md')->spew_utf8( $_[0] // $PAGE ); @events = () }

subtest 'refused' => sub {
    my @bad = (
        [ 'a heading of the same level'  => 'Intro#Alpha', "text\n## Hijack\nmore",  qr/heading/i ],
        [ 'a heading of a higher level'  => 'Intro#Alpha', "text\n# Hijack\nmore",   qr/heading/i ],
        [ 'a deeper heading'             => 'Intro#Alpha', "text\n### Sub\nmore",    qr/heading/i ],
        [ 'a heading with trailing #'    => 'Intro#Alpha', "## Closed ##",           qr/heading/i ],
        [ 'an indented heading (3 spaces)' => 'Intro#Alpha', "   # Hijack",          qr/heading/i ],
        [ 'a heading that is all of it'  => 'Intro#Beta',  "# Hijack",               qr/heading/i ],
        [ 'a heading after a closed fence' => 'Intro#Alpha', "```\ncode\n```\n# Hijack", qr/heading/i ],
        [ 'a heading in a section body that starts like front matter' => 'Intro#Alpha', "---\n# Hijack\n---", qr/heading/i ],
        [ 'an unclosed ``` fence'        => 'Intro#Alpha', "text\n```\ncode",        qr/fence/i ],
        [ 'an unclosed ~~~ fence'        => 'Intro#Beta',  "~~~\ncode",              qr/fence/i ],
        [ 'a fence closed by a shorter one' => 'Intro#Alpha', "````\ncode\n```",     qr/fence/i ],
        [ 'an unclosed HTML comment'     => 'Intro#Alpha', "text\n<!-- never",       qr/comment/i ],
        [ 'a heading in the preamble'    => '',            "text\n# Hijack",         qr/heading/i ],
        [ 'an open fence in the preamble' => '',           "```\ncode",              qr/fence/i ],
    );
    for my $b (@bad) {
        reset_page();
        my $res = update( $b->[1], $b->[2] );
        ok $res->{isError}, "$b->[0]: refused";
        like $res->{content}[0]{text}, $b->[3], '... and says why';
        like $res->{content}[0]{text}, qr/add_section/, '... and points to add_section';
        is $dir->child('p.md')->slurp_utf8, $PAGE, '... nothing written';
        is scalar @events, 0, '... no event';
    }
};

subtest 'accepted' => sub {
    my @good = (
        [ 'plain text'                         => 'Intro#Alpha', "new text\n\nmore" ],
        [ 'a # without a space is no heading'  => 'Intro#Alpha', "#hashtag and ####### seven" ],
        [ 'indented code that looks like one'  => 'Intro#Alpha', "    # code\n\ttext" ],
        [ 'a heading inside a closed fence'    => 'Intro#Alpha', "```\n# comment\n## more\n```" ],
        [ 'a heading inside a closed ~~~ fence' => 'Intro#Beta', "~~~\n# comment\n~~~\nafter" ],
        [ 'a longer closing fence'             => 'Intro#Alpha', "```\n# c\n`````" ],
        [ 'a heading inside an HTML comment'   => 'Intro#Alpha', "<!--\n# hidden\n-->\nvisible" ],
        [ 'an empty body'                      => 'Intro#Alpha', '' ],
        [ 'a preamble with front matter'       => '', "---\n# yaml comment\ntitle: x\n---\nintro\n" ],
        [ 'a preamble of text'                 => '', "just text\n" ],
    );
    for my $g (@good) {
        reset_page();
        my $res = update( $g->[1], $g->[2] );
        ok !$res->{isError}, "$g->[0]: accepted" or diag $res->{content}[0]{text};
        is scalar @events, 1, '... with its event';
    }

    # the page's own structure is unchanged by a legal edit
    reset_page();
    update( 'Intro#Alpha', "```\n# not a heading\n```" );
    my ($toc) = grep { $_->name eq 'get_toc' } @{ $server->server->tools };
    is_deeply [ map { $_->{heading_path} } @{ $toc->code->( $toc, { page => 'p.md' } )->{structuredContent}{entries} } ],
        [ 'Intro', 'Intro#Alpha', 'Intro#Beta' ], 'all addresses are still there';
};

subtest 'only what the edit adds counts' => sub {
    # a page whose last section already has an unclosed fence
    reset_page( $PAGE . "```\nunclosed\n" );
    my $res = update( 'Intro#Alpha', 'changed' );
    ok !$res->{isError}, 'another section can still be edited' or diag $res->{content}[0]{text};
    $res = update( 'Intro#Beta', "beta text\n```\nunclosed\n" );
    ok $res->{isError}, 'but the body that keeps the fence open is refused';
    $res = update( 'Intro#Beta', "beta text\n```\nclosed now\n```" );
    ok !$res->{isError}, 'closing it is accepted' or diag $res->{content}[0]{text};
};

subtest 'the same on a CRLF page and with a BOM' => sub {
    reset_page("# A\r\ntext\r\n");
    ok update( 'A', "x\r\n## B\r\ny" )->{isError}, 'CRLF content with a heading is refused';
    ok !update( 'A', "x\r\ny" )->{isError}, 'CRLF content without is accepted';
    reset_page("\x{FEFF}# A\ntext\n");
    ok update( '', "# B" )->{isError}, 'a heading in the preamble of a BOM page is refused';
    ok !update( '', "pre" )->{isError}, 'text is accepted';
};

subtest 'the schema says so' => sub {
    my ($tool) = grep { $_->name eq 'update_paragraph' } @{ $server->server->tools };
    like $tool->description, qr/heading/i, 'the description mentions headings';
    like $tool->description, qr/add_section/, 'and where sections are added';
    like $tool->input_schema->{properties}{content}{description}, qr/heading/i, 'content says it may hold none';
};

done_testing;
