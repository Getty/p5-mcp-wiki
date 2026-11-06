---
name: mcp-wiki-core
description: Load before editing p5-mcp-wiki — MCP::Wiki::Server tool surface, heading_path as section identity, TOC parser, optional Git::Raw history, path security model.
user-invocable: false
model: inherit
---

# mcp-wiki-core

MCP::Wiki is a stdio MCP server that manages a directory of Markdown files as a wiki: list and
search pages, read a page's TOC, read and edit one section at a time, optionally commit every
change and restore a section from the Git history. A section is addressed by its
`heading_path`, never by line numbers. The client is a language model reading untrusted wiki
content, so `_resolve_page` is the only thing that keeps a call inside the wiki. Open defects
and proposals are karr cards (`karr list`), not part of this skill.

## Vocabulary

| Term | Meaning |
|------|---------|
| **page** | A `.md` file below `wiki_root`, outside any `.git`, named relative to the root (`sub/dir/page.md`) |
| **wiki_root** | Base directory, fixed at construction, default `.`; no tool call can change it |
| **section** | From a heading line to the line before the next heading of any level — flat, an H1 ends at its first H2 |
| **body** | A section without its heading line — what `get_paragraph` returns and `update_paragraph` replaces |
| **preamble** | The lines before the first heading, heading_path `""`; no TOC entry |
| **heading_path** | `#`-joined chain of a heading's ancestors and itself (`Intro#Background`) — the only stable address |
| **event** | Hashref handed to `on_change` handlers after a write; types and keys in the tool table |

## Layers

```
bin/mcp-wiki                  # Getopt::Long -> Server->new -> to_stdio
lib/MCP/Wiki.pm               # $VERSION + POD only
lib/MCP/Wiki/Server.pm        # Moo; the 15 tools, _resolve_page, on_change, auto-commit
lib/MCP/Wiki/Document.pm      # one page: TOC, sections, preamble, hashes, structure edits
lib/MCP/Wiki/TOC/Parser.pm    # line-based ATX parser -> entries, builds heading_path
lib/MCP/Wiki/TOC/Entry.pm     # value object; as_hash is the wire form of get_toc
lib/MCP/Wiki/Git/History.pm   # Git::Raw: section commits, restore, auto_commit
lib/MCP/Wiki/Git.pm           # deprecated subclass of Git::History, published API only
```

`Document` trusts the `file_path` it gets; confinement is the Server's job. The Server never
uses `MCP::Wiki::Git`.

## Tools and events

| Tool | Arguments (`[optional]`) | Event (keys besides `type`) |
|------|--------------------------|-----------------------------|
| `list_pages` | `[prefix]` | — |
| `get_toc` | `page`, `[max_level]`, `[include_preview]` | — |
| `get_page` | `page` | — |
| `get_paragraph` | `page`, `heading_path` | — |
| `create_page` | `page`, `[content]`, `[reason]` | `create` {page, reason} |
| `update_paragraph` | `page`, `heading_path`, `content`, `[reason]`, `[expected_hash]` | `update` {page, heading_path, reason} |
| `write_page` | `page`, `content`, `[reason]`, `[expected_hash]` | `write` {page, reason} |
| `add_section` | `page`, `heading`, `[parent]`, `[before]`, `[content]`, `[reason]` | `add_section` {page, heading_path (new), reason} |
| `delete_section` | `page`, `heading_path`, `[reason]`, `[expected_hash]` | `delete_section` {page, heading_path, reason} |
| `rename_heading` | `page`, `heading_path`, `heading`, `[reason]`, `[expected_hash]` | `rename_heading` {page, heading_path (new), previous_heading_path, reason} |
| `search_pages` | `query`, `[prefix]`, `[limit]` | — |
| `rename_page` | `from`, `to`, `[reason]` | `rename` {from, to, reason only when given} — no `page` key |
| `delete_page` | `page`, `[reason]` | `delete` {page, reason only when given} |
| `get_section_history` | `page`, `heading_path` | — |
| `restore_section` | `page`, `heading_path`, `commit_hash`, `[reason]` | `restore` {page, heading_path, commit_hash, reason} |

- Register through `_add_tool`, never `$self->server->tool`: it refuses a call carrying
  `root_dir`. Every tool sets `annotations => $self->_annotations(...)` (never open-world);
  a `heading_path` argument's description names `get_toc` and gives an example (t/46).
- Event names (`page`, `from`, `to`) are `_page_name` of the resolved path, as `list_pages`
  names it, never the client's spelling (`x/../a.md` → `a.md`). Auto-commit and History use
  the same string. `reason` may be `undef`.
- `commit_reason_required`: `_add_tool` refuses a call to any tool not annotated read-only
  without a visible `reason` (an error result, not -32602) and says so in the descriptions.
  `reason` stays out of `required`, so a new writing tool needs an optional `reason`.

## Invariants

**Confinement**
- Every file access of a tool goes through `_resolve_page`: it resolves the name component by
  component from the realpath'd root and checks `$root->subsumes` at every step (`/wiki-evil`
  is not under `/wiki`). It refuses any `.git` component (any case), the root, a basename not
  ending in `.md`, an existing path that is no plain file. A tool building a path itself
  reopens the hole.
- `rename_page`/`delete_page` use `_resolve_page_not_link`: a name that is itself a symlink is
  refused (the link would dangle); reads and writes through a link work.
- Names are characters, the filesystem is bytes: `_resolve_page` walks the UTF-8 encoding and
  returns bytes; names going out are decoded; History encodes before touching disk. Mixing
  the two re-encodes a name into another file.
- `list_pages` lists exactly what `_resolve_page` accepts — no `.git`, no directory symlinks,
  a non-UTF-8 name or unreadable subdirectory skipped with a `warn`. `prefix` is walked by
  `_walk_page($prefix, 1)` with the same checks; `search_pages` walks `_list_pages($prefix)`
  and re-resolves every page. `max_level`/`include_preview` only shorten `get_toc`.

**Handlers**
- `code => sub { my ($tool, $args) = @_; ... }` — a closure over `$self`, no signatures.
  Answer `$tool->structured_result({...})`, fail with `$tool->text_result($msg, 1)`.
- Wrap everything that can die (`_resolve_page`, `_create_document`, file I/O, History) in
  `eval` and answer with a prefix naming what failed (`Cannot read page: …`). `_add_tool`'s
  `<tool> failed: …` is a safety net, not a substitute.
- Error texts pass `_error_text` (no `at FILE line N.`, root cut from paths): never build an
  absolute path into a message. An unknown `heading_path` gets `_heading_hint` (at most 50).
- The `-e` test before create/rename is only for the message; `_create_exclusive` (`O_EXCL`)
  and `_move_no_clobber` (`link` + `unlink`) never replace a page that appears meanwhile.

**Addressing and parser**
- `TOC::Parser::_build_heading_path` keeps an ancestor stack: entering level L pops every open
  heading of level >= L, then pushes (`# A`, `### C`, `## B` give `A`, `A#C`, `A#B`).
- A repeated path gets an occurrence suffix on its last segment (`Page#Notes[2]`), children
  carry it, the first keeps its address. The parser assigns it, so `Document` and History do a
  plain first match on the whole string; History numbers each revision by the same rule.
- Segments are escaped by `Parser::escape_segment` (`\` → `\\`, `#` → `\#`, trailing `[digits]`
  → `\[digits]`); `split_heading_path` is the inverse; the tools never split.
- What counts as a heading follows CommonMark — the rules live in the POD of
  `MCP::Wiki::TOC::Parser` (HEADING RECOGNITION, HEADING PATHS); change them there. ATX, 0–3
  spaces indent, a closing `#` run only after whitespace (`# C#` stays `C#`); front matter,
  fences, HTML comment blocks and 4-space-indented lines are skipped; no Setext. Anchors are
  GitHub-style, part of `get_toc`'s wire form, never an address.
- The address is a tool argument, History's key and what users have stored: changing how it is
  built — stack, separator, escaping, which lines are headings — is ADR-grade, Breaking in
  `Changes`, never part of an unrelated change.
- `line_start`/`line_end` belong to one parse; every call parses afresh. Never carry a line
  range across calls or commits.

**Sections and pages**
- TOC `line_start`/`line_end`, `content_preview` and `char_count` include the heading line.
- `hash` (SHA-256 hex, `Document::_section_hash`) covers the section's bytes, heading line to
  `line_end`, subsections not; `get_page` hashes all page bytes. `expected_hash` is compared
  against the read the write works on ("changed since read", nothing written); no lock. Only
  `Document` hashes.
- `get_paragraph` then `update_paragraph` writes the page back byte-identical. The preamble
  (`""`) works like a body, front matter included; a page without headings is all preamble.
- `Document::_check_body` (`Parser::body_problem`) refuses a body with a heading line outside a
  closed fence or comment, or one left open, in `update_paragraph` and `add_section`; the
  message points at `add_section`. `restore_section` is not checked.
- Structure edits re-parse the new text before writing: the new heading reads back as itself,
  existing paths stay unchanged (a duplicate in front of its twin is refused), levels <= 6.
  `add_section` changes no other section's bytes; add then delete restores the page byte for
  byte. `delete_section` takes the subtree.
- `Document` reads a page once per operation; `write_text` is its only write: it keeps the
  permission bits and refuses a read-only page. CRLF pages are written back as CRLF, a leading
  U+FEFF is kept. Invalid UTF-8 reads leniently but is never written (`read_for_update`).

**Git and change events**
- With `use_git`, `BUILD` opens the repository via `Git::Raw::Repository->discover`
  (subdirectory, linked worktree). `git_history` is `undef` when `Git::Raw` does not load or
  no repository is found: one `warn` at startup, the history tools answer "Git history not
  available", writes stay quiet. History prefixes page names with the root's path in the
  workdir (`_repo_path`).
- `Git::Raw` is a `recommends`, loaded by a runtime `require` — the sanctioned exception to
  `getty-perl-core`'s use-at-the-top rule; loading it before `MCP::Server` segfaults. Only
  History and `MCP::Wiki::Git` call it; bytes in, decoded text out.
- A commit uses the repository's identity, else `MCP::Wiki <mcp-wiki@localhost>`; an index
  matching HEAD commits nothing. Tests inject `git_history` stand-ins: the Server calls only
  `get_section_commits`, `restore_section` and `auto_commit`.
- `_fire_on_change` runs after the write: auto-commit first, then each handler in `eval` with
  its own copy, errors `warn`ed; the write counts as done whatever they do. Auto-commit hangs
  off it, never off a tool; every event type commits, `restore` too, staging each path as the
  work tree has it (a rename both names, a delete the removal). Message: the `reason` if
  visible, else generated (`Updated page: m.md (Intro#Alpha)`, `Restore Intro#Alpha from 0123456`).
- `restore_section` reads with `Document::read_for_update`, hands History the LF text, writes
  what History returns with `write_text`, fires `restore`. Only History patches.

`PLAN.md` is the original draft; where it contradicts `lib/`, `lib/` wins.

## Docker

One image, `raudssus/mcp-wiki` (`docker_image` in `dist.ini`), built by the bundle on `dzil
build` (`DZIL_DOCKER_API_SKIP=1` skips), pushed on `dzil release` — publish gate. Context is
the **built dist**: `cpanm --installdeps --with-recommends .` (brings Git::Raw), then `cpanm .`,
no dzil in the image. uid 1000, `WORKDIR /wiki`, never chowns; the entrypoint stops when the
effective `--wiki-root` is not writable and `exec`s mcp-wiki without a shell. t/08 pins it;
registry and build path are the maintainer's decision.

## Verification

`prove -lr t/` is canonical; never the network or a real wiki. With `Git::Raw` the real-API
files run (t/42, t/49–t/51, t/54, t/56, t/63, t/70-binary-scripts.t); without it they skip — keep both green. Guards:
t/05 cpanfile, t/06 README table and bin POD, t/07 dead code, t/34 and t/46 schemas and
annotations, t/36 confinement, t/69 `$VERSION` in every module. A new or changed tool needs
its README row (t/06), annotations (t/46) and t/36 coverage; `scripts/binary-verify.sh` and
`scripts/binary-smoke.sh` pin the tool count (15) and the tool names.
