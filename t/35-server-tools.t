use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use File::Spec;
use JSON::MaybeXS qw( decode_json );
use MCP::Wiki::Server;
use feature 'signatures';

# Look a tool up by name; a missing tool is a loud failure, not a shifted index.
sub tool_named {
    my ($server, $name) = @_;
    my ($tool) = grep { $_->name eq $name } @{ $server->server->tools };
    die "tool '$name' is not registered" unless $tool;
    return $tool;
}

sub call_tool {
    my ($server, $name, $args) = @_;
    my $tool = tool_named($server, $name);
    return $tool->code->($tool, $args);
}

sub data_of {
    my ($result) = @_;
    return decode_json($result->{content}->[0]->{text});
}

# Create a test wiki directory
my $wiki_dir = tempdir;

# Initialize git repo
system("git init -q $wiki_dir") == 0 or die "git init failed";

subtest 'list_pages with empty wiki' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'list_pages',
        {}
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"pages"\s*:\s*\[\]/, 'empty wiki returns empty pages array');
    like($text, qr/"count"\s*:\s*0/, 'count is 0');
};

subtest 'create_page' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'create_page',
        { page => 'test.md', content => "# Test\n\nHello world." }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"success":\s*1/, 'create_page returns success');
    ok(-e "$wiki_dir/test.md", 'file was created');
};

subtest 'get_toc after creating page' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'get_toc',
        { page => 'test.md' }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"heading":\s*"Test"/, 'toc contains the heading');
    like($text, qr/"level":\s*1/, 'heading level is 1');
};

subtest 'get_paragraph' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'get_paragraph',
        { page => 'test.md', heading_path => 'Test' }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/Hello world/, 'paragraph content returned');
};

subtest 'update_paragraph' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'update_paragraph',
        { page => 'test.md', heading_path => 'Test', content => "Updated content here." }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"success":\s*1/, 'update returns success');

    # Verify content changed
    my $content = Path::Tiny::path("$wiki_dir/test.md")->slurp_utf8;
    like($content, qr/Updated content/, 'file content was updated');
    is(() = $content =~ /^# Test$/mg, 1, 'the heading is kept once, not duplicated');

    # What get_paragraph returns can be written back unchanged
    my $before = $content;
    my $got = data_of(call_tool($server, 'get_paragraph', { page => 'test.md', heading_path => 'Test' }));
    call_tool($server, 'update_paragraph',
        { page => 'test.md', heading_path => 'Test', content => $got->{content} });
    is(Path::Tiny::path("$wiki_dir/test.md")->slurp_utf8, $before, 'get -> update leaves the page as it was');
};

subtest 'rename_page' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    # First create another page
    Path::Tiny::path("$wiki_dir/old.md")->spew_utf8("# Old\n\nContent");
    my $result = call_tool($server, 'rename_page',
        { from => 'old.md', to => 'new.md' }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"success":\s*1/, 'rename returns success');
    ok(-e "$wiki_dir/new.md", 'new file exists');
    ok(!-e "$wiki_dir/old.md", 'old file removed');
};

subtest 'delete_page' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    # Create a file to delete
    Path::Tiny::path("$wiki_dir/delete-me.md")->spew_utf8("# Delete\n\nMe");
    my $result = call_tool($server, 'delete_page',
        { page => 'delete-me.md' }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/"success":\s*1/, 'delete returns success');
    ok(!-e "$wiki_dir/delete-me.md", 'file was deleted');
};

subtest 'on_change callback fires' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");
    my $called = 0;
    my $event_data;

    $server->on_change(sub ($event) {
        $called++;
        $event_data = $event;
    });

    # Trigger a create
    call_tool($server, 'create_page',
        { page => 'callback-test.md', content => "# Callback Test" }
    );

    is($called, 1, 'callback was called once');
    is($event_data->{type}, 'create', 'event type is create');
    is($event_data->{page}, 'callback-test.md', 'page name correct');
};

subtest 'path traversal blocked' => sub {
    my $server = MCP::Wiki::Server->new(wiki_root => "$wiki_dir");

    my $result = call_tool($server, 'get_toc',
        { page => '../../../etc/passwd' }
    );

    my $text = $result->{content}->[0]->{text};
    like($text, qr/error|invalid|not found/i, 'path traversal is blocked');
};

done_testing;