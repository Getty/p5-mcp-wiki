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
use Fcntl qw( O_WRONLY O_CREAT O_EXCL );
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

Every tool that writes (C<create_page>, C<update_paragraph>, C<rename_page>,
C<delete_page>, C<restore_section>) refuses a call without a non-empty
C<reason> with an error result, and its description says so. Without it
C<reason> stays optional. Default: 0

=cut
has commit_reason_required => (
    is => 'ro',
    default => 0,
);

=attr server

The L<MCP::Server> the tools are registered on, named C<MCP-Wiki> with the
distribution's version. Built on first use; one passed to C<new> gets the nine
tools added to it.

=cut
has server => (
    is => 'lazy',
    builder => '_build_server',
);

has _on_change_handlers => (
    is => 'ro',
    default => sub { [] },
);

=attr git_history

The L<MCP::Wiki::Git::History> for C<wiki_root>, built on first use when
C<use_git> is set and L<Git::Raw> loads; otherwise undef, and then the history
tools answer that git history is not available and nothing is committed. An
object passed to C<new> is used instead; the server calls only
C<get_section_commits>, C<restore_section> and C<auto_commit> on it, always
with the page name relative to C<wiki_root>.

=cut
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
    my ($path) = $self->_walk_page($page);
    return $path;
}

# The walk of _resolve_page. In list context it also says whether the name
# itself, its last component, is a symlink: rename and delete refuse such a
# name, because the path they get is the link's target.
#
# With $as_dir the name is a directory (the prefix of list_pages): it gets the
# same walk and the same checks for the root and ".git", but must be an
# existing directory, may be the root, and may not go through a symlink,
# because list_pages enters none.
sub _walk_page {
    my ($self, $page, $as_dir) = @_;

    croak 'Page name required' unless defined $page && !ref $page && length $page;
    croak 'Invalid page name' if $page =~ /\0/;

    my $root = $self->_wiki_root_path;
    my $path = $root;
    my $is_link = 0;
    for my $part (split m{/+}, encode('UTF-8', $page)) {
        next if $part eq '' || $part eq '.';
        $path = $part eq '..' ? $path->parent : $path->child($part);
        $is_link = $part ne '..' && -l $path ? 1 : 0;
        croak "Directory goes through a symlink: $page" if $as_dir && $is_link;
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

    if ($as_dir) {
        croak "Not a directory: $page" unless -d $path;
        return ($path, 0);
    }

    # The root itself is a directory, never a page.
    croak "Path outside wiki root: $page" if $path eq $root;

    croak "Not a markdown page: $page" unless $path->basename =~ /\.md\z/i;
    croak 'Not a wiki page ('.(-d $path ? 'a directory' : 'not a plain file')."): $page"
        if -e $path && !-f $path;

    return ($path, $is_link);
}

# For rename and delete: croaks when the page name itself is a symlink. The
# resolved path would be the link's target, so the tool would move or remove
# another page and leave the link dangling. Reading and writing through a
# link keep working.
sub _resolve_page_not_link {
    my ($self, $page) = @_;
    my ($path, $is_link) = $self->_walk_page($page);
    croak 'Page name is a symlink to '.$self->_page_name($path)
        .': name that page instead of the link: '.$page if $is_link;
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
#
# With a $prefix, a directory relative to the root, only that directory is
# walked and listed; it is checked like a page name.
sub _list_pages {
    my ($self, $prefix) = @_;

    my $root = $self->_wiki_root_path;
    my $start = defined $prefix && length $prefix
        ? ($self->_walk_page($prefix, 1))[0] : $root;
    my @pages;
    my @dirs = ($start);
    while (my $dir = shift @dirs) {
        my @children = eval { $dir->children };
        if (my $err = $@) {
            die $err if $dir eq $start;
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

# The tools test for an existing page before they write, but a page can appear
# between that test and the write. These two act so that it is never replaced:
# they return 1 when done, 0 when the name exists by now, and die on any other
# failure.

# Writes a new page; O_EXCL makes the creation fail on an existing name.
sub _create_exclusive {
    my ($self, $path, $content) = @_;

    sysopen my $fh, "$path", O_WRONLY | O_CREAT | O_EXCL
        or return $!{EEXIST} ? 0 : die "Cannot create page: $!\n";
    binmode $fh;
    unless (print {$fh} encode('UTF-8', $content) and close $fh) {
        my $err = $!;
        unlink "$path";    # ours, and incomplete
        die "Cannot write page: $err\n";
    }
    return 1;
}

# Moves a page; link fails on an existing name where rename would replace it.
# A filesystem without hard links gets a plain rename after one more test.
sub _move_no_clobber {
    my ($self, $from, $to) = @_;

    unless (link "$from", "$to") {
        return 0 if $!{EEXIST} || -e $to || -l $to;
        $from->move($to);
        return 1;
    }
    unless (unlink "$from") {
        my $err = $!;
        unlink "$to";    # the second name we just made
        die "Cannot remove the old name: $err\n";
    }
    return 1;
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

    # With commit_reason_required every tool that writes refuses a call
    # without a reason, and its description says so. A tool writes unless its
    # annotations call it read-only.
    my $needs_reason = $self->commit_reason_required
        && !$spec{annotations}{readOnlyHint};
    if ($needs_reason) {
        $spec{description} .= ' A non-empty reason is required (this server was started'
            .' with commit_reason_required).';
        my $reason = $spec{input_schema}{properties}{reason};
        $reason->{description} .= ' - required on this server' if $reason;
    }

    return $self->server->tool(
        %spec,
        code => sub ($tool, $args) {
            return $tool->text_result(
                'root_dir is not supported: the wiki root is fixed when the server starts', 1
            ) if ref $args eq 'HASH' && exists $args->{root_dir};

            return $tool->text_result(
                "A reason is required: $name was called without a non-empty reason,"
                .' and this server was started with commit_reason_required', 1
            ) if $needs_reason
                && !(ref $args eq 'HASH' && defined $args->{reason} && !ref $args->{reason}
                    && $args->{reason} =~ /\S/);

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
        description => 'List all wiki pages (.md files) below the wiki root, or with prefix'
            .' only those below one directory',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {
                prefix => {
                    type => 'string',
                    description => 'Only list pages below this directory (path relative to the wiki root, e.g. "projects/alpha"); the walk descends nowhere else. Default: the whole wiki',
                },
            },
        },
        code => sub ($tool, $args) {
            my $pages = eval { $self->_list_pages($args->{prefix}) }
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
            .' call read it and change with any edit. A long page gives a long answer:'
            .' max_level and include_preview shorten it without changing any heading_path.',
        annotations => $self->_annotations(read_only => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name (path of a .md file relative to the wiki root)',
                },
                max_level => {
                    type => 'integer',
                    minimum => 1,
                    maximum => 6,
                    description => 'Only list headings down to this level (1-6); deeper sections stay addressable by their heading_path. Default: all levels',
                },
                include_preview => {
                    type => 'boolean',
                    description => 'Include content_preview in every entry. Default: true; false leaves it out',
                },
            },
            required => ['page'],
        },
        code => sub ($tool, $args) {
            my $max_level = $args->{max_level};
            return $tool->text_result('Invalid max_level: an integer from 1 to 6', 1)
                if defined $max_level && (ref $max_level || $max_level !~ /\A[1-6]\z/);

            my $doc = eval { $self->_create_document($args->{page}) };
            if ($@) {
                return $tool->text_result("Invalid page: $@", 1);
            }

            my @toc = eval { $doc->get_toc };
            if ($@) {
                return $tool->text_result("Cannot read page: $@", 1);
            }

            @toc = grep { $_->level <= $max_level } @toc if defined $max_level;
            my @entries = map { $_->as_hash } @toc;
            if (exists $args->{include_preview} && !$args->{include_preview}) {
                delete $_->{content_preview} for @entries;
            }

            return $tool->structured_result({
                page => $args->{page},
                entries => \@entries,
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
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"; a # or \ inside a heading\'s own text is written \# or \\\\',
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
            .' Without content the page gets the default content "# <name>", a heading'
            .' made of the file name without ".md" (not of the directories).',
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

            my $created = eval {
                $page_path->parent->mkpath;
                my $title = decode('UTF-8', $page_path->basename =~ s/\.md\z//ir);
                $self->_create_exclusive($page_path, $args->{content} // "# $title\n");
            };
            return $tool->text_result("Create failed: $@", 1) unless defined $created;
            return $tool->text_result("Page already exists: $args->{page}", 1) unless $created;

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
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"; a # or \ inside a heading\'s own text is written \# or \\\\',
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
        description => 'Rename or move a wiki page within the wiki root.'
            .' Refuses a name that is itself a symlink: name the page it points to.',
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
                reason => {
                    type => 'string',
                    description => 'Reason for the rename (used as git commit message if git is enabled)',
                },
            },
            required => ['from', 'to'],
        },
        code => sub ($tool, $args) {
            my $from_path = eval { $self->_resolve_page_not_link($args->{from}) }
                or return $tool->text_result("Invalid path: $@", 1);
            my $to_path = eval { $self->_resolve_page_not_link($args->{to}) }
                or return $tool->text_result("Invalid path: $@", 1);

            unless (-e $from_path) {
                return $tool->text_result("Page not found: $args->{from}", 1);
            }

            if (-e $to_path) {
                return $tool->text_result("Target already exists: $args->{to}", 1);
            }

            my $moved = eval {
                $to_path->parent->mkpath;
                $self->_move_no_clobber($from_path, $to_path);
            };
            return $tool->text_result("Rename failed: $@", 1) unless defined $moved;
            return $tool->text_result("Target already exists: $args->{to}", 1) unless $moved;

            $self->_fire_on_change({
                type   => 'rename',
                from   => $self->_page_name($from_path),
                to     => $self->_page_name($to_path),
                (defined $args->{reason} ? (reason => $args->{reason}) : ()),
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
        description => 'Delete a wiki page.'
            .' Refuses a name that is itself a symlink: name the page it points to.',
        annotations => $self->_annotations(destructive => 1),
        input_schema => {
            type => 'object',
            properties => {
                page => {
                    type => 'string',
                    description => 'Page name to delete (path of a .md file relative to the wiki root)',
                },
                reason => {
                    type => 'string',
                    description => 'Reason for the deletion (used as git commit message if git is enabled)',
                },
            },
            required => ['page'],
        },
        code => sub ($tool, $args) {
            my $page_path = eval { $self->_resolve_page_not_link($args->{page}) }
                or return $tool->text_result("Invalid path: $@", 1);

            unless (-e $page_path) {
                return $tool->text_result("Page not found: $args->{page}", 1);
            }

            eval { $page_path->remove; 1 }
                or return $tool->text_result("Delete failed: $@", 1);

            $self->_fire_on_change({
                type => 'delete',
                page => $self->_page_name($page_path),
                (defined $args->{reason} ? (reason => $args->{reason}) : ()),
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
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"; a # or \ inside a heading\'s own text is written \# or \\\\',
                },
            },
            required => ['page', 'heading_path'],
        },
        code => sub ($tool, $args) {
            my $git = $self->git_history;
            unless ($git) {
                return $tool->text_result("Git history not available (git may not be enabled)", 1);
            }

            my $page_path = eval { $self->_resolve_page($args->{page}) }
                or return $tool->text_result("Invalid page: $@", 1);

            # History finds the page in each commit's tree by its canonical
            # name, the one auto-commit stages
            my @commits = eval {
                $git->get_section_commits($self->_page_name($page_path), $args->{heading_path});
            };
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
        description => 'Restore a section from a historical commit. The restored page is committed'
            .' with the reason as message, else "Restore <heading_path> from <short hash>".',
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
                    description => 'Full heading path as get_toc returns it: the #-joined ancestor headings down to the section, e.g. "Introduction#Background"; a # or \ inside a heading\'s own text is written \# or \\\\',
                },
                commit_hash => {
                    type => 'string',
                    description => 'Git commit hash to restore from',
                },
                reason => {
                    type => 'string',
                    description => 'Reason for the restore (used as git commit message if git is enabled)',
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
                    $self->_page_name($doc->file_path),
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
C<commit_hash>, or C<from> and C<to> for a rename. A rename or delete carries
C<reason> only when the call gave one. Page names are relative to
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
    if ($self->use_git) {
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
    # A restore names the section and the commit it came from
    return 'Restore '.($event->{heading_path} // '').' from '
        .substr($event->{commit_hash} // '', 0, 7) if $type eq 'restore';
    # A rename names both pages, every other event the one it changed
    my $page = $type eq 'rename'
        ? ($event->{from} // '').' -> '.($event->{to} // '')
        : $event->{page} // '';
    my $heading = $event->{heading_path} // '';
    if ($heading) {
        return "$messages{$type}: $page ($heading)";
    }
    return "$messages{$type}: $page";
}

=method to_stdio

    $server->to_stdio;

Serves the tools over standard input and output: reads one JSON-RPC request
per line, answers each in turn and returns when the input ends.

=cut

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

=head1 TOOLS

The server offers nine tools. A page is named by its path relative to
C<wiki_root> (see L</PAGE NAMES>), a section by its C<heading_path>: the
C<#>-joined headings from the top level down to the section, as C<get_toc>
returns them, for example C<Introduction#Background>; a C<#> or C<\> inside a
heading's own text is written C<\#> or C<\\>. The second and later heading with
the same path get a C<[2]>, C<[3]> ... on the last segment (C<Page#Notes[2]>);
C<get_toc> shows them so. Which lines are headings and how
the path is built is described in L<MCP::Wiki::TOC::Parser>. The line numbers
C<get_toc> reports are only valid for the page as that call read it.

=over 4

=item C<list_pages> (optional C<prefix>)

All pages below C<wiki_root>, sorted, and their count. With C<prefix>, a
directory relative to the root such as C<projects/alpha>, only the pages below
it, still named relative to the root; the walk enters no other directory. The
prefix is checked like a page name (it may not leave the root, name C<.git> or
go through a symlink) and has to be an existing directory.

=item C<get_toc> (C<page>, optional C<max_level>, C<include_preview>)

Every heading of the page: level, heading, anchor, C<heading_path>, line range,
a preview of the section and its length in characters. C<max_level> (1 to 6)
leaves out the headings below that level; they stay addressable by their
C<heading_path>, which this does not change. C<include_preview> false leaves
C<content_preview> out of every entry. Both only make a long answer shorter;
without them the answer is the full table of contents.

=item C<get_paragraph> (C<page>, C<heading_path>)

The section's body without its heading line, with heading, C<heading_path> and
line range. An unknown C<heading_path> is answered with the ones the page has.

=item C<create_page> (C<page>, optional C<content>, C<reason>)

Creates the page and any missing directories. Fails if the page exists; without
C<content> the page starts with a heading made of the file name without
C<.md>: C<# c> for C<a/b/c.md>. Directories that a rename or delete leaves empty
stay.

=item C<update_paragraph> (C<page>, C<heading_path>, C<content>, optional C<reason>)

Replaces the section's body; its heading line stays.

=item C<rename_page> (C<from>, C<to>, optional C<reason>)

Renames or moves a page, creating missing directories. Never replaces an
existing page. Refuses a name that is itself a symlink.

=item C<delete_page> (C<page>, optional C<reason>)

Deletes the page. Refuses a name that is itself a symlink.

=item C<get_section_history> (C<page>, C<heading_path>)

The commits that created or changed the section, newest first. Needs
C<use_git> and L<Git::Raw>.

=item C<restore_section> (C<page>, C<heading_path>, C<commit_hash>, optional C<reason>)

Puts the section's text from that commit back into the page and leaves the rest
of the page as it is. With C<use_git> the restore is committed, with the
C<reason> as message, else C<Restore Intro#Background from 1a2b3c4> (section and
short commit hash). Needs C<use_git> and L<Git::Raw>.

=back

Every tool that writes calls the L</on_change> handlers afterwards. With
C<use_git>, every write is committed, with the C<reason> as message when one is
given.

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
works like the page it points to for reading and writing. C<rename_page> and
C<delete_page> refuse a name that is itself a symlink (as the source or target of
a rename): they would move or remove the page it points to and leave the link
dangling; name that page instead. A page inside a symlinked directory is not
affected.

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