use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );

# The Docker setup and its single registry. Reads the repository files; the
# entrypoint runs against stand-ins for id, setpriv and mcp-wiki in a tempdir,
# so nothing here needs docker, root or the network.

plan skip_all => 'docker-entrypoint.sh not found (run from the distribution root)'
  unless path('docker-entrypoint.sh')->is_file;

my $dist_ini = path('dist.ini')->slurp_utf8;
my $docker   = path('Dockerfile')->slurp_utf8;

# -- one registry ------------------------------------------------------------
like( $dist_ini, qr/^docker_image\s*=\s*raudssus\/mcp-wiki\s*$/m, 'dist.ini names the Docker Hub image' );
unlike( $dist_ini, qr/^\s*docker_local\b/m, 'dist.ini does not hold the image back from the registry' );
unlike( $dist_ini, qr/localhost:5000/, 'no second, local registry' );
ok( !path('maint/release-after.pl')->exists, 'no second release path that builds and pushes on its own' );
SKIP: {
  # The release tarball does not ship README.md (only README); this check is repo-only.
  skip 'README.md not shipped in the distribution', 1 unless path('README.md')->is_file;
  like( path('README.md')->slurp_utf8, qr/\braudssus\/mcp-wiki\b/, 'README documents the same image' );
}

# -- Dockerfile --------------------------------------------------------------
unlike( $docker, qr/PERL5LIB/, 'no PERL5LIB pinned to one perl version' );
unlike( $docker, qr/site_perl\/5\.\d+\.\d+/, 'no perl version in a path' );
like( $docker, qr/DZIL_DOCKER_API_SKIP=1\s+dzil build/, 'dzil build inside the image does not build an image' );

# -- shebang -----------------------------------------------------------------
my ($shebang) = path('bin/mcp-wiki')->lines_utf8( { count => 1 } );
is( $shebang, "#!/usr/bin/env perl\n",
    'mcp-wiki finds perl on PATH; the install step rewrites it anyway' );

# -- entrypoint --------------------------------------------------------------
my $bin = tempdir;
my $log = $bin->child('log');

sub stub {
    my ( $name, $body ) = @_;
    my $file = $bin->child($name);
    $file->spew_utf8("#!/bin/bash\n$body\n");
    $file->chmod(0755);
}

# every stand-in logs "name arg1|arg2|..." and the last one runs
my $record = 'printf "%s %s\n" "$(basename "$0")" "$(IFS="|"; echo "$*")" >> ' . "$log";
stub( mcp_wiki => $record );    # placeholder, renamed below
$bin->child('mcp_wiki')->move( $bin->child('mcp-wiki') );
stub( chown   => $record );
stub( setpriv => "$record; shift 5; exec \"\$@\"" );    # --reuid U --regid G --clear-groups

sub run_entrypoint {
    my ( $uid, @args ) = @_;
    my $wiki = tempdir;
    stub( id   => "echo $uid" );
    stub( stat => 'echo 4711' );
    $log->remove;
    local $ENV{PATH}          = "$bin:$ENV{PATH}";
    local $ENV{MCP_WIKI_ROOT} = "$wiki";
    my $rc = system( 'bash', 'docker-entrypoint.sh', @args );
    return ( $rc, $log->exists ? [ $log->lines_utf8( { chomp => 1 } ) ] : [] );
}

my @awkward = ( '--wiki-root', '/my wiki/with spaces', '--reason', q{it's "quoted" $HOME} );

{
    my ( $rc, $lines ) = run_entrypoint( 1000, @awkward );
    is( $rc, 0, 'entrypoint exits cleanly as a plain user' );
    is_deeply( $lines, [ 'mcp-wiki ' . join( '|', @awkward ) ],
        'plain user: arguments reach mcp-wiki unsplit' );
}

{
    my ( $rc, $lines ) = run_entrypoint( 0, @awkward );
    is( $rc, 0, 'entrypoint exits cleanly as root' );
    is_deeply(
        $lines,
        [ 'setpriv --reuid|4711|--regid|4711|--clear-groups|mcp-wiki|' . join( '|', @awkward ),
          'mcp-wiki ' . join( '|', @awkward ) ],
        'root: dropped to the owner of the wiki without a shell; arguments unsplit'
    );
}

done_testing;
