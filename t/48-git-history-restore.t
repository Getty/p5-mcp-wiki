use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;
use MCP::Wiki::Git::History;

# restore_section splices the historic section into the current document and
# must leave everything outside that section byte-identical: the final newline,
# trailing blank lines and the blank line before the next heading. History
# works on LF text. The splice is exercised without a repository by a History whose historic section is fixed.

{
    package Local::FixedHistory;
    use Moo;
    extends 'MCP::Wiki::Git::History';
    has section => ( is => 'rw' );
    sub get_section_content_at_commit {
        my ($self) = @_;
        return { content => $self->section, heading => 'x', line_start => 1, line_end => 1 };
    }
}

my $git = Local::FixedHistory->new( wiki_root => '/nonexistent-for-this-test' );

sub restored {
    my ( $current, $section, $path ) = @_;
    $git->section($section);
    my $res = eval { $git->restore_section( 'page.md', $path // 'A#Alpha', 'abc123', { current_content => $current } ) };
    fail("restore_section died: $@") unless $res;
    return $res ? $res->{content} : undef;
}

my $old = "## Alpha\nold";

is( restored( "# A\n## Alpha\nnew\n## Beta\nb\n", $old ),
    "# A\n## Alpha\nold\n## Beta\nb\n", 'middle section, directly followed by the next heading' );

is( restored( "# A\n## Alpha\nnew\n\n## Beta\nb\n", $old ),
    "# A\n## Alpha\nold\n\n## Beta\nb\n", 'the blank line before the next heading stays' );

is( restored( "# A\n## Alpha\nnew\n\n\n## Beta\nb\n", $old ),
    "# A\n## Alpha\nold\n\n\n## Beta\nb\n", 'several blank lines before the next heading stay' );

is( restored( "# A\n## Beta\nb\n## Alpha\nnew\n", $old ),
    "# A\n## Beta\nb\n## Alpha\nold\n", 'last section keeps the final newline' );

is( restored( "# A\n## Beta\nb\n## Alpha\nnew", $old ),
    "# A\n## Beta\nb\n## Alpha\nold", 'last section without a final newline gets none' );

is( restored( "# A\n## Beta\nb\n## Alpha\nnew\n\n\n", $old ),
    "# A\n## Beta\nb\n## Alpha\nold\n\n\n", 'trailing blank lines at the end of the page stay' );

is( restored( "# A\n## Alpha\nnew\n## Beta\nb\n", "## Alpha\nold 1\nold 2\n\nold 3" ),
    "# A\n## Alpha\nold 1\nold 2\n\nold 3\n## Beta\nb\n", 'a longer historic section replaces a shorter one; inner blank lines are kept' );

is( restored( "# A\n## Alpha\nnew\nmore\nlines\n## Beta\nb\n", $old ),
    "# A\n## Alpha\nold\n## Beta\nb\n", 'a shorter historic section replaces a longer one' );

# The real get_section_content_at_commit hands back a trailing "\n" when the old
# section ended in a blank line; the result must be the same either way.
is( restored( "# A\n## Alpha\nnew\n\n## Beta\nb\n", "## Alpha\nold\n" ),
    "# A\n## Alpha\nold\n\n## Beta\nb\n", 'a historic section with a trailing newline gives the same result' );
is( restored( "# A\n## Beta\nb\n## Alpha\nnew\n", "## Alpha\nold\n" ),
    "# A\n## Beta\nb\n## Alpha\nold\n", 'same for the last section' );

# CRLF is not tested here: the real method never returns CRLF section text
# (History normalises the whole historic page first); see t/49 for the
# end-to-end case.

# ---- server level: a CRLF page stays CRLF through restore_section.
# (Card 14 routes restore through Document, which owns the page's line ending;
# the stand-in below works on the LF text the server hands it.)
{
    package Local::FakeHistory;
    sub new { return bless {}, shift }
    sub restore_section {
        my ( $self, $page, $heading_path, $commit_hash, $opts ) = @_;
        my $doc = $opts->{current_content};
        $doc =~ s/new alpha/old alpha/;
        return { success => 1, content => $doc, restored_from => $commit_hash };
    }
}

my $wiki = tempdir;
my $page = $wiki->child('crlf.md');
$page->spew_raw("# Intro\r\n## Alpha\r\nnew alpha\r\n## Beta\r\nbeta\r\n");
my $server = MCP::Wiki::Server->new( wiki_root => "$wiki", git_history => Local::FakeHistory->new );
my ($tool) = grep { $_->name eq 'restore_section' } @{ $server->server->tools };

my $res = $tool->code->( $tool, { page => 'crlf.md', heading_path => 'Intro#Alpha', commit_hash => 'abc123' } );
ok( !$res->{isError}, 'restore_section on a CRLF page succeeds' ) or diag( $res->{content}[0]{text} );
my $raw = $page->slurp_raw;
like( $raw, qr/old alpha/, 'the restored text is on disk' );
is( $raw, "# Intro\r\n## Alpha\r\nold alpha\r\n## Beta\r\nbeta\r\n", 'the page is still CRLF throughout' );

done_testing;
