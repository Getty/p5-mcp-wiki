use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# restore_section is committed with use_git (t/59), so its `reason` is the
# commit message, like the reason of every other writing tool. The description
# must say so.

my $server = MCP::Wiki::Server->new( wiki_root => '' . tempdir );
my ($tool) = grep { $_->name eq 'restore_section' } @{ $server->server->tools };
BAIL_OUT('no restore_section tool') unless $tool;

my $d = $tool->input_schema->{properties}{reason}{description} // '';
ok( length $d, 'restore_section reason is described' );
like( $d, qr/commit message/i, 'restore_section reason is described as the commit message' );
unlike( $d, qr/not committed/i, 'restore_section reason does not claim the restore is not committed' );

done_testing;
