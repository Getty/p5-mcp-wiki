# MCP-Wiki

Markdown wiki MCP server with TOC extraction, paragraph-level editing, and git history.

## Install with Docker (no Perl required)

```bash
docker run -i --rm -v /path/to/wiki:/wiki raudssus/mcp-wiki
```

The server speaks MCP over stdin/stdout (hence `-i`) and serves the mounted
`/wiki`, the image's working directory and so the default wiki root. Options
go after the image name: `docker run -i --rm -v /path/to/wiki:/wiki
raudssus/mcp-wiki --git` commits every change and serves the history tools.
The mount must hold the git repository; for a wiki in a subdirectory of it,
mount the repository and add `--wiki-root /wiki/subdirectory`.

The container runs as uid 1000 and never changes the ownership of what you
mount. When `/wiki` (or the directory given by `--wiki-root`) is not writable
for that uid, it stops with a message saying so; fix it with `--user UID:GID`
of the directory's owner, or by giving uid 1000 write access.

The image is built from the built distribution, not from the checkout:
`dzil build` does it, or by hand `dzil build` and then `docker build` in the
build directory (`MCP-Wiki-*/`).

## Install with Perl

```bash
cpanm MCP::Wiki
```

## Usage

```perl
use v5.36;
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

Every tool except `list_pages` takes `page` (or `from`/`to`) as a path
relative to `wiki_root`. A section is addressed by `heading_path`, the
`#`-joined chain of its ancestor headings such as `Introduction#Background` --
not by `heading`, and never by line number. A `#` or `\` inside a heading's own
text is written `\#` or `\\`. The second and later heading with the same path
get `[2]`, `[3]` ... on the last segment (`Page#Notes[2]`); `get_toc` shows them
so and every tool accepts them. Which lines count as headings (code fences, front
matter, HTML comments are skipped) and how the path is built is documented in
`MCP::Wiki::TOC::Parser`. Siblings are not part of the
chain: with `# Intro`, `## Alpha`, `## Beta` the second section is
`Intro#Beta`.

| Tool | Required | Optional | Description |
|------|----------|----------|-------------|
| `list_pages` | | `prefix` | List all wiki pages, or only those below the directory `prefix` |
| `get_toc` | `page` | `max_level`, `include_preview` | Get table of contents for a page, every entry with the `hash` of its section; `max_level` (1-6) cuts deeper headings, `include_preview` false drops the previews |
| `get_paragraph` | `page`, `heading_path` | | Get the body of the section under a heading path (heading line not included) and its `hash` |
| `get_page` | `page` | | Get the whole text of a page and its `hash`, e.g. a page without headings |
| `create_page` | `page` | `content`, `reason` | Create a new wiki page; fails if it exists, default content `# <name>`, the file name without `.md` |
| `update_paragraph` | `page`, `heading_path`, `content` | `reason`, `expected_hash` | Replace a section's body; the heading line stays; refused if the section no longer has the `hash` in `expected_hash` |
| `rename_page` | `from`, `to` | `reason` | Rename/move a page |
| `delete_page` | `page` | `reason` | Delete a page |
| `get_section_history` | `page`, `heading_path` | | Get git history for a section (needs `use_git` and Git::Raw) |
| `restore_section` | `page`, `heading_path`, `commit_hash` | `reason` | Restore a section from a git commit (needs `use_git` and Git::Raw) |

`reason` becomes the whole git commit message when `use_git` is on; without one
the commit gets a generated message naming the page. `restore_section` is
committed too: its message is the `reason`, else `Restore <heading_path> from
<short hash>`.

The `heading_path` `""` is the preamble: the text before the first heading,
front matter included (all of a page without headings). `get_paragraph` reads
it and `update_paragraph` replaces it like any section.

A section's `hash` is the SHA-256 (hex) of its bytes on disk, heading line
included, subsections not. Passing it back as `expected_hash` makes a write
fail with "changed since read", and write nothing, when someone else changed
the section in between; without it a write is unconditional. It is a check,
not a lock.

## Configuration

- `wiki_root`: Root directory for wiki pages (default: current dir)
- `use_git`: Enable git auto-commit on changes (default: 0). Needs the optional
  Git::Raw and a git repository that the wiki root is, or lies in: a
  subdirectory of the repository or a linked worktree (found from the wiki
  root upwards; page names stay relative to the wiki root). Without either the
  server warns once at startup and goes on without git: the history tools
  answer "not available" and nothing is committed.
- `commit_reason_required`: every tool that writes (`create_page`,
  `update_paragraph`, `rename_page`, `delete_page`, `restore_section`) refuses a
  call without a non-empty `reason`, and its description says so (default: 0,
  `reason` stays optional).

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
- is not a `.md` file (a directory or FIFO named `x.md` is none either), or
- lies below a `.git` directory (any case, any depth, also through a symlink).

A name that is itself a symlink to a page in the root is read and written like
that page, but `rename_page` and `delete_page` refuse it (they would act on the
page it points to and leave the link dangling): name the page itself.

`list_pages` returns exactly the pages the other tools accept.

To serve another directory, start a server with another `wiki_root`
(`mcp-wiki --wiki-root /path/to/wiki`).

## License

Copyright (c) 2026 Torsten Raudssus. Same terms as Perl 5 itself.