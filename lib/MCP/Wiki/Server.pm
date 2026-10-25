package MCP::Wiki::Server;
# ABSTRACT: Main MCP server for wiki management

use strict;
use warnings;
use Moo;
use MCP::Server;
use MCP::Wiki::Document;
use Path::Tiny;
use Carp qw( croak );
use Encode qw( decode encode );
use JSON::PP ();
use MCP::Wiki;
use feature 'signatures';
no warnings 'experimental::signatures';

=attr wiki_root

Root directory for wiki pages. Defaults to current directory.

Set once when the server is constructed; no tool call can change it or reach a
file outside of it. See L</PAGE NAMES>.

=cut
has wiki_root => (
    is => 'ro',
    default => sub { '.' },
);

=attr use_git

Enable git auto-commit on changes. Default: 0

=cut
has use_git => (
    is => 'ro',
    default => 0,
);

=attr commit_reason_required

Accepted, but currently has no effect: a missing reason is not rejected.
Default: 0

=cut
has commit_reason_required => (
    is => 'ro',
    default => 0,
);

has server => (
    is => 'lazy',
    builder => '_build_server',
);

has _on_change_handlers => (
    is => 'ro',
    default => sub { [] },
);

has git_history => (
    is => 'lazy',
);

sub _build_git_history {
    my ($self) = @_;
    return unless $self->use_git;
    return unless eval { require Git::Raw; 1 };
    require MCP::Wiki::Git::History;
    return MCP::Wiki::Git::History->new(wiki_root => $self->wiki_root);
}

sub BUILD {
    my ($self) = @_;
    $self->_setup_tools;
}

sub _wiki_root_path {
    my ($self) = @_;

    my $root = eval { Path::Tiny::path($self->wiki_root)->realpath };
    croak 'Invalid wiki_root: ' . $self->wiki_root unless $root && $root->is_dir;

    return $root;
}

# True for a path component that names a git directory. Compared without
# regard to case, because a case-insensitive filesystem opens ".GIT" as ".git".
sub _is_git_dir_name {
    my ($self, $name) = @_;
    return lc $name eq '.git';
}

# Turns a page name from a client into the physical path it stands for, or
# croaks. The client is a language model that reads untrusted wiki content, so
# the name is the only thing keeping a tool call inside the wiki: every tool
# that touches a file has to come through here.
#
# The name is walked one component at a time from the resolved root. Whatever
# already exists on disk is resolved before the next component is applied, so a
# symlink is followed and a ".." after it means the parent of its target; the
# part that does not exist yet (a page about to be created, with its
# directories) is appended as plain names. Containment is tested at every step
# on whole path components, so "/wiki-evil" is not below "/wiki" and nothing
# outside the root is probed beyond the step that leaves it.
#
# Three things inside the root are no pages either. Nothing below a ".git"
# directory: a write to its config or hooks is code execution at the next git
# command. Nothing but ".md" files, which keeps every other file in the
# directory out of reach. And nothing that exists but is no plain file: a
# directory named "x.md" would be moved or removed whole, a FIFO would block
# the read. ".git" is looked for in the name and in the resolved path, the
# rest in the resolved path: that is what a call acts on.
#
# The name is a character string; on disk it is its UTF-8 encoding. The walk
# and the returned path are bytes, like the root and every name realpath gives
# back: mixed with characters they would be re-encoded into a different name.
sub _resolve_page {
    my ($self, $page) = @_;

    croak 'Page name required' unless defined $page && !ref $page && length $page;
    croak 'Invalid page name' if $page =~ /\0/;

    my $root = $self->_wiki_root_path;
    my $path = $root;
    for my $part (split m{/+}, encode('UTF-8', $page)) {
        next if $part eq '' || $part eq '.';
        $path = $part eq '..' ? $path->parent : $path->child($part);
        if (-l $path || -e $path) {
            $path = eval { $path->realpath }
                or croak "Cannot resolve page path: $page";
            # Fail closed should a link survive resolution: a later write
            # would follow it past the check below.
            croak "Cannot resolve page path: $page" if -l $path;
        }
        croak "Path outside wiki root: $page" unless $root->subsumes($path);
        croak "Not a wiki page (inside .git): $page"
            if grep { $self->_is_git_dir_name($_) }
                $part, split m{/}, $path->relative($root);
    }

    # The root itself is a directory, never a page.
    croak "Path outside wiki root: $page" if $path eq $root;

    croak "Not a markdown page: $page" unless $path->basename =~ /\.md\z/i;
    croak 'Not a wiki page ('.(-d $path ? 'a directory' : 'not a plain file')."): $page"
        if -e $path && !-f $path;

    return $path;
}

# The name of a page _resolve_page returned, relative to the root: the form
# list_pages shows. Events carry this, whatever spelling the client used.
sub _page_name {
    my ($self, $path) = @_;
    return decode('UTF-8', Path::Tiny::path($path)->relative($self->_wiki_root_path)->stringify);
}

# All pages below the root, as sorted names relative to it. A page is listed
# only if _resolve_page accepts its name, so the list never offers something
# the other tools refuse: no symlink leading out of the root, into ".git" or to
# a file that is no page. ".git" is not entered, and neither are directory
# symlinks. Directory entries are bytes: a name is listed decoded from UTF-8,
# one that is not valid UTF-8 cannot be sent back and is skipped with a warning.
# So is a directory below the root that cannot be read, such as a root-only
# lost+found; only an unreadable root fails the listing.
sub _list_pages {
    my ($self) = @_;

    my $root = $self->_wiki_root_path;
    my @pages;
    my @dirs = ($root);
    while (my $dir = shift @dirs) {
        my @children = eval { $dir->children };
        if (my $err = $@) {
            die $err if $dir eq $root;
            warn 'list_pages: skipping directory '.$dir->relative($root).': '
                .(ref $err && $err->{err} ? $err->{err} : $err)."\n";
            next;
        }
        for my $child (@children) {
            next if $self->_is_git_dir_name($child->basename);
            if (-d $child) {
                push @dirs, $child unless -l $child;
                next;
            }
            next unless $child->basename =~ /\.md\z/i;
            my $bytes = $child->relative($root)->stringify;
            my $rel = eval { decode('UTF-8', $bytes, Encode::FB_CROAK | Encode::LEAVE_SRC) };
            unless (defined $rel) {
                warn "list_pages: skipping $bytes: the name is not valid UTF-8\n";
                next;
            }
            push @pages, $rel if eval { $self->_resolve_page($rel)->is_file };
        }
    }

    return [sort @pages];
}

sub _create_document {
    my ($self, $page) = @_;

    my $page_path = $self->_resolve_page($page);
    croak "Page not found: $page" unless $page_path->is_file;

    return MCP::Wiki::Document->new(
        file_path  => "$page_path",
        wiki_root  => $self->_wiki_root_path->stringify,
    );
}

# Registers a tool. The wiki root is fixed when the server starts; a call that
# still carries a root_dir is refused instead of being carried out against the
# configured root, where the same page name may stand for a different file.
#
# A handler answers its own failures with an error result that says what went
# wrong. Should a die still escape one, it is answered here as well: MCP::Server
# would turn it into an opaque JSON-RPC "Internal error" and the model would
# learn nothing. Either way the text goes through _error_text.
sub _add_tool {
    my ($self, %spec) = @_;

    my $code = delete $spec{code};
    my $name = $spec{name};

    return $self->server->tool(
        %spec,
        code => sub ($tool, $args) {
            return $tool->text_result(
                'root_dir is not supported: the wiki root is fixed when the server starts', 1
            ) if ref $args eq 'HASH' && exists $args->{root_dir};

            my $result;
            eval { $result = $code->($tool, $args); 1 }
                or $result = $tool->text_result("$name failed: $@", 1);

            if (ref $result eq 'HASH' && $result->{isError}) {
                $_->{text} = $self->_error_text($_->{text})
                    for grep { ($_->{type} // '') eq 'text' } @{ $result->{content} // [] };
            }

            return $result;
        },
    );
}

# An error as the model gets it. The messages come from croak, die and
# Path::Tiny, so they carry Perl's " at FILE line N." and absolute paths. The
# trailers go; the wiki root is cut from every path, which leaves the name
# relative to it, the way pages are named (the root itself becomes "."). Such
# paths are bytes, as on disk, and are decoded on the way.
sub _error_text {
    my ($self, $text) = @_;

    $text =~ s/ at (?:(?! at ).)+? line \d+(?:, <[^>]*> (?:line|chunk) \d+)?\.$//mg;
    $text =~ s/\s+\z//;

    my @roots = grep { defined && length && Path::Tiny::path($_)->is_absolute }
        eval { $self->_wiki_root_path->stringify }, $self->wiki_root;
    for my $root (sort { length $b <=> length $a } @roots) {
        $text =~ s{\Q$root\E(?:/+([^'":\n]*)|(?=['":\s]|\z))}{
            my $rel = $1 // '';
            my $bytes = $rel;
            !length $rel ? '.'
                : (utf8::downgrade($bytes, 1)
                    ? eval { decode('UTF-8', $bytes, Encode::FB_CROAK) } : undef) // $rel
        }ge;
    }

    return $text;
}

# For an error about a heading_path the page does not have: the paths it does
# have, at most 50, so the model can pick the right one. Empty when the page
# has the path after all or cannot be read.
sub _heading_hint {
    my ($self, $doc, $heading_path) = @_;

    my @paths = eval { map { $_->heading_path } $doc->get_toc };
    return '' if $@ || grep { $_ eq ($heading_path // '') } @paths;
    return "\nThe page has no headings." unless @paths;

    my $more = @paths - 50;
    splice @paths, 50 if $more > 0;
    return join "\n", '', 'Heading paths on this page:', @paths,
        ($more > 0 ? "... and $more more" : ());
}

# MCP tool annotations: hints for a client about what a tool does. Every tool
# stays inside the wiki, so none is open-world; a tool that is not read-only
# changes pages, and a destructive one may replace or remove what is there.
sub _annotations {
    my ($self, %hint) = @_;
    return {
        readOnlyHint  => $hint{read_only} ? JSON::PP::true : JSON::PP::false,
        openWorldHint => JSON::PP::false,
        ($hint{read_only} ? () : (
            destructiveHint => $hint{destructive} ? JSON::PP::true : JSON::PP::false,
            idempotentHint  => $hint{idempotent}  ? JSON::PP::true : JSON::PP::false,
        )),
    };
}

sub _setup_tools {
    my ($self) = @_;

    # Tool: list_pages
    $self->_add_tool(
        name        => 'list_pages',
        description => 'List all wiki pages (.md files) below the wiki root',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {},
        },
        code => sub ($tool, $args) {
            my $pages = eval { $self->_list_pages }
                or return $tool->text_result("Cannot list pages: $@", 1);

            return $tool->structured_result({
                pages => $pages,
                count => scalar(@$pages),
            });
        },
    );

    # Tool: get_toc
    $self->_add_tool(
        name        => 'get_toc',
        description => 'Get the table of contents of a wiki page: every heading with its level,'
            .' heading_path and line range. heading_path is the address of a section that'
            .' the other tools take; the line numbers are only valid for the page as this'
            .' call read it and change with any edit.',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
            },
            required => ['page'],
        },
        code => sub ($tool, $args) {
            my $doc = eval { $self->_create_document($args->{page}) };
            if ($@) {
                return $tool->text_result("Invalid page: $@", 1);
            }

            my @toc = eval { $doc->get_toc };
            if ($@) {
                return $tool->text_result("Cannot read page: $@", 1);
            }

            return $tool->structured_result({
                page => $args->{page},
                entries => [map { $_->as_hash } @toc],
            });
        },
    );

    # Tool: get_paragraph
    $self->_add_tool(
        name        => 'get_paragraph',
        description => 'Get the body of a section (without its heading line) by heading path',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
                heading_path => {
                    type => 'string',
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"',
                },
            },
            required => ['page', 'heading_path'],
        },
        code => sub ($tool, $args) {
            my $doc = eval { $self->_create_document($args->{page}) };
            if ($@) {
                return $tool->text_result("Invalid page: $@", 1);
            }

            my $para = eval { $doc->get_paragraph($args->{heading_path}) };
            if ($@) {
                return $tool->text_result("Cannot read page: $@", 1);
            }

            unless ($para) {
                return $tool->text_result("Heading not found: $args->{heading_path}"
                    .$self->_heading_hint($doc, $args->{heading_path}), 1);
            }

            return $tool->structured_result($para);
        },
    );

    # Tool: create_page
    $self->_add_tool(
        name        => 'create_page',
        description => 'Create a new wiki page. Fails if a page of that name already exists.'
            .' Without content the page gets the default content "# <page>", a heading'
            .' made of the page name.',
        annotations => $self->_annotations(),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root, can include subdirectories)',
                },
                content => {
                    type => 'string',
                    description => 'Initial page content',
                },
                reason => {
                    type => 'string',
                    description => 'Reason for creating the page (used as git commit message if git is enabled)',
                },
            },
            required => ['page'],
        },
        code => sub ($tool, $args) {
            my $page_path = eval { $self->_resolve_page($args->{page}) }
                or return $tool->text_result("Invalid page path: $@", 1);

            if (-e $page_path) {
                return $tool->text_result("Page already exists: $args->{page}", 1);
            }

            eval {
                $page_path->parent->mkpath;
                $page_path->spew_utf8($args->{content} // "# $args->{page}\n");
                1;
            } or return $tool->text_result("Create failed: $@", 1);

            $self->_fire_on_change({
                type   => 'create',
                page   => $self->_page_name($page_path),
                reason => $args->{reason},
            });

            return $tool->structured_result({
                success => 1,
                page    => $args->{page},
            });
        },
    );

    # Tool: update_paragraph
    $self->_add_tool(
        name        => 'update_paragraph',
        description => 'Replace the body of a section (its heading line stays) by heading path',
        annotations => $self->_annotations(destructive => 1, idempotent => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
                heading_path => {
                    type => 'string',
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"',
                },
                content => {
                    type => 'string',
                    description => 'New body for the section, without the heading line',
                },
                reason => {
                    type => 'string',
                    description => 'Reason for the change (used as git commit message if git is enabled)',
                },
            },
            required => ['page', 'heading_path', 'content'],
        },
        code => sub ($tool, $args) {
            my $doc = eval { $self->_create_document($args->{page}) };
            if ($@) {
                return $tool->text_result("Invalid page: $@", 1);
            }

            eval { $doc->set_paragraph($args->{heading_path}, $args->{content}) };
            if (my $err = $@) {
                $err =~ s/\s+\z//;
                return $tool->text_result("Update failed: $err"
                    .$self->_heading_hint($doc, $args->{heading_path}), 1);
            }

            $self->_fire_on_change({
                type   => 'update',
                page   => $self->_page_name($doc->file_path),
                heading_path => $args->{heading_path},
                reason => $args->{reason},
            });

            return $tool->structured_result({
                success => 1,
                page    => $args->{page},
                heading_path => $args->{heading_path},
            });
        },
    );

    # Tool: rename_page
    $self->_add_tool(
        name        => 'rename_page',
        description => 'Rename or move a wiki page within the wiki root',
        annotations => $self->_annotations(destructive => 1),
        input_schema => {
            type => 'object',
            properties => {
                from => {
                    type => 'string',
                    description => 'Current page name (path of a .md file relative to the wiki root)',
                },
                to => {
                    type => 'string',
                    description => 'New page name (path of a .md file relative to the wiki root, can include subdirectories)',
                },
            },
            required => ['from', 'to'],
        },
        code => sub ($tool, $args) {
            my $from_path = eval { $self->_resolve_page($args->{from}) }
                or return $tool->text_result("Invalid path: $@", 1);
            my $to_path = eval { $self->_resolve_page($args->{to}) }
                or return $tool->text_result("Invalid path: $@", 1);

            unless (-e $from_path) {
                return $tool->text_result("Page not found: $args->{from}", 1);
            }

            if (-e $to_path) {
                return $tool->text_result("Target already exists: $args->{to}", 1);
            }

            eval {
                $to_path->parent->mkpath;
                $from_path->move($to_path);
                1;
            } or return $tool->text_result("Rename failed: $@", 1);

            $self->_fire_on_change({
                type   => 'rename',
                from   => $self->_page_name($from_path),
                to     => $self->_page_name($to_path),
            });

            return $tool->structured_result({
                success => 1,
                from    => $args->{from},
                to      => $args->{to},
            });
        },
    );

    # Tool: delete_page
    $self->_add_tool(
        name        => 'delete_page',
        description => 'Delete a wiki page',
        annotations => $self->_annotations(destructive => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name to delete (path of a .md file relative to the wiki root)',
                },
            },
            required => ['page'],
        },
        code => sub ($tool, $args) {
            my $page_path = eval { $self->_resolve_page($args->{page}) }
                or return $tool->text_result("Invalid path: $@", 1);

            unless (-e $page_path) {
                return $tool->text_result("Page not found: $args->{page}", 1);
            }

            eval { $page_path->remove; 1 }
                or return $tool->text_result("Delete failed: $@", 1);

            $self->_fire_on_change({
                type => 'delete',
                page => $self->_page_name($page_path),
            });

            return $tool->structured_result({
                success => 1,
                page    => $args->{page},
            });
        },
    );

    # Tool: get_section_history
    $self->_add_tool(
        name        => 'get_section_history',
        description => 'Get commit history for a section identified by heading path',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
                heading_path => {
                    type => 'string',
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"',
                },
            },
            required => ['page', 'heading_path'],
        },
        code => sub ($tool, $args) {
            my $git = $self->git_history;
            unless ($git) {
                return $tool->text_result("Git history not available (git may not be enabled)", 1);
            }

            eval { $self->_resolve_page($args->{page}); 1 }
                or return $tool->text_result("Invalid page: $@", 1);

            my @commits = eval { $git->get_section_commits($args->{page}, $args->{heading_path}) };
            if ($@) {
                return $tool->text_result("Cannot read section history: $@", 1);
            }

            return $tool->structured_result({
                page         => $args->{page},
                heading_path => $args->{heading_path},
                commits      => \@commits,
                count        => scalar(@commits),
            });
        },
    );

    # Tool: restore_section
    $self->_add_tool(
        name        => 'restore_section',
        description => 'Restore a section from a historical commit',
        annotations => $self->_annotations(destructive => 1, idempotent => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
                heading_path => {
                    type => 'string',
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"',
                },
                commit_hash => {
                    type => 'string',
                    description => 'Git commit hash to restore from',
                },
                reason => {
                    type => 'string',
                    description => 'Reason for the restore, passed on to on_change handlers in the restore event; a restore is not committed',
                },
            },
            required => ['page', 'heading_path', 'commit_hash'],
        },
        code => sub ($tool, $args) {
            my $git = $self->git_history;
            unless ($git) {
                return $tool->text_result("Git history not available (git may not be enabled)", 1);
            }

            my $doc = eval { $self->_create_document($args->{page}) };
            if ($@) {
                return $tool->text_result("Invalid page: $@", 1);
            }

            # History patches the page's text with LF line endings; a page that
            # is not valid UTF-8 is refused here, before anything is written
            my $eol;
            my $result = eval {
                (my $current_content, $eol) = $doc->read_for_update;
                $git->restore_section(
                    $args->{page},
                    $args->{heading_path},
                    $args->{commit_hash},
                    { current_content => $current_content }
                );
            };
            if ($@) {
                return $tool->text_result("Restore failed: $@", 1);
            }

            # History already patched the section into the whole document, so
            # that document replaces the page, written back with the page's
            # line ending through the document, whose file_path came from
            # _resolve_page like every file access of a tool
            eval { $doc->write_text($result->{content}, $eol) };
            if ($@) {
                return $tool->text_result("Restore failed: $@", 1);
            }

            $self->_fire_on_change({
                type         => 'restore',
                page         => $self->_page_name($doc->file_path),
                heading_path => $args->{heading_path},
                commit_hash  => $args->{commit_hash},
                reason       => $args->{reason},
            });

            return $tool->structured_result({
                success       => 1,
                page          => $args->{page},
                heading_path  => $args->{heading_path},
                restored_from => $result->{restored_from},
            });
        },
    );
}

sub _build_server {
    my ($self) = @_;
    return MCP::Server->new(name => 'MCP-Wiki', version => $MCP::Wiki::VERSION);
}

=method on_change

    $server->on_change(sub ($event) { ... });

Registers a handler, called after a writing tool changed a page. Every handler
gets a hash reference of its own: C<type> (C<create>, C<update>, C<rename>,
C<delete> or C<restore>) and, by type, C<page>, C<heading_path>, C<reason>,
C<commit_hash>, or C<from> and C<to> for a rename. Page names are relative to
C<wiki_root>, the way C<list_pages> shows them, whatever spelling the client
used: C<sub/./a.md> arrives as C<sub/a.md>, a symlink as the page it points
to. A handler that dies is warned about; the change stands.

=cut

sub on_change {
    my ($self, $handler) = @_;
    push @{$self->_on_change_handlers}, $handler;
    return $self;
}

sub _fire_on_change {
    my ($self, $event) = @_;

    # Auto-commit via git if enabled
    if ($self->use_git && $event->{type} ne 'restore') {
        my $git = eval { $self->git_history };
        warn "Git auto-commit error: $@" if $@;
        if ($git) {
            my $message = $self->_commit_message_for_event($event);
            my $reason = $event->{reason};
            # A rename stages the old name's removal and the new one
            my @paths = $event->{type} eq 'rename'
                ? @{$event}{qw( from to )}
                : $event->{page};
            eval {
                $git->auto_commit(
                    \@paths,
                    $message,
                    (defined $reason ? (reason => $reason) : ()),
                );
            };
            warn "Git auto-commit error: $@" if $@;
        }
    }

    # Call user handlers, each with an event of its own
    for my $handler (@{$self->_on_change_handlers}) {
        eval { $handler->({ %$event }) };
        warn "on_change error: $@" if $@;
    }
}

sub _commit_message_for_event {
    my ($self, $event) = @_;
    my %messages = (
        create  => "Created page",
        update  => "Updated page",
        rename  => "Renamed page",
        delete  => "Deleted page",
    );
    my $type = $event->{type} // 'unknown';
    my $page = $event->{page} // '';
    my $heading = $event->{heading_path} // '';
    if ($heading) {
        return "$messages{$type}: $page ($heading)";
    }
    return "$messages{$type}: $page";
}

sub to_stdio {
    my ($self) = @_;
    $self->server->to_stdio;
}

1;

__END__

=head1 SYNOPSIS

    use MCP::Wiki::Server;

    my $server = MCP::Wiki::Server->new(
        wiki_root => '/path/to/wiki',
        use_git   => 1,
    );

    $server->on_change(sub {
        my $ev = shift;
        if ($ev->{type} eq 'update') {
            say "Page updated: $ev->{page}";
        }
    });

    $server->to_stdio;

=head1 PAGE NAMES

A page is a C<.md> file below C<wiki_root>, and every tool addresses it by its
path relative to that root, for example C<notes.md> or
C<projects/alpha/plan.md>. The extension is part of the name and is matched
without regard to case. C<create_page> and C<rename_page> create missing
directories on the way.

A page name is resolved against the root before anything is read or written:
symlinks are followed, C<..> is applied, and the result has to lie below the
root. A name that leads outside is refused, whether it gets there through
C<..>, through a symlink (including one whose target does not exist yet) or
through a directory that merely shares the root's name as a prefix, such as
C</srv/wiki-old> next to C</srv/wiki>. A symlink that stays inside the root
works like the page it points to.

Three things inside the root are not pages and are refused by every tool:

=over 4

=item *

Any file that is not a C<.md> file, including one reached through a symlink
with a C<.md> name.

=item *

Anything below a directory named C<.git>, in any spelling of upper and lower
case, at any depth, and also when reached through a symlink. The repository of
a wiki with git history is therefore out of reach of the tools.

=item *

Anything that exists under a page name but is no plain file: a directory
called C<notes.md>, a FIFO, a device. A directory with such a name can still
hold pages.

=back

C<list_pages> returns exactly the names the other tools accept. It does not
enter C<.git> or directories that are symlinks, and skips a directory it cannot
read with a warning; only an unreadable C<wiki_root> is an error.

Page names are text; on disk a name is its UTF-8 encoding, so names and
directories in any script work in every tool. A file whose name is not valid
UTF-8 cannot be named by a client: C<list_pages> leaves it out and warns.

The tools take no C<root_dir> argument. A call that passes one is answered with
an error and changes nothing. To serve a different directory, start a server
with a different C<wiki_root>.

=cut