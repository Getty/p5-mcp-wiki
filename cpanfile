requires 'MCP';
requires 'Mojolicious';          # Required by MCP::Server
requires 'Moo';
requires 'Path::Tiny';
requires 'JSON::MaybeXS';

# Optional: history/restore tools degrade cleanly without it
recommends 'Git::Raw';

on test => sub {
  requires 'Test::More';
  requires 'File::Find::Rule';
};

on develop => sub {
  requires 'Dist::Zilla';
};
