use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use JSON::MaybeXS qw( decode_json );
use MCP::Wiki::Server;
use MCP::Wiki::TOC::Parser;

my $md = join "\n", '# Page', '## Notes', 'first', '## Other', '## Notes', 'second',
    '### Sub', 'deep', '## Notes', 'third', '# Page', '## Notes', 'again', '';

my @e = MCP::Wiki::TOC::Parser->parse_content($md);
is_deeply [map { $_->heading_path } @e], [
    'Page', 'Page#Notes', 'Page#Other', 'Page#Notes[2]', 'Page#Notes[2]#Sub',
    'Page#Notes[3]', 'Page[2]', 'Page[2]#Notes',
], 'later duplicates get [n] on their last segment; the first keeps its address';
is $e[3]->heading, 'Notes', 'the heading text has no suffix';
is_deeply [MCP::Wiki::TOC::Parser->split_heading_path('Page#Notes[2]')], [['Page', 'Notes'], 2],
    'split_heading_path reads the suffix';

# the tools reach every duplicate
my $dir = tempdir;
$dir->child('p.md')->spew_utf8($md);
my $server = MCP::Wiki::Server->new(wiki_root => "$dir");
sub call {
    my ($name, $args) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    return $tool->code->($tool, $args);
}
sub data { decode_json($_[0]{content}[0]{text}) }

my $toc = data(call('get_toc', { page => 'p.md' }));
is_deeply [map { $_->{heading_path} } @{ $toc->{toc} // $toc->{entries} // [] }],
    [map { $_->heading_path } @e], 'get_toc lists the suffixed addresses';

is data(call('get_paragraph', { page => 'p.md', heading_path => 'Page#Notes[2]' }))->{content},
    "second", 'get_paragraph reaches the 2nd duplicate';
is data(call('get_paragraph', { page => 'p.md', heading_path => 'Page#Notes' }))->{content},
    "first", '... and the unsuffixed path is still the first';

my $r = call('update_paragraph', { page => 'p.md', heading_path => 'Page#Notes[3]', content => 'changed' });
ok !$r->{isError}, 'update_paragraph accepts the 3rd duplicate';
is $dir->child('p.md')->slurp_utf8, join("\n", '# Page', '## Notes', 'first', '## Other', '## Notes',
    'second', '### Sub', 'deep', '## Notes', 'changed', '# Page', '## Notes', 'again', ''),
    'only the addressed duplicate changed';

# history tools: the commits are asked for the suffixed path unchanged
my @asked;
{
    package Stub;
    sub new { bless {}, shift }
    sub get_section_commits { shift; push @asked, ['commits', @_]; [] }
    sub restore_section     { shift; push @asked, ['restore', @_]; die "stub\n" }
    sub auto_commit         { 1 }
}
my $gs = MCP::Wiki::Server->new(wiki_root => "$dir", use_git => 1, git_history => Stub->new);
my ($t) = grep { $_->name eq 'get_section_history' } @{ $gs->server->tools };
$t->code->($t, { page => 'p.md', heading_path => 'Page#Notes[2]' });
is_deeply $asked[0], ['commits', 'p.md', 'Page#Notes[2]'], 'get_section_history passes the suffixed path on';

done_testing;
