# MCP-Wiki

Markdown wiki MCP server with TOC extraction, paragraph-level editing, and git history.

## Install with Docker (no Perl required)

```bash
docker run --rm \
    -v "$HOME:$HOME" -e HOME="$HOME" \
    raudssus/mcp-wiki --help
```

## Install with Perl

```bash
cpanm MCP::Wiki
```

## Usage

```perl
use MCP::Wiki::Server;

my $server = MCP::Wiki::Server->new(
    wiki_root => '/path/to/wiki',
    use_git   => 1,
);

$server->on_change(sub ($event) {
    # $event->{type} is create, update, rename, delete or restore
    # Useful for auto-commits, webhooks, etc.
});

$server->to_stdio;
```

## MCP Tools

Every tool takes `page` (or `from`/`to`) as a path relative to `wiki_root`. A
section is addressed by `heading_path`, the `#`-joined chain of its ancestor
headings such as `Introduction#Background` -- not by `heading`, and never by
line number. Siblings are not part of the chain: with `# Intro`, `## Alpha`,
`## Beta` the second section is `Intro#Beta`.

| Tool | Required | Optional | Description |
|------|----------|----------|-------------|
| `list_pages` | | | List all wiki pages |
| `get_toc` | `page` | | Get table of contents for a page |
| `get_paragraph` | `page`, `heading_path` | | Get the body of the section under a heading path (heading line not included) |
| `create_page` | `page` | `content` | Create a new wiki page |
| `update_paragraph` | `page`, `heading_path`, `content` | `reason` | Replace a section's body; the heading line stays |
| `rename_page` | `from`, `to` | | Rename/move a page |
| `delete_page` | `page` | | Delete a page |
| `get_section_history` | `page`, `heading_path` | | Get git history for a section (needs `use_git` and Git::Raw) |
| `restore_section` | `page`, `heading_path`, `commit_hash` | `reason` | Restore a section from a git commit (needs `use_git` and Git::Raw) |

`reason` becomes the git commit message when `use_git` is on.

### Known defects

These behave as described today; they are tracked, not fixed:

- `restore_section` hands the full restored document to the section write,
  so a restore does not yield the section as it was (k3).

## Configuration

- `wiki_root`: Root directory for wiki pages (default: current dir)
- `use_git`: Enable git auto-commit on changes (default: 0). Needs the optional
  Git::Raw; without it the history tools answer "not available" and nothing is
  committed. `restore_section` does not auto-commit.
- `commit_reason_required`: accepted (default: 0) but currently has no effect.

On the command line these are `--wiki-root`, `--git` and
`--commit-reason-required`.

## Page names and the wiki root

A page is a `.md` file below `wiki_root`; tools address it by its path relative
to that root (`notes.md`, `projects/alpha/plan.md`). The root is fixed when the
server starts: there is no `root_dir` tool argument, and a call that passes one
is refused.

Page names are resolved (symlinks, `..`) before use. Every tool refuses a name
that

- leads outside the root,
- is not a `.md` file, or
- lies below a `.git` directory (any case, any depth, also through a symlink).

`list_pages` returns exactly the pages the other tools accept.

To serve another directory, start a server with another `wiki_root`
(`mcp-wiki --wiki-root /path/to/wiki`).

## License

Copyright (c) 2026 Torsten Raudssus. Same terms as Perl 5 itself.