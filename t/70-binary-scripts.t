#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path tempdir );

# scripts/binary-verify.sh (build machine) and scripts/binary-smoke.sh (clean
# machine) judge a standalone binary by one MCP session. No binary is needed
# here: a wrapper script that execs the Perl code stands in for it, and two
# variants of it play the failures the scripts must catch. Opt-in against the
# real Git::Raw, hermetic like t/42: the wrapped server and its git history
# run for real, in tempdirs the scripts create themselves.
my $home;
BEGIN {
    $home = tempdir;
    $ENV{HOME}                = "$home";
    $ENV{XDG_CONFIG_HOME}     = "$home";
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    delete @ENV{qw( GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_DIR )};
}

# The prepare cases need only bash and run with or without Git::Raw. The rest
# (verify/smoke) runs a real server and needs Git::Raw, sh and git.
use File::Spec;
sub have_tool {
    my ($tool) = @_;
    return scalar grep { -f && -x _ } map { File::Spec->catfile( $_, $tool ) } File::Spec->path;
}
BEGIN {
    plan skip_all => 'bash not found on PATH (the binary scripts need bash)'
        unless have_tool('bash');
}

my $root   = path(__FILE__)->absolute->parent->parent;
my $lib    = $root->child('lib');
my $bin    = $root->child( 'bin', 'mcp-wiki' );
my $verify = $root->child( 'scripts', 'binary-verify.sh' );
my $smoke  = $root->child( 'scripts', 'binary-smoke.sh' );
my $prepare = $root->child( 'scripts', 'binary-prepare.sh' );
my $tmp    = tempdir;

sub write_exe {
    my ( $name, $text ) = @_;
    my $file = $tmp->child($name);
    $file->spew($text);
    $file->chmod(0755);
    return "$file";
}

my $real = qq{exec '$^X' '-I$lib' '$bin' "\$@"\n};

# the stand-in for the binary
my $wrapper = write_exe( 'wrapper', "#!/bin/sh\n$real" );

# the startup warning of a server that found no history, then the real one
my $warning = "Git is not available, the wiki is served without history and commits: "
    . "Not a git repository: /somewhere\n";
my $degraded = write_exe( 'degraded', "#!/bin/sh\nprintf '%s' '$warning' >&2\n$real" );

# the real server, its stdout filtered: the tools/list answer (id 2) loses its
# last tool, so everything else in the session stays as the real server says
my $filter = write_exe( 'drop-one-tool.pl', <<'PERL' );
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();
my $json = JSON::PP->new->utf8->canonical;
$| = 1;
while ( my $line = <STDIN> ) {
    my $msg = eval { $json->decode($line) };
    if ( ref $msg eq 'HASH' && ( $msg->{id} // '' ) eq '2' && $msg->{result}{tools} ) {
        pop @{ $msg->{result}{tools} };
        $line = $json->encode($msg) . "\n";
    }
    print $line;
}
PERL
my $short = write_exe( 'short', "#!/bin/sh\n'$^X' '-I$lib' '$bin' \"\$@\" | '$^X' '$filter'\n" );

# run a command, stdout and stderr to one string: ( exit code, output )
sub run {
    my @cmd = @_;
    my $out = $tmp->child('run.out');
    my $pid = fork // die "fork: $!";
    if ( !$pid ) {
        open STDOUT, '>', "$out" or die "stdout: $!";
        open STDERR, '>&', \*STDOUT or die "stderr: $!";
        exec @cmd or die "exec @cmd: $!";
    }
    waitpid $pid, 0;
    return ( $? >> 8, $out->slurp_utf8 );
}

# The spawned server loads MCP::Wiki::Server before Git::Raw itself; this file
# only needs to know that Git::Raw is there.
SKIP: {
    skip 'Git::Raw not installed (opt-in test against the real API)', 12
        unless eval { require Git::Raw; 1 };
    for my $tool (qw( sh git )) {
        skip "$tool not found on PATH (the binary scripts need bash, sh and git)", 12
            unless have_tool($tool);
    }

    ok( -f $verify, 'scripts/binary-verify.sh exists' );
    ok( -f $smoke,  'scripts/binary-smoke.sh exists' );

    {
        my ( $rc, $out ) = run( 'bash', "$verify", $wrapper );
        is( $rc, 0, 'verify_script_passes_against_perl' ) or diag $out;
        like( $out, qr/^verify: OK\n\z/m, 'verify ends with its OK line' );
    }

    {
        my ( $rc, $out ) = run( 'sh', "$smoke", $wrapper );
        is( $rc, 0, 'smoke_script_passes_against_perl' ) or diag $out;
        like( $out, qr/^smoke: OK\n\z/m, 'smoke ends with its OK line' );
    }

    # a failing run must exit 1 with a reason; exit 127 (script missing) is not it
    {
        my ( $rc, $out ) = run( 'bash', "$verify", $degraded );
        is( $rc, 1, 'verify_fails_on_degrade_warning' );
        like( $out, qr/^FAIL: /m, 'verify names the reason' );
        unlike( $out, qr/^verify: OK/m, 'verify does not report OK' );
    }

    {
        my ( $rc, $out ) = run( 'sh', "$smoke", $short );
        is( $rc, 1, 'smoke_fails_on_wrong_tool_count' );
        like( $out, qr/^FAIL: .*tool/mi, 'smoke names the tool count as the reason' );
        unlike( $out, qr/^smoke: OK/m, 'smoke does not report OK' );
    }
}

# scripts/binary-prepare.sh moves the host's system headers; it must refuse to
# run anywhere but a CI runner. Only the refusal is exercised here, never with
# GITHUB_ACTIONS=true: the script would hide this machine's OpenSSL headers.
{
    my ( $rc, $out ) = do {
        delete local $ENV{GITHUB_ACTIONS};
        run( 'bash', "$prepare" );
    };
    is( $rc, 1, 'prepare_refuses_outside_ci' );
    like( $out, qr/^FAIL: .*only on a CI runner/m, 'prepare names the CI-runner restriction' );
}

{
    my $cache = $tmp->child('prepare-cache');    # does not exist yet
    my ( $rc, $out ) = do {
        delete local $ENV{GITHUB_ACTIONS};
        run( 'bash', "$prepare", "$cache" );
    };
    is( $rc, 1, 'prepare_refuses_outside_ci_with_cache_dir' );
    like( $out, qr/^FAIL: .*only on a CI runner/m, 'prepare with a cache dir names the CI-runner restriction' );
    ok( !-e $cache, 'prepare creates nothing (no cache dir) when it refuses' );
}

done_testing;
