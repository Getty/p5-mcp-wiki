#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# search_pages: a plain, case-insensitive substring search over the pages
# list_pages offers, with the section each match is in.

binmode Test::More->builder->$_, ':utf8' for qw( output failure_output todo_output );

my $base = tempdir;
my $wiki = $base->child('wiki');
$wiki->child($_)->mkpath for qw( sub/deep .git );
$base->child('outside.md')->spew_utf8("# Out\nNeedle outside\n");
$wiki->child('a.md')->spew_utf8("# Alpha\n\nThe Needle is here\n\n## Sub\n   needle again   \nnothing\n");
$wiki->child('pre.md')->spew_utf8("---\ntitle: needle\n---\nintro\n\n# H\n");
$wiki->child('plain.md')->spew_utf8("no heading, only NEEDLE\n");
$wiki->child( 'sub', 'b.md' )->spew_utf8("# B\nneedle in b\n");
$wiki->child( 'sub', 'deep', 'c.md' )->spew_utf8("# C\nneedle in c\n");
$wiki->child('none.md')->spew_utf8("# None\nnothing here\n");
$wiki->child('data.txt')->spew_utf8("needle in a text file\n");
$wiki->child( '.git', 'x.md' )->spew_utf8("# Git\nneedle in git\n");
my $can_symlink = eval { symlink( '../outside.md', "$wiki/leak.md" ) && symlink( '../', "$wiki/out" ) };

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );
sub search {
    my ($args) = @_;
    my ($tool) = grep { $_->name eq 'search_pages' } @{ $server->server->tools };
    return { isError => 1, content => [ { text => 'no tool search_pages' } ] } unless $tool;
    return $tool->code->( $tool, $args );
}
sub found {
    my ($args) = @_;
    my $res = search($args);
    ok( !$res->{isError}, 'answers' ) or diag( $res->{content}[0]{text} );
    return $res->{structuredContent} // {};
}
sub where { return [ map {; "$_->{page}:$_->{line}" } @{ $_[0]{matches} // [] } ] }

subtest 'matches' => sub {
    my $r = found( { query => 'nEEdle' } );
    is_deeply where($r), [ 'a.md:3', 'a.md:6', 'plain.md:1', 'pre.md:2', 'sub/b.md:2', 'sub/deep/c.md:2' ],
        'every line with the text, ignoring case, pages in order, none from .git, data.txt or outside';
    is $r->{count}, 6, 'count';
    ok !$r->{truncated}, 'not truncated';
    is $r->{limit}, 50, 'the default limit is 50';
    my %m = map {; "$_->{page}:$_->{line}" => $_ } @{ $r->{matches} };
    is $m{'a.md:3'}{heading_path}, 'Alpha', 'the section of the line';
    is $m{'a.md:6'}{heading_path}, 'Alpha#Sub', 'also a nested one';
    is $m{'a.md:6'}{snippet}, 'needle again', 'the snippet is trimmed';
    is $m{'plain.md:1'}{heading_path}, '', 'no heading: empty path';
    is $m{'pre.md:2'}{heading_path}, '', 'front matter is in the preamble';
    is_deeply [ sort keys %{ $m{'a.md:3'} } ], [qw( heading_path line page snippet )], 'the keys';
};

subtest 'plain string, Unicode' => sub {
    $wiki->child('re.md')->spew_utf8("# R\nabc and a.c and (x) and [y]\nÜber alles\n");
    is_deeply where( found( { query => 'a.c' } ) ), ['re.md:2'], '. is a dot, not a pattern';
    is_deeply where( found( { query => '(x)' } ) ), ['re.md:2'], 'brackets are text';
    is_deeply where( found( { query => '[y]' } ) ), ['re.md:2'], '... all of them';
    is_deeply where( found( { query => 'ÜBER' } ) ), ['re.md:3'], 'case folding works beyond ASCII';
    $wiki->child('re.md')->remove;
};

subtest 'snippet' => sub {
    $wiki->child('long.md')->spew_utf8( "# L\n" . ( 'x' x 300 ) . ' FINDME ' . ( 'y' x 300 ) . "\n" );
    my ($m) = @{ found( { query => 'findme' } )->{matches} };
    ok length( $m->{snippet} // '' ) <= 166, 'a long line is cut' or diag length $m->{snippet};
    like $m->{snippet}, qr/\A\.\.\..*FINDME.*\.\.\.\z/, 'with marks where it was cut, and the match inside';
    $wiki->child('long.md')->remove;
};

subtest 'prefix' => sub {
    is_deeply where( found( { query => 'needle', prefix => 'sub' } ) ), [ 'sub/b.md:2', 'sub/deep/c.md:2' ],
        'only below the directory';
    is_deeply where( found( { query => 'needle', prefix => 'sub/deep' } ) ), ['sub/deep/c.md:2'], 'deeper';
    for my $bad ( '../', '../outside', '.git', 'sub/../../x', 'nope', 'a.md', ( $can_symlink ? 'out' : () ) ) {
        my $res = search( { query => 'needle', prefix => $bad } );
        ok $res->{isError}, "prefix '$bad' is refused";
        unlike $res->{content}[0]{text}, qr/Needle outside|needle in git/, '... without a leak';
    }
};

subtest 'limit' => sub {
    my $r = found( { query => 'needle', limit => 2 } );
    is_deeply where($r), [ 'a.md:3', 'a.md:6' ], 'the first ones';
    is $r->{limit}, 2, 'the limit is reported';
    ok $r->{truncated}, 'truncated says there were more';

    $r = found( { query => 'needle', limit => 6 } );
    is $r->{count}, 6, 'as many as there are';
    ok !$r->{truncated}, 'exactly the limit is not truncated';

    $wiki->child('many.md')->spew_utf8( "# M\n" . join( '', map {"needle $_\n"} 1 .. 60 ) );
    $r = found( { query => 'needle', prefix => '' } );
    is $r->{count}, 50, 'the default limit holds';
    ok $r->{truncated}, 'and says so';
    $wiki->child('many.md')->remove;

    $r = found( { query => 'zzz-not-there' } );
    is_deeply $r->{matches}, [], 'no match: an empty list';
    ok !$r->{truncated}, 'not truncated';
};

subtest 'refusals' => sub {
    for my $bad (
        [ 'empty query'     => { query => '' } ],
        [ 'line break'      => { query => "a\nb" } ],
        [ 'no query'        => {} ],
        [ 'limit 0'         => { query => 'x', limit => 0 } ],
        [ 'limit too big'   => { query => 'x', limit => 501 } ],
        [ 'limit not a number' => { query => 'x', limit => 'many' } ],
        [ 'root_dir'        => { query => 'x', root_dir => "$base" } ],
    ) {
        ok search( $bad->[1] )->{isError}, "$bad->[0]: refused";
    }
};

subtest 'schema' => sub {
    my ($tool) = grep { $_->name eq 'search_pages' } @{ $server->server->tools };
    ok $tool, 'registered' or return;
    ok $tool->annotations->{readOnlyHint}, 'read-only';
    is_deeply [ sort keys %{ $tool->input_schema->{properties} } ], [qw( limit prefix query )], 'arguments';
    is_deeply $tool->input_schema->{required}, ['query'], 'only query is required';
};

done_testing;
