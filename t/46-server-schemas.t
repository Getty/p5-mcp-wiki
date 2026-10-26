use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki;
use MCP::Wiki::Server;

# What a client learns from tools/list and initialize: declared arguments,
# descriptions that say how to use them, and the server version. Facts are
# asserted, not wording.

BEGIN {
  eval { require MCP::Server::Context; require MCP::Server::Legacy; require MCP::Constants; 1 }
    or plan skip_all => 'installed MCP has no MCP::Server::Context/Legacy: request handler not drivable in-process';
}
use MCP::Server::Legacy qw( legacy_request );
use MCP::Constants qw( META_PROTOCOL_VERSION META_CLIENT_CAPABILITIES PROTOCOL_VERSION );

my $dir    = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => "$dir" );

my $next_id = 0;
sub rpc {
  my ( $method, $params ) = @_;
  my $request = { jsonrpc => '2.0', id => ++$next_id, method => $method, defined $params ? ( params => $params ) : () };
  my $legacy  = legacy_request( undef, $request );
  my $context = MCP::Server::Context->new( legacy => $legacy );
  return $server->server->handle( $request, $context );
}

my $meta = { _meta => { +META_PROTOCOL_VERSION, PROTOCOL_VERSION, +META_CLIENT_CAPABILITIES, {} } };
my $list = rpc( 'tools/list', $meta );
ok( !$list->{error}, 'tools/list answers' ) or diag explain $list;
my %tool = map { $_->{name} => $_ } @{ $list->{result}{tools} };

# create_page declares reason, optional
{
  my $schema = $tool{create_page}{inputSchema};
  is( $schema->{properties}{reason}{type}, 'string', 'create_page declares reason as a string' );
  ok( !grep( { $_ eq 'reason' } @{ $schema->{required} // [] } ), 'reason is optional' );
  ok( length( $schema->{properties}{reason}{description} // '' ), 'reason is described' );
}

# every heading_path says what it is
for my $name ( sort grep { exists $tool{$_}{inputSchema}{properties}{heading_path} } keys %tool ) {
  my $d = $tool{$name}{inputSchema}{properties}{heading_path}{description} // '';
  like( $d, qr/get_toc/, "$name: heading_path says where the value comes from" );
  like( $d, qr/\w#\w/,   "$name: heading_path carries an example with the # separator" );
  like( $d, qr/full|ancestor/i, "$name: heading_path says it is the whole path" );
}

# create_page: fails on an existing page, default content
{
  my $d = $tool{create_page}{description} // '';
  like( $d, qr/exist/i,   'create_page description says it fails if the page exists' );
  like( $d, qr/default/i, 'create_page description says what the default content is' );
}

# get_toc description: says line numbers are valid for one call only and that heading_path is the address
{
  my $d = $tool{get_toc}{description} // '';
  like( $d, qr/line/i,        'get_toc description mentions line numbers' );
  like( $d, qr/heading_path/, 'get_toc description names heading_path as the address' );
}

# tool annotations: what a client may rely on to decide how careful to be
{
  my %writes = map { $_ => 1 } qw( create_page update_paragraph rename_page delete_page restore_section
    write_page add_section delete_section rename_heading );
  my %destructive = map { $_ => 1 } qw( update_paragraph rename_page delete_page restore_section
    write_page delete_section rename_heading );
  my $true = sub { $_[0] && "$_[0]" ne '0' && "$_[0]" ne 'false' ? 1 : 0 };

  for my $name ( sort keys %tool ) {
    my $a = $tool{$name}{annotations};
    is( ref $a, 'HASH', "$name has annotations" ) or next;
    ok( defined $a->{readOnlyHint}, "$name declares readOnlyHint" );
    is( $true->( $a->{readOnlyHint} ), $writes{$name} ? 0 : 1, "$name: readOnlyHint is true exactly for tools that do not write" );
    ok( defined $a->{openWorldHint} && !$true->( $a->{openWorldHint} ), "$name is not open-world" );
    if ( $destructive{$name} ) {
      ok( $true->( $a->{destructiveHint} ), "$name is marked destructive" );
    }
    elsif ( $writes{$name} ) {
      ok( !$true->( $a->{destructiveHint} ), "$name (create) is not destructive" );
    }
  }
  for my $name (qw( get_toc get_paragraph get_page search_pages get_section_history list_pages )) {
    ok( $true->( $tool{$name}{annotations}{readOnlyHint} ), "$name is read-only" );
  }
}

# server version
{
  my $res = rpc( 'initialize', { protocolVersion => '2025-11-25', capabilities => {}, clientInfo => { name => 't', version => '1' } } );
  ok( !$res->{error}, 'initialize answers' ) or diag explain $res;
  ok( defined $MCP::Wiki::VERSION, 'MCP::Wiki has a version' );
  is( $res->{result}{serverInfo}{version}, $MCP::Wiki::VERSION, 'serverInfo version is the distribution version' );
}

done_testing;
