use strict;
use warnings;
use Test::More;
use Path::Tiny qw( path );

# Guards the removal of dead code (karr k9). Reads only.

# Part A: unused internals
require_ok('MCP::Wiki::Document');
require_ok('MCP::Wiki::Git::History');
require_ok('MCP::Wiki::TOC::Entry');
require_ok('MCP::Wiki::Server');

ok( !MCP::Wiki::Document->can('update_content_hash'), 'Document has no update_content_hash' );
ok( !MCP::Wiki::Git::History->can('_build_history_file'), 'History has no _build_history_file' );
ok( !MCP::Wiki::Git::History->can('history_file'), 'History has no history_file' );

# Imports may be swept by namespace::clean, so a symbol-table check could not
# fail; read the code lines of the source instead (POD and comments dropped).
sub code_of {
  my ($file) = @_;
  my ( $in_pod, @code ) = (0);
  for my $line ( path($file)->lines_utf8 ) {
    if ( $line =~ /^=cut\b/ )    { $in_pod = 0; next }
    if ( $line =~ /^=[a-zA-Z]/ ) { $in_pod = 1; next }
    next if $in_pod;
    last if $line =~ /^__END__/;
    $line =~ s/#.*//;
    push @code, $line;
  }
  return join '', @code;
}

for my $file (qw(
  lib/MCP/Wiki/Server.pm lib/MCP/Wiki/Document.pm lib/MCP/Wiki/Git/History.pm
)) {
  unlike( code_of($file), qr/\bDigest::SHA\b|\bsha256_hex\b/, $file.' loads no Digest::SHA' );
}
unlike( code_of('lib/MCP/Wiki/Server.pm'), qr/\bto_json\b/, 'Server imports no to_json' );
unlike( code_of('lib/MCP/Wiki/TOC/Entry.pm'), qr/\bTypes::Standard\b/, 'Entry loads no Types::Standard' );
unlike( code_of('lib/MCP/Wiki/Git/History.pm'), qr/mcp-wiki-history\.json/, 'no history json file' );

done_testing;
