package MCP::Wiki;

# ABSTRACT: Markdown wiki MCP server with TOC extraction and git history

use strict;
use warnings;

our $VERSION = '0.001';

1;
__END__

=head1 SYNOPSIS

    use MCP::Wiki::Server;

    my $server = MCP::Wiki::Server->new(
        wiki_root => '/path/to/wiki',
        use_git   => 1,
    );

    $server->to_stdio;

=head1 DESCRIPTION

An MCP server that manages a markdown wiki in a directory. Supports TOC
extraction, paragraph-level editing, and git history tracking.

=head1 SEE ALSO

L<MCP::Wiki::Server>, L<MCP::Wiki::Document>, L<MCP::Wiki::TOC::Parser>