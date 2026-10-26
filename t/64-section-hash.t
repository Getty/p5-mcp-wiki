use strict;
use warnings;
use Test::More;
use Digest::SHA qw( sha256_hex );
use Path::Tiny qw( tempdir );
use MCP::Wiki::Document;
use MCP::Wiki::TOC::Parser;
use MCP::Wiki::Server;

# Optimistic concurrency: every section has a hash (SHA-256 of the section's
# bytes on disk, heading line included), get_toc and get_paragraph show it and
# update_paragraph refuses a write whose expected_hash is stale.

my $dir = tempdir;

sub doc {
    my ($name, $bytes) = @_;
    $dir->child($name)->spew_raw($bytes);
    return MCP::Wiki::Document->new(file_path => "$dir/$name", wiki_root => "$dir");
}

my $lf = "# A\n\nbody a\n\n## B\ntext b\n";

subtest 'the hash is the SHA-256 of the section bytes on disk' => sub {
    my $doc = doc('lf.md', $lf);
    my %h = map { $_->heading_path => $_->as_hash->{hash} } $doc->get_toc;
    is $h{A},   sha256_hex("# A\n\nbody a\n\n"), 'section with its heading line and blank tail';
    is $h{'A#B'}, sha256_hex("## B\ntext b\n"),  'the last section, with its final newline';
    is $doc->get_paragraph('A')->{hash}, $h{A}, 'get_paragraph shows the same hash';
    like $h{A}, qr/\A[0-9a-f]{64}\z/, 'lower-case hex';

    my $crlf = doc('crlf.md', "# A\r\n\r\nbody\r\n## B\r\ntext\r\n");
    is $crlf->get_paragraph('A')->{hash}, sha256_hex("# A\r\n\r\nbody\r\n"), 'a CRLF page hashes its CRLF bytes';

    my $nonl = doc('nonl.md', "# A\nno newline");
    is $nonl->get_paragraph('A')->{hash}, sha256_hex("# A\nno newline"), 'no final newline, none hashed';

    my $uni = doc('uni.md', "# \xc3\x84\n\xe2\x82\xac euro\n");
    is $uni->get_paragraph("\x{c4}")->{hash}, sha256_hex("# \xc3\x84\n\xe2\x82\xac euro\n"), 'bytes, not characters';
};

subtest 'the hash follows the section, not its neighbours' => sub {
    my $doc = doc('f.md', $lf);
    my %before = map { $_->heading_path => $_->as_hash->{hash} } $doc->get_toc;
    $doc->set_paragraph('A#B', 'changed');
    my %after = map { $_->heading_path => $_->as_hash->{hash} } $doc->get_toc;
    is $after{A}, $before{A}, 'the untouched section keeps its hash';
    isnt $after{'A#B'}, $before{'A#B'}, 'the changed section has a new one';
    $doc->set_paragraph('A#B', "text b");
    is $doc->get_paragraph('A#B')->{hash}, $before{'A#B'}, 'the same bytes give the same hash again';
};

subtest 'set_paragraph with expected_hash' => sub {
    my $doc = doc('s.md', $lf);
    my $h = $doc->get_paragraph('A#B')->{hash};

    my $new = $doc->set_paragraph('A#B', 'one', expected_hash => $h);
    is $new, $doc->get_paragraph('A#B')->{hash}, 'returns the new hash of the section';
    isnt $new, $h, '... which differs from the old one';

    my $bytes = $dir->child('s.md')->slurp_raw;
    eval { $doc->set_paragraph('A#B', 'two', expected_hash => $h) };
    like $@, qr/changed since read/, 'a stale hash is refused';
    is $dir->child('s.md')->slurp_raw, $bytes, '... and nothing is written';

    ok $doc->set_paragraph('A#B', 'three', expected_hash => uc $new), 'hex case does not matter';

    eval { $doc->set_paragraph('A#B', 'x', expected_hash => 'nonsense') };
    like $@, qr/expected_hash/, 'a malformed hash is refused';
    eval { $doc->set_paragraph('A#B', 'x', expected_hash => '') };
    like $@, qr/expected_hash/, 'so is an empty one';

    ok $doc->set_paragraph('A#B', 'four'), 'without expected_hash it writes as before';
};

subtest 'Entry as_hash carries the hash only when it has one' => sub {
    my @plain = MCP::Wiki::TOC::Parser->parse_content($lf);
    ok !exists $plain[0]->as_hash->{hash}, 'the bare parser knows no hash';
    my @e = doc('e.md', $lf)->get_toc;
    like $e[0]->as_hash->{hash}, qr/\A[0-9a-f]{64}\z/, 'a document adds it';
};

subtest 'the tools' => sub {
    $dir->child('t.md')->spew_utf8($lf);
    my $server = MCP::Wiki::Server->new(wiki_root => "$dir");
    my @events;
    $server->on_change(sub { push @events, $_[0] });
    my $call = sub {
        my ($name, $args) = @_;
        my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
        return $tool->code->($tool, $args);
    };

    my $toc = $call->(get_toc => { page => 't.md' })->{structuredContent};
    my ($b) = grep { $_->{heading_path} eq 'A#B' } @{ $toc->{entries} };
    is $b->{hash}, sha256_hex("## B\ntext b\n"), 'get_toc shows the hash of every entry';
    my $para = $call->(get_paragraph => { page => 't.md', heading_path => 'A#B' })->{structuredContent};
    is $para->{hash}, $b->{hash}, 'get_paragraph shows it';

    # client B changes the section after client A has read it
    my $res = $call->(update_paragraph => { page => 't.md', heading_path => 'A#B', content => 'by B' });
    ok !$res->{isError}, 'an update without expected_hash works as before';
    is $res->{structuredContent}{hash}, $call->(get_paragraph => { page => 't.md', heading_path => 'A#B' })->{structuredContent}{hash},
        'and answers with the new hash of the section';

    my $disk = $dir->child('t.md')->slurp_raw;
    @events = ();
    $res = $call->(update_paragraph => { page => 't.md', heading_path => 'A#B', content => 'by A', expected_hash => $para->{hash} });
    ok $res->{isError}, 'client A, holding the old hash, is refused';
    like $res->{content}[0]{text}, qr/changed since read/, 'the message says why';
    is $dir->child('t.md')->slurp_raw, $disk, 'nothing is written';
    is scalar @events, 0, 'no event fires';

    my $now = $call->(get_paragraph => { page => 't.md', heading_path => 'A#B' })->{structuredContent}{hash};
    $res = $call->(update_paragraph => { page => 't.md', heading_path => 'A#B', content => 'by A', expected_hash => $now });
    ok !$res->{isError}, 'with the current hash the write goes through' or diag $res->{content}[0]{text};
    is scalar @events, 1, 'and fires its event';

    my ($tool) = grep { $_->name eq 'update_paragraph' } @{ $server->server->tools };
    my $schema = $tool->input_schema;
    is $schema->{properties}{expected_hash}{type}, 'string', 'expected_hash is in the schema';
    ok !(grep { $_ eq 'expected_hash' } @{ $schema->{required} }), '... and optional';
};

done_testing;
