use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );

# This test only verifies the module loads without crashing
# Git functionality requires Git::Raw which may not be available
subtest 'History module loads without Git::Raw' => sub {
    # Git::Raw is required lazily (_build_repo), never at load time
    ok(eval { require MCP::Wiki::Git::History; 1 }, 'module loads without Git::Raw')
        or diag $@;
};

done_testing;