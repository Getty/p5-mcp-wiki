use strict;
use warnings;
use Test::More;
use Path::Tiny qw( tempdir );
use MCP::Wiki::Server;

# Request level: JSON-RPC requests go through MCP::Server's own handler, the
# way the stdio transport hands them over, so descriptions, input schemas and
# argument validation are exercised as a client sees them.

BEGIN {
  eval { require MCP::Server::Context; require MCP::Server::Legacy; require MCP::Constants; 1 }
    or plan skip_all => 'installed MCP has no MCP::Server::Context/Legacy: request handler not drivable in-process';
}
use MCP::Server::Legacy qw( legacy_request );
use MCP::Constants qw( INVALID_PARAMS META_PROTOCOL_VERSION META_CLIENT_CAPABILITIES PROTOCOL_VERSION );

my $dir    = tempdir;
my $server = MCP::Wiki::Server->new( wiki_root => "$dir" );

# Same context the stdio transport builds for each request line.
my $next_id = 0;
sub rpc {
  my ( $method, $params ) = @_;
  my $request = { jsonrpc => '2.0', id => ++$next_id, method => $method, defined $params ? ( params => $params ) : () };
  my $legacy  = legacy_request( undef, $request );
  my $context = MCP::Server::Context->new( legacy => $legacy );
  return $server->server->handle( $request, $context );
}

# Current-protocol requests carry the protocol version in _meta; the legacy
# initialize handshake does not.
sub meta {
  return { _meta => { +META_PROTOCOL_VERSION, PROTOCOL_VERSION, +META_CLIENT_CAPABILITIES, {} } };
}

sub call {
  my ( $name, $args ) = @_;
  return rpc( 'tools/call', { %{ meta() }, name => $name, arguments => $args } );
}

# README tool table
my %REQUIRED = (
  list_pages          => [],
  get_toc             => ['page'],
  get_paragraph       => [ 'heading_path', 'page' ],
  create_page         => ['page'],
  update_paragraph    => [ 'content', 'heading_path', 'page' ],
  rename_page         => [ 'from', 'to' ],
  delete_page         => ['page'],
  get_section_history => [ 'heading_path', 'page' ],
  restore_section     => [ 'commit_hash', 'heading_path', 'page' ],
);

$dir->child('home.md')->spew_utf8("# Home\n\nWelcome.\n\n## Setup\n\nRun it.\n");
$dir->child('sub')->mkpath;
$dir->child( 'sub', 'deep.md' )->spew_utf8("# Deep\n\nBottom.\n");

subtest 'initialize' => sub {
  my $res = rpc( 'initialize', { protocolVersion => '2025-11-25', capabilities => {}, clientInfo => { name => 't', version => '1' } } );
  ok( !$res->{error}, 'no error' ) or diag explain $res;
  my $info = $res->{result}{serverInfo};
  is( ref $info, 'HASH', 'serverInfo present' );
  ok( length $info->{name}, 'serverInfo has a name' );
  ok( $res->{result}{capabilities}{tools}, 'tools capability announced' );
};

subtest 'tools/list' => sub {
  my $res = rpc( 'tools/list', meta() );
  ok( !$res->{error}, 'no error' ) or diag explain $res;
  my %by_name = map { $_->{name} => $_ } @{ $res->{result}{tools} };

  is_deeply( [ sort keys %by_name ], [ sort keys %REQUIRED ], 'exactly the 9 tools' );
  is( scalar @{ $res->{result}{tools} }, 9, 'no tool listed twice' );

  my %registered = map { $_->name => $_ } @{ $server->server->tools };
  for my $name ( sort keys %REQUIRED ) {
    my $t = $by_name{$name} or next;
    ok( defined $t->{description} && length $t->{description}, $name.' has a description' );
    is( $t->{inputSchema}{type}, 'object', $name.' inputSchema is an object schema' );
    is_deeply( [ sort @{ $t->{inputSchema}{required} // [] } ], $REQUIRED{$name}, $name.' required fields' );
    is_deeply( $t->{inputSchema}, $registered{$name}->input_schema, $name.' schema is the one on the tool object' );
    my %props = %{ $t->{inputSchema}{properties} // {} };
    ok( !grep( { !exists $props{$_} } @{ $REQUIRED{$name} } ), $name.' declares a property for each required field' );
  }
};

subtest 'tools/call list_pages' => sub {
  my $res = call( 'list_pages', {} );
  ok( !$res->{error}, 'no error' ) or diag explain $res;
  ok( !$res->{result}{isError}, 'not an error result' );
  is_deeply( [ sort @{ $res->{result}{structuredContent}{pages} } ], [ 'home.md', 'sub/deep.md' ], 'pages' );
  is( $res->{result}{structuredContent}{count}, 2, 'count' );
  is( $res->{result}{content}[0]{type}, 'text', 'text content as well' );
};

subtest 'tools/call get_toc' => sub {
  my $res = call( 'get_toc', { page => 'home.md' } );
  ok( !$res->{error}, 'no error' ) or diag explain $res;
  my $toc = $res->{result}{structuredContent};
  is( $toc->{page}, 'home.md', 'page echoed' );
  my @paths = map { $_->{heading_path} } @{ $toc->{entries} };
  is_deeply( \@paths, [ 'Home', 'Home#Setup' ], 'heading_paths of the page' );
};

subtest 'tools/call get_paragraph' => sub {
  my $res = call( 'get_paragraph', { page => 'home.md', heading_path => 'Home#Setup' } );
  ok( !$res->{error}, 'no error' ) or diag explain $res;
  ok( !$res->{result}{isError}, 'not an error result' );
  is( $res->{result}{structuredContent}{content}, "\nRun it.", 'body of the section' );
  unlike( $res->{result}{structuredContent}{content}, qr/^## Setup/m, 'heading line not part of it' );

  my $sub = call( 'get_paragraph', { page => 'sub/deep.md', heading_path => 'Deep' } );
  like( $sub->{result}{structuredContent}{content}, qr/Bottom\./, 'page in a subdirectory' );
};

subtest 'tools/call refuses a missing required argument' => sub {
  my $res = call( 'get_paragraph', { page => 'home.md' } );
  ok( !$res->{result}, 'no result' );
  is( $res->{error}{code}, INVALID_PARAMS, 'JSON-RPC invalid params' );
  is( $res->{error}{message}, 'Invalid arguments', 'message' );
  is( $res->{id}, $next_id, 'error carries the request id' );

  my $none = call( 'get_toc', {} );
  is( $none->{error}{code}, INVALID_PARAMS, 'get_toc without page: invalid params too' );
};

subtest 'tools/call unknown tool' => sub {
  my $res = call( 'no_such_tool', {} );
  is( $res->{error}{code}, INVALID_PARAMS, 'invalid params' );
  like( $res->{error}{message}, qr/not found/, 'says the tool was not found' );
};

done_testing;
