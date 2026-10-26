requires 'perl', '5.020';
requires 'MCP';
requires 'Mojolicious';          # Required by MCP::Server
requires 'Moo';
requires 'namespace::clean';
requires 'Path::Tiny';

# Optional: history/restore tools degrade cleanly without it
recommends 'Git::Raw';

on test => sub {
  requires 'File::Find::Rule';
  requires 'JSON::MaybeXS';
  requires 'Test::More';
};

on develop => sub {
  requires 'Dist::Zilla';
};
