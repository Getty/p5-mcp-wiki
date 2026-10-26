use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );

# The Docker setup and its single registry. Reads the repository files; the
# entrypoint runs against stand-ins for id and mcp-wiki in a tempdir, so
# nothing here needs docker, root or the network.

plan skip_all => 'docker-entrypoint.sh not found (run from the distribution root)'
  unless path('docker-entrypoint.sh')->is_file;

my $dist_ini = path('dist.ini')->slurp_utf8;
my $docker   = path('Dockerfile')->slurp_utf8;
$docker =~ s/^#[^\n]*\n//mg;    # the comments explain the manual build, they are no instructions

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
unlike( $docker, qr/\bdzil\b|Dist::Zilla/, 'the image installs the built dist, no dzil inside' );
unlike( $docker, qr/App::cpanminus/, 'cpanm comes with the base image, it is not installed again' );
unlike( $docker, qr/^EXPOSE\b/m, 'a stdio server exposes no port' );
like( $docker, qr/^WORKDIR\s+\/wiki\s*$/m, 'the default wiki root (.) is the volume' );
like( $docker, qr/^USER\s+appuser\s*$/m, 'the image runs as the unprivileged user' );
unlike( path('docker-entrypoint.sh')->slurp_utf8, qr/\bchown\b|\bsetpriv\b/,
    'the entrypoint neither changes the ownership of a volume nor switches users' );

# The dependencies are a layer of their own, ahead of the sources, so a code
# change does not install them again
like( $docker,
    qr/^COPY\s+cpanfile\s+META\.json\s+Makefile\.PL\s+\.\/?\s*\nRUN\s+cpanm\b[^\n]*--installdeps\b[^\n]*\s\.\s*$/m,
    'dependencies install from the dist metadata in a layer of their own' );
like( $docker, qr/^RUN\s+cpanm\b[^\n]*--with-recommends\b/m, 'the optional Git::Raw is installed too' );
like( $docker,
    qr/--installdeps.*^COPY\s+\.\s+\.\s*\nRUN\s+cpanm\b[^\n]*\s\.\s*$/ms,
    'then the rest is copied and the dist installed' );

# -- shebang -----------------------------------------------------------------
my ($shebang) = path('bin/mcp-wiki')->lines_utf8( { count => 1 } );
is( $shebang, "#!/usr/bin/env perl\n",
    'mcp-wiki finds perl on PATH; the install step rewrites it anyway' );

# -- entrypoint --------------------------------------------------------------
my $bin = tempdir;
my $log = $bin->child('log');
my $err = $bin->child('err');

sub stub {
    my ( $name, $body ) = @_;
    my $file = $bin->child($name);
    $file->spew_utf8("#!/bin/bash\n$body\n");
    $file->chmod(0755);
}

# every stand-in logs "name arg1|arg2|..."
my $record = 'printf "%s %s\n" "$(basename "$0")" "$(IFS="|"; echo "$*")" >> ' . "$log";
stub( 'mcp-wiki' => $record );
stub( 'chown'    => $record );
stub( 'setpriv'  => $record );
stub( 'id'       => 'echo 4711' );

# Runs the entrypoint with @args; returns the exit status, what the
# stand-ins logged, and what went to stderr.
sub run_entrypoint {
    my (@args) = @_;
    $log->remove;
    $err->remove;
    local $ENV{PATH}     = "$bin:$ENV{PATH}";
    local $ENV{ERR_FILE} = "$err";
    my $rc = system( 'bash', '-c', 'exec bash docker-entrypoint.sh "$@" 2>"$ERR_FILE"', '_', @args );
    return (
        $rc >> 8,
        $log->exists ? [ $log->lines_utf8( { chomp => 1 } ) ] : [],
        $err->exists ? $err->slurp_utf8 : '',
    );
}

# A wiki root whose name needs the quoting to survive
my $volume = tempdir;
my $wiki   = $volume->child( 'my wiki', 'with spaces' );
$wiki->mkpath;

{
    my @awkward = ( '--wiki-root', "$wiki", '--reason', q{it's "quoted" $HOME} );
    my ( $rc, $lines ) = run_entrypoint(@awkward);
    is( $rc, 0, 'entrypoint exits cleanly' );
    is_deeply( $lines, [ 'mcp-wiki ' . join( '|', @awkward ) ],
        'arguments reach mcp-wiki unsplit, without a privilege drop or an ownership change' );
}

{
    my @args = ( "--wiki-root=$wiki", '--git' );
    my ( $rc, $lines ) = run_entrypoint(@args);
    is( $rc, 0, '--wiki-root=PATH is the wiki root too' );
    is_deeply( $lines, [ 'mcp-wiki ' . join( '|', @args ) ], 'and its arguments arrive unchanged' );
}

# The effective wiki root is the last --wiki-root
{
    my @good_last = ( '--wiki-root', "$volume/missing", '--wiki-root', "$wiki" );
    my ( $rc, $lines ) = run_entrypoint(@good_last);
    is( $rc, 0, 'an earlier --wiki-root is overridden by the last one' );
    is( scalar @$lines, 1, 'and mcp-wiki ran' );

    my ( $rc2, $lines2, $stderr2 ) = run_entrypoint( '--wiki-root', "$wiki", '--wiki-root', "$volume/missing" );
    isnt( $rc2, 0, 'the last --wiki-root is the one that is checked' );
    is_deeply( $lines2, [], 'mcp-wiki did not start' );
    like( $stderr2, qr/\Q$volume\/missing\E/, 'and the message names that path' );
}

# Without --wiki-root the root is /wiki
SKIP: {
    skip '/wiki exists on this machine', 3 if -e '/wiki';
    my ( $rc, $lines, $stderr ) = run_entrypoint('--git');
    isnt( $rc, 0, 'no --wiki-root: /wiki is checked' );
    is_deeply( $lines, [], 'mcp-wiki did not start' );
    like( $stderr, qr{/wiki\b}, 'and the message names /wiki' );
}

# A wiki root the user cannot write to stops the container with a message
SKIP: {
    my $readonly = $volume->child('readonly');
    $readonly->mkpath;
    $readonly->chmod(0555);
    skip 'running with the right to write to a read-only directory', 5 if -w $readonly;

    my ( $rc, $lines, $stderr ) = run_entrypoint( '--wiki-root', "$readonly" );
    isnt( $rc, 0, 'a wiki root that is not writable stops the entrypoint' );
    is_deeply( $lines, [], 'mcp-wiki did not start, nothing was changed on the volume' );
    like( $stderr, qr/\Q$readonly\E/, 'the message names the path' );
    like( $stderr, qr/\b4711\b/, 'the uid' );
    like( $stderr, qr/--user/, 'and says how to fix it' );
    $readonly->chmod(0755);
}

done_testing;
