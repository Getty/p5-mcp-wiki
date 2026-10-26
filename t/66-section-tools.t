use strict;
use warnings;
use Test::More;
use Digest::SHA qw( sha256_hex );
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# write_page, add_section, delete_section and rename_heading: what they write,
# what they answer, which event they fire, when they refuse.

{
    package Local::RecordingGit;
    sub new { return bless { commits => [] }, shift }
    sub auto_commit { my ( $s, $paths, $msg, @rest ) = @_; push @{ $s->{commits} }, [ $paths, $msg ]; return 1 }
}

my $GUIDE = join '', map {"$_\n"} '# Guide', '', 'intro', '', '## Setup', '', 'setup text', '',
    '### Deep', '', 'deep text', '', '## Usage', '', 'usage text', '', '# Other', '', 'other text';

my $dir = tempdir;
my $git = Local::RecordingGit->new;
my $server = MCP::Wiki::Server->new( wiki_root => "$dir", use_git => 1, git_history => $git );
my @events;
$server->on_change( sub { push @events, $_[0] } );

sub call {
    my ( $name, $args ) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    return { isError => 1, content => [ { text => "no tool $name" } ] } unless $tool;
    return $tool->code->( $tool, $args );
}
sub fresh {
    my ( $name, $text ) = @_;
    $dir->child($name)->spew_raw( $text // $GUIDE );
    @events = ();
    return $name;
}
sub disk { $dir->child( $_[0] )->slurp_utf8 }
sub paths {
    my $res = call( get_toc => { page => $_[0], include_preview => JSON::PP::false } );
    return [ map { $_->{heading_path} } @{ $res->{structuredContent}{entries} // [] } ];
}
sub err { return $_[0]{isError} ? $_[0]{content}[0]{text} : undef }
sub ok_res {
    my ( $res, $label ) = @_;
    ok( !$res->{isError}, $label ) or diag( $res->{content}[0]{text} );
    return $res->{structuredContent};
}

subtest 'add_section: last child of the parent' => sub {
    my $p = fresh('a.md');
    my $out = ok_res( call( add_section => { page => $p, parent => 'Guide', heading => 'Faq', content => 'Q and A', reason => 'why' } ),
        'accepted' );
    is $out->{heading_path}, 'Guide#Faq', 'answers with the new heading_path';
    is $out->{level}, 2, 'one level below the parent';
    is disk($p), ( $GUIDE =~ s/(# Other\n)/## Faq\nQ and A\n\n$1/r ), 'after the parent\'s last subsection, before the next sibling';
    is $out->{hash}, call( get_paragraph => { page => $p, heading_path => 'Guide#Faq' } )->{structuredContent}{hash},
        'and with the hash of the new section';
    is_deeply [ @{ $events[0] // {} }{qw( type page heading_path reason )} ], [ 'add_section', $p, 'Guide#Faq', 'why' ], 'event';
    is_deeply [ @{ $git->{commits}[-1] // [] } ], [ [$p], "Added section: $p (Guide#Faq)" ], 'committed with a generated message';
    is_deeply paths($p), [ 'Guide', 'Guide#Setup', 'Guide#Setup#Deep', 'Guide#Usage', 'Guide#Faq', 'Other' ], 'the other addresses stay';

    $p = fresh('a.md');
    $out = ok_res( call( add_section => { page => $p, parent => 'Guide#Setup', heading => 'Extra' } ), 'below a level 2 section' );
    is $out->{heading_path}, 'Guide#Setup#Extra', 'a level 3 section';
    is $out->{level}, 3, 'level is parent + 1';
    like disk($p), qr/deep text\n\n### Extra\n\n## Usage/, 'after the subtree of the parent, without a body';
};

subtest 'add_section: top level and before' => sub {
    my $p = fresh('a.md');
    my $out = ok_res( call( add_section => { page => $p, parent => '', heading => 'Last', content => 'x' } ), 'top level' );
    is $out->{heading_path}, 'Last', 'a root path';
    is $out->{level}, 1, 'level 1';
    is disk($p), $GUIDE . "# Last\nx\n", 'at the end of the page';

    $p = fresh('a.md');
    $out = ok_res( call( add_section => { page => $p, heading => 'Last2' } ), 'parent defaults to the top level' );
    is $out->{heading_path}, 'Last2', 'the same';

    $p = fresh('a.md');
    $out = ok_res( call( add_section => { page => $p, parent => 'Guide', before => 'Guide#Usage', heading => 'Mid', content => 'm' } ),
        'before a sibling' );
    is $out->{heading_path}, 'Guide#Mid', 'path under the parent';
    is_deeply paths($p), [ 'Guide', 'Guide#Setup', 'Guide#Setup#Deep', 'Guide#Mid', 'Guide#Usage', 'Other' ], 'in front of it';
    like disk($p), qr/deep text\n\n## Mid\nm\n\n## Usage\n/, 'text';

    $p = fresh('a.md');
    $out = ok_res( call( add_section => { page => $p, parent => '', before => 'Guide', heading => 'First' } ), 'top level, before the first' );
    is_deeply paths($p), [ 'First', 'Guide', 'Guide#Setup', 'Guide#Setup#Deep', 'Guide#Usage', 'Other' ], 'first on the page';

    $p = fresh( 'empty.md', '' );
    ok_res( call( add_section => { page => $p, heading => 'H', content => 'c' } ), 'to an empty page' );
    is disk($p), "# H\nc\n", 'it starts the page';

    $p = fresh( 'plain.md', "just text\n" );
    ok_res( call( add_section => { page => $p, heading => 'H' } ), 'to a page without headings' );
    is disk($p), "just text\n# H\n", 'after the text';

    $p = fresh( 'crlf.md', "# A\r\ntext\r\n" );
    ok_res( call( add_section => { page => $p, parent => 'A', heading => 'B', content => "x\ny" } ), 'to a CRLF page' );
    is $dir->child($p)->slurp_raw, "# A\r\ntext\r\n## B\r\nx\r\ny\r\n", 'written with CRLF';
};

subtest 'add_section: refusals' => sub {
    my $p = fresh('a.md');
    my $before = disk($p);
    my %base = ( page => $p, heading => 'New' );
    my @bad = (
        [ 'unknown parent'            => { %base, parent => 'Nope' }, qr/Heading not found/ ],
        [ 'unknown before'            => { %base, parent => 'Guide', before => 'Guide#Nope' }, qr/Heading not found/ ],
        [ 'before is not a child'     => { %base, parent => 'Guide', before => 'Guide#Setup#Deep' }, qr/child|sibling/i ],
        [ 'before under another parent' => { %base, parent => 'Other', before => 'Guide#Usage' }, qr/child|sibling/i ],
        [ 'before without a parent'   => { %base, before => 'Guide#Usage' }, qr/child|sibling/i ],
        [ 'empty heading'             => { %base, heading => '  ' }, qr/heading/i ],
        [ 'heading with a line break' => { %base, heading => "A\nB" }, qr/line/i ],
        [ 'heading the parser reads differently' => { %base, heading => 'Foo #' }, qr/heading/i ],
        [ 'heading made of #'         => { %base, heading => '#' }, qr/heading/i ],
        [ 'would change an address'   => { %base, parent => 'Guide', before => 'Guide#Usage', heading => 'Usage' }, qr/address/i ],
        [ 'content with a heading'    => { %base, parent => 'Guide', content => "x\n## Sneaky\ny" }, qr/heading/i ],
        [ 'content with an open fence' => { %base, parent => 'Guide', content => "```\ncode" }, qr/fence/i ],
        [ 'missing page'              => { page => 'nope.md', heading => 'X' }, qr/not found|Invalid/i ],
    );
    for my $b (@bad) {
        my $e = err( call( add_section => $b->[1] ) );
        like $e // '', $b->[2], "$b->[0]: refused";
        is disk($p), $before, '... nothing written';
    }
    is scalar @events, 0, 'no event for any of them';
    ok !$dir->child('nope.md')->exists, 'no page is created';

    my $deep = fresh( 'deep.md', join '', map {"$_\n"} '# 1', '## 2', '### 3', '#### 4', '##### 5', '###### 6' );
    like err( call( add_section => { page => $deep, parent => '1#2#3#4#5#6', heading => 'Seven' } )) // '', qr/level/i, 'nothing below level 6';

    my $root2 = fresh( 'root2.md', "## X\ntext\n" );
    like err( call( add_section => { page => $root2, before => 'X', heading => 'Y' } )) // '', qr/child|level|adopt/i,
        'a level 1 heading before a level 2 one would make it a child';

    my $ok = fresh('a.md');
    my $out = ok_res( call( add_section => { page => $ok, parent => 'Guide', heading => 'Usage' } ), 'a duplicate heading at the end' );
    is $out->{heading_path}, 'Guide#Usage[2]', 'gets the occurrence suffix';
    $out = ok_res( call( add_section => { page => $ok, parent => 'Guide', heading => 'C#' } ), 'a # in the text' );
    is $out->{heading_path}, 'Guide#C\#', 'is escaped in the path';
    ok_res( call( add_section => { page => $ok, parent => 'Guide', heading => 'Code', content => "```\n# not a heading\n```" } ),
        'a heading inside a closed fence is no heading' );
};

subtest 'delete_section' => sub {
    my $p = fresh('a.md');
    my $out = ok_res( call( delete_section => { page => $p, heading_path => 'Guide#Setup', reason => 'r' } ), 'accepted' );
    is_deeply $out->{removed} // [], [ 'Guide#Setup', 'Guide#Setup#Deep' ], 'removes the section and its subsections';
    is disk($p), join( '', map {"$_\n"} '# Guide', '', 'intro', '', '## Usage', '', 'usage text', '', '# Other', '', 'other text' ),
        'heading and text are gone';
    is_deeply [ @{ $events[0] // {} }{qw( type page heading_path reason )} ], [ 'delete_section', $p, 'Guide#Setup', 'r' ], 'event';
    is_deeply [ @{ $git->{commits}[-1] // [] } ], [ [$p], "Deleted section: $p (Guide#Setup)" ], 'committed';

    $p = fresh('a.md');
    ok_res( call( delete_section => { page => $p, heading_path => 'Other' } ), 'the last section' );
    is disk($p), ( $GUIDE =~ s/# Other\n\nother text\n//r ), 'cut off the end';

    $p = fresh('a.md');
    my $h = call( get_paragraph => { page => $p, heading_path => 'Guide#Usage' } )->{structuredContent}{hash};
    call( update_paragraph => { page => $p, heading_path => 'Guide#Usage', content => 'changed by B' } );
    my $now = disk($p);
    @events = ();
    like err( call( delete_section => { page => $p, heading_path => 'Guide#Usage', expected_hash => $h } )) // '',
        qr/changed since read/, 'a stale expected_hash is refused';
    is disk($p), $now, '... nothing written';
    is scalar @events, 0, '... no event';
    $h = call( get_paragraph => { page => $p, heading_path => 'Guide#Usage' } )->{structuredContent}{hash};
    ok_res( call( delete_section => { page => $p, heading_path => 'Guide#Usage', expected_hash => $h } ), 'the current one is accepted' );

    $p = fresh('a.md');
    like err( call( delete_section => { page => $p, heading_path => 'Guide#Nope' } )) // '', qr/Heading not found/, 'unknown path';
    like err( call( delete_section => { page => $p, heading_path => '' } )) // '', qr/preamble/i, 'the preamble is not a section';
    is disk($p), $GUIDE, 'nothing written';

    $p = fresh( 'dups.md', "# P\n## N\na\n## N\nb\n" );
    ok_res( call( delete_section => { page => $p, heading_path => 'P#N[2]' } ), 'a later duplicate' );
    is disk($p), "# P\n## N\na\n", 'only that one goes';
};

subtest 'rename_heading' => sub {
    my $p = fresh('a.md');
    my $out = ok_res( call( rename_heading => { page => $p, heading_path => 'Guide#Setup', heading => 'Install', reason => 'r' } ), 'accepted' );
    is $out->{heading_path}, 'Guide#Install', 'answers with the new path';
    is $out->{previous_heading_path}, 'Guide#Setup', 'and the old one';
    is disk($p), ( $GUIDE =~ s/## Setup/## Install/r ), 'only the heading line changes, its level stays';
    is_deeply paths($p), [ 'Guide', 'Guide#Install', 'Guide#Install#Deep', 'Guide#Usage', 'Other' ], 'its subsections move with it';
    is $out->{hash}, call( get_paragraph => { page => $p, heading_path => 'Guide#Install' } )->{structuredContent}{hash}, 'hash of the renamed section';
    is_deeply [ @{ $events[0] // {} }{qw( type page heading_path previous_heading_path reason )} ],
        [ 'rename_heading', $p, 'Guide#Install', 'Guide#Setup', 'r' ], 'event';
    is_deeply [ @{ $git->{commits}[-1] // [] } ], [ [$p], "Renamed heading: $p (Guide#Install)" ], 'committed';

    $p = fresh('a.md');
    $out = ok_res( call( rename_heading => { page => $p, heading_path => 'Guide#Setup', heading => 'Usage' } ), 'to a name a sibling has' );
    is $out->{heading_path}, 'Guide#Usage', 'the earlier one takes the plain address';
    is_deeply paths($p), [ 'Guide', 'Guide#Usage', 'Guide#Usage#Deep', 'Guide#Usage[2]', 'Other' ], 'the other becomes [2]';

    $p = fresh( 'x.md', "  ## Old ##\ntext\n" );
    $out = ok_res( call( rename_heading => { page => $p, heading_path => 'Old', heading => '  New one  ' } ), 'whitespace trimmed' );
    is disk($p), "## New one\ntext\n", 'the line is rewritten with the same level';

    $p = fresh('a.md');
    my $before = disk($p);
    my $h = call( get_paragraph => { page => $p, heading_path => 'Other' } )->{structuredContent}{hash};
    call( update_paragraph => { page => $p, heading_path => 'Other', content => 'B was here' } );
    $before = disk($p);
    @events = ();
    like err( call( rename_heading => { page => $p, heading_path => 'Other', heading => 'Z', expected_hash => $h } )) // '',
        qr/changed since read/, 'stale hash refused';
    is disk($p), $before, '... nothing written';

    for my $bad ( [ 'unknown path' => { heading_path => 'Nope', heading => 'Z' }, qr/Heading not found/ ],
                  [ 'the preamble' => { heading_path => '', heading => 'Z' }, qr/preamble/i ],
                  [ 'empty' => { heading_path => 'Other', heading => ' ' }, qr/heading/i ],
                  [ 'line break' => { heading_path => 'Other', heading => "a\nb" }, qr/line/i ],
                  [ 'closing hashes' => { heading_path => 'Other', heading => 'a #' }, qr/heading/i ] ) {
        like err( call( rename_heading => { page => $p, %{ $bad->[1] } } )) // '', $bad->[2], "$bad->[0]: refused";
    }
    is disk($p), $before, 'nothing written by any of them';
    is scalar @events, 0, 'no event';
};

subtest 'add_section touches no other section' => sub {
    my %layouts = (
        compact      => "# Page\n## Notes\nalpha\n## Other\nbeta\n",
        'blank lines' => "# Page\n\n## Notes\n\nalpha\n\n## Other\n\nbeta\n",
        'preamble only' => "nur text\n",
        'preamble and a heading' => "nur text\n\n# Eins\ntext\n",
        'no final newline' => "# Page\n## Notes\nalpha",
        'trailing blank lines' => "# Page\n## Notes\nalpha\n\n\n",
    );
    my @adds = (
        [ 'last child of the first'  => { parent => 'Page' } ],
        [ 'in front of a sibling'    => { parent => 'Page', before => 'Page#Other' } ],
        [ 'in front of the first'    => { parent => 'Page', before => 'Page#Notes' } ],
        [ 'below a leaf'             => { parent => 'Page#Notes' } ],
        [ 'at the top level'         => { parent => '' } ],
    );
    for my $layout ( sort keys %layouts ) {
        for my $add (@adds) {
            my $label = "$layout, $add->[0]";
            my $text = $layouts{$layout};
            my $p = fresh( 'lay.md', $text );
            my %args = %{ $add->[1] };
            my %have = map { ( $_ => 1 ) } @{ paths($p) };
            next if grep { length && !$have{$_} } grep { defined } @args{qw( parent before )};
            my %before = map { ( $_->{heading_path} => $_->{hash} ) } @{ call( get_toc => { page => $p } )->{structuredContent}{entries} // [] };
            my $pre = call( get_paragraph => { page => $p, heading_path => '' } )->{structuredContent}{hash};

            my $out = ok_res( call( add_section => { page => $p, heading => 'Neu', content => "gamma\n", %args } ), "$label: added" );
            my %after = map { ( $_->{heading_path} => $_->{hash} ) } @{ call( get_toc => { page => $p } )->{structuredContent}{entries} // [] };
            my $new = $out->{heading_path} // '';
            # the one exception: a last line that lacked its newline gets it
            if ( $layout ne 'no final newline' ) {
                is_deeply { map { ( $_ => $after{$_} ) } grep { $_ ne $new } keys %after }, \%before,
                    "$label: every other section keeps its hash";
            }
            is call( get_paragraph => { page => $p, heading_path => '' } )->{structuredContent}{hash}, $pre,
                "$label: and so does the preamble";

            ok_res( call( delete_section => { page => $p, heading_path => $new } ), "$label: deleted again" );
            is disk($p), $text, "$label: add then delete gives the original bytes";
        }
    }

    # a line that lacks its newline gets exactly that newline
    my $p = fresh( 'nonl.md', "# A\nx" );
    ok_res( call( add_section => { page => $p, parent => 'A', heading => 'B' } ), 'added after a last line without newline' );
    is disk($p), "# A\nx\n## B", 'the one newline is added, nothing else';
};

subtest 'write_page' => sub {
    my $p = fresh('a.md');
    my $out = ok_res( call( write_page => { page => $p, content => "# New\n\nall new\n", reason => 'r' } ), 'accepted' );
    is disk($p), "# New\n\nall new\n", 'replaces the whole page';
    is $out->{hash}, sha256_hex("# New\n\nall new\n"), 'answers with the hash of the page';
    is_deeply [ @{ $events[0] // {} }{qw( type page reason )} ], [ 'write', $p, 'r' ], 'event';
    is_deeply [ @{ $git->{commits}[-1] // [] } ], [ [$p], "Wrote page: $p" ], 'committed';

    $p = fresh( 'crlf.md', "# A\r\nx\r\n" );
    ok_res( call( write_page => { page => $p, content => "# B\ny\n" } ), 'on a CRLF page' );
    is $dir->child($p)->slurp_raw, "# B\r\ny\r\n", 'it keeps its line ending';

    $p = fresh('a.md');
    my $h = call( get_page => { page => $p } )->{structuredContent}{hash};
    call( update_paragraph => { page => $p, heading_path => 'Other', content => 'B was here' } );
    my $now = disk($p);
    @events = ();
    like err( call( write_page => { page => $p, content => 'mine', expected_hash => $h } )) // '', qr/changed since read/, 'stale hash refused';
    is disk($p), $now, '... nothing written';
    is scalar @events, 0, '... no event';
    $h = call( get_page => { page => $p } )->{structuredContent}{hash};
    ok_res( call( write_page => { page => $p, content => 'mine', expected_hash => $h } ), 'the current hash is accepted' );

    like err( call( write_page => { page => 'missing.md', content => 'x' } )) // '', qr/not found/i, 'a missing page is an error';
    ok !$dir->child('missing.md')->exists, 'and not created';
    ok_res( call( write_page => { page => $p, content => '' } ), 'empty content is allowed' );
    is disk($p), '', 'it empties the page';
};

subtest 'schemas' => sub {
    my %spec = (
        write_page     => [ [qw( page content )], [qw( reason expected_hash )] ],
        add_section    => [ [qw( page heading )], [qw( parent before content reason )] ],
        delete_section => [ [qw( page heading_path )], [qw( reason expected_hash )] ],
        rename_heading => [ [qw( page heading_path heading )], [qw( reason expected_hash )] ],
    );
    for my $name ( sort keys %spec ) {
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        ok $tool, "$name is registered" or next;
        my $schema = $tool->input_schema;
        is_deeply [ sort @{ $schema->{required} // [] } ], [ sort @{ $spec{$name}[0] } ], "$name: required";
        is_deeply [ sort keys %{ $schema->{properties} } ], [ sort @{ $spec{$name}[0] }, @{ $spec{$name}[1] } ], "$name: all arguments";
        ok !$tool->annotations->{readOnlyHint}, "$name writes";
        ok length( $schema->{properties}{$_}{description} // '' ), "$name.$_ is described" for keys %{ $schema->{properties} };
    }
    my ($d) = grep { $_->name eq 'delete_section' } @{ $server->server->tools };
    ok $d && $d->annotations->{destructiveHint}, 'delete_section is destructive';
};

done_testing;
