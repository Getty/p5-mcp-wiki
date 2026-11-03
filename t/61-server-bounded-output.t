#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use JSON::PP ();
use MCP::Wiki::Server;

# list_pages takes an optional prefix (a directory below the root) and get_toc
# the optional max_level and include_preview. Without them the answers are what
# they always were; with them they get shorter and no address changes.

my $can_symlink = eval { symlink( '', '' ); 1 };
my $base = tempdir;
my $wiki = $base->child('wiki');
$wiki->child($_)->mkpath for qw( projects/alpha projects/beta other locked .git );
$base->child('elsewhere')->mkpath;
$wiki->child($_)->spew_utf8("# T\n") for
    qw( top.md projects/p.md projects/alpha/a.md projects/alpha/a2.md projects/beta/b.md other/o.md .git/g.md );
$base->child( 'elsewhere', 'leak.md' )->spew_utf8("# Leak\n");
$wiki->child( 'locked', 'hidden.md' )->spew_utf8("# H\n");
if ($can_symlink) {
    symlink '../elsewhere', $wiki->child('out') or die "symlink: $!";
    symlink 'projects',     $wiki->child('alias') or die "symlink: $!";
}

my $server = MCP::Wiki::Server->new( wiki_root => "$wiki" );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    BAIL_OUT("no tool $name") unless $tool;
    my $res = eval { $tool->code->( $tool, $args ) };
    return $res // { isError => 1, content => [ { text => "DIED: $@" } ] };
}
sub data { return $_[0]{structuredContent} }

# -- list_pages
my @all = qw(
    locked/hidden.md other/o.md projects/alpha/a.md projects/alpha/a2.md
    projects/beta/b.md projects/p.md top.md
);
my $res = call( list_pages => {} );
is_deeply( data($res)->{pages}, \@all, 'without a prefix the whole wiki is listed' );

for my $same ( '', '.', './', '/' ) {
    is_deeply( data( call( list_pages => { prefix => $same } ) )->{pages}, \@all,
        "prefix '$same' is the whole wiki" );
}

$res = call( list_pages => { prefix => 'projects' } );
is_deeply( data($res)->{pages}, [qw( projects/alpha/a.md projects/alpha/a2.md projects/beta/b.md projects/p.md )],
    'a prefix lists only the pages below it, named relative to the root' );
is( data($res)->{count}, 4, 'count follows' );

for my $spelling ( 'projects/', 'projects//', './projects', 'other/../projects' ) {
    is_deeply( data( call( list_pages => { prefix => $spelling } ) )->{pages}, data($res)->{pages},
        "prefix '$spelling' means the same directory" );
}
is_deeply( data( call( list_pages => { prefix => 'projects/alpha' } ) )->{pages},
    [qw( projects/alpha/a.md projects/alpha/a2.md )], 'a nested prefix' );
is_deeply( data( call( list_pages => { prefix => 'projects/alpha/' } ) )->{pages},
    [qw( projects/alpha/a.md projects/alpha/a2.md )], 'a trailing slash is harmless' );

# the walk stays inside the prefix: a directory elsewhere that cannot be read
# is not even tried
SKIP: {
    chmod 0, $wiki->child('locked');
    skip 'directory stays readable (running as root?)', 2 if -r $wiki->child('locked');
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    call( list_pages => {} );
    is( scalar @warn, 1, 'without a prefix the unreadable directory is reported' );
    @warn = ();
    call( list_pages => { prefix => 'projects' } );
    is( scalar @warn, 0, 'with a prefix the walk never goes there' );
    chmod 0755, $wiki->child('locked');
}

# the prefix is checked like a page name
my @bad = (
    [ '..'                  => 'leaves the root' ],
    [ '../elsewhere'        => 'sibling directory' ],
    [ 'projects/../..'      => 'dot-dot out of the root' ],
    [ '.git'                => 'the repository' ],
    [ 'projects/.GIT'       => 'the repository in any case' ],
    [ 'top.md'              => 'a page is no directory' ],
    [ 'nowhere'             => 'a directory that does not exist' ],
    [ "projects\0"          => 'a NUL byte' ],
);
push @bad, [ out => 'a directory symlink leaving the root' ], [ alias => 'a directory symlink inside' ],
    [ 'alias/alpha' => 'a path through a directory symlink' ] if $can_symlink;
for my $case (@bad) {
    my $r = call( list_pages => { prefix => $case->[0] } );
    ok( $r->{isError}, "prefix refused: $case->[1]" ) or diag explain data($r);
    unlike( $r->{content}[0]{text} // '', qr/leak\.md|\Q$base\E|g\.md/, '... and names nothing outside' );
}

# -- get_toc
$wiki->child('doc.md')->spew_utf8(<<'MD');
# One
text one
## Two
text two
### Three
text three
#### Four
text four
## Two B
more
# Other
end
MD

$res = call( get_toc => { page => 'doc.md' } );
my @full = @{ data($res)->{entries} };
is( scalar @full, 6, 'default: all headings' );
ok( ( !grep { !defined $_->{content_preview} } @full ), 'default: every entry has its preview' );
is_deeply( [ sort keys %{ $full[0] } ],
    [qw( anchor char_count content_preview hash heading heading_path level line_end line_start )],
    'default: the entry has all its keys' );

for my $true ( JSON::PP::true, 1 ) {
    my @e = @{ data( call( get_toc => { page => 'doc.md', include_preview => $true } ) )->{entries} };
    is_deeply( \@e, \@full, 'include_preview true is the default' );
}

for my $off ( JSON::PP::false, 0 ) {
    my @e = @{ data( call( get_toc => { page => 'doc.md', include_preview => $off } ) )->{entries} };
    is( scalar @e, 6, 'include_preview false keeps every entry' );
    ok( ( !grep { exists $_->{content_preview} } @e ), 'include_preview false leaves the preview out' );
    my @rest = map { my %h = %$_; delete $h{content_preview}; \%h } @full;
    is_deeply( \@e, \@rest, 'everything else is unchanged' );
}

my %expect = ( 1 => 2, 2 => 4, 3 => 5, 4 => 6, 5 => 6, 6 => 6 );
for my $max ( sort keys %expect ) {
    my @e = @{ data( call( get_toc => { page => 'doc.md', max_level => $max } ) )->{entries} };
    is( scalar @e, $expect{$max}, "max_level $max keeps the headings down to that level" );
    ok( ( !grep { $_->{level} > $max } @e ), '... and none deeper' );
    is_deeply( \@e, [ grep { $_->{level} <= $max } @full ], '... unchanged, heading_path and lines included' );
}

my @both = @{ data( call( get_toc => { page => 'doc.md', max_level => 2, include_preview => JSON::PP::false } ) )->{entries} };
is_deeply( [ map { $_->{heading_path} } @both ], [ 'One', 'One#Two', 'One#Two B', 'Other' ],
    'both together' );

for my $bad ( 0, 7, -1, 'x', '2.5', '', [], {} ) {
    my $r = call( get_toc => { page => 'doc.md', max_level => $bad } );
    ok( $r->{isError}, 'max_level ' . ( ref $bad || "'$bad'" ) . ' is refused' );
    like( $r->{content}[0]{text}, qr/max_level/, '... naming the argument' );
}

# a section that max_level hides is still addressed by its heading_path
$res = call( get_paragraph => { page => 'doc.md', heading_path => 'One#Two#Three#Four' } );
ok( !$res->{isError}, 'a hidden deeper section is still addressable' );

# -- the schemas
my %schema = map { $_->name => $_->input_schema } @{ $server->server->tools };
is( $schema{list_pages}{properties}{prefix}{type}, 'string', 'list_pages declares prefix' );
is( $schema{get_toc}{properties}{max_level}{type}, 'integer', 'get_toc declares max_level' );
is_deeply( [ @{ $schema{get_toc}{properties}{max_level} }{qw( minimum maximum )} ], [ 1, 6 ], '... with its range' );
is( $schema{get_toc}{properties}{include_preview}{type}, 'boolean', 'get_toc declares include_preview' );
is_deeply( $schema{get_toc}{required}, ['page'], 'page stays the only required argument' );
ok( !$schema{list_pages}{required}, 'list_pages requires nothing' );
for my $arg ( [ list_pages => 'prefix' ], [ get_toc => 'max_level' ], [ get_toc => 'include_preview' ] ) {
    ok( length( $schema{ $arg->[0] }{properties}{ $arg->[1] }{description} // '' ), "$arg->[0] $arg->[1] is described" );
}

done_testing;
