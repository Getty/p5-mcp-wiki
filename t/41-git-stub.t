use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );

# MCP::Wiki::Git is a deprecated stub over MCP::Wiki::Git::History (karr k9).
# Runs without Git::Raw and never touches a repository.

require_ok('MCP::Wiki::Git');

can_ok( 'MCP::Wiki::Git', qw( new wiki_root repo get_head_hash auto_commit ) );

ok( MCP::Wiki::Git->isa('MCP::Wiki::Git::History'), 'delegates to History' );
ok( MCP::Wiki::Git->can('get_section_commits'), 'inherits History API' );
isnt( MCP::Wiki::Git->can('auto_commit'), MCP::Wiki::Git::History->can('auto_commit'),
  'auto_commit wraps the History one to keep the old return contract' );

my $dir = tempdir;
my $git = MCP::Wiki::Git->new( wiki_root => "$dir" );
isa_ok( $git, 'MCP::Wiki::Git' );
is( $git->wiki_root, "$dir", 'wiki_root accessor' );
ok( !eval { $git->repo; 1 }, 'repo dies for a non-repository' );
like( $@, qr/Not a git repository/, 'with the History error' );

ok( !eval { MCP::Wiki::Git->new; 1 }, 'wiki_root stays required' );

done_testing;
