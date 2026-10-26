package MCP::Wiki::Git;
# ABSTRACT: DEPRECATED thin wrapper around MCP::Wiki::Git::History

our $VERSION = '0.002';

use Moo;
use namespace::clean;

extends 'MCP::Wiki::Git::History';

=method auto_commit

    $git->auto_commit('page.md', 'Update page');

Delegates to L<MCP::Wiki::Git::History/auto_commit> and keeps the old
contract: returns C<1> on success, dies on failure. The History method
returns a hashref (C<success>, C<hash>, C<message>) and also accepts a
C<reason> option; this wrapper exposes neither.

=cut

around auto_commit => sub {
  my ( $orig, $self, $file_path, $message ) = @_;
  $self->$orig( $file_path, $message );
  return 1;
};

=method get_head_hash

Returns the id of the current HEAD commit.

=cut

sub get_head_hash {
  my ( $self ) = @_;
  return $self->repo->head->target->id;
}

1;

__END__

=head1 SYNOPSIS

    use MCP::Wiki::Git;

    my $git = MCP::Wiki::Git->new(wiki_root => '/path/to/wiki');
    $git->auto_commit('example.md', 'Update example page');

=head1 DESCRIPTION

B<DEPRECATED.> Use L<MCP::Wiki::Git::History> instead. The server does not use
this class. It remains, loadable without L<Git::Raw>, only because it was
published in MCP-Wiki 0.001. It subclasses L<MCP::Wiki::Git::History> and
keeps the old C<new(wiki_root =E<gt> ...)>, C<wiki_root>, C<repo>,
C<get_head_hash> and C<auto_commit($file, $message)> interface.

=cut
