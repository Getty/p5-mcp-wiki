use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# restore_section is never committed, so its `reason` is no commit message: it
# is only passed on in the restore event. The description must not say otherwise.

my $server = MCP::Wiki::Server->new( wiki_root => '' . tempdir );
my ($tool) = grep { $_->name eq 'restore_section' } @{ $server->server->tools };
BAIL_OUT('no restore_section tool') unless $tool;

my $d = $tool->input_schema->{properties}{reason}{description} // '';
ok( length $d, 'restore_section reason is described' );
unlike( $d, qr/commit message/i, 'restore_section reason does not claim to become a commit message' );

done_testing;
