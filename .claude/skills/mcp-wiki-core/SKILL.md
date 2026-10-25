---
name: mcp-wiki-core
description: Load before editing p5-mcp-wiki — MCP::Wiki::Server tool surface, heading_path as section identity, TOC parser, optional Git::Raw history, path security model.
user-invocable: false
model: inherit
---

# mcp-wiki-core

MCP::Wiki is a stdio MCP server that manages a directory of Markdown files as a wiki:
list pages, extract a page's TOC, read and replace one section at a time, optionally
commit changes and restore a section from the Git history. A section is addressed
by its `heading_path`, never by line numbers. The client is a language model reading
untrusted wiki content, so `_resolve_page` is the only thing that keeps a call inside
the wiki. Open defects and proposals are karr cards (`karr list`), not part of this skill.

## Vocabulary

| Term | Meaning |
|------|---------|
| **page** | A `.md` file below the wiki_root, outside any `.git`, named relative to the root (`sub/dir/page.md`) |
| **wiki_root** | Base directory, fixed at construction; no tool call can change it |
| **section** | From a heading line to the line before the next heading of any level |
| **body** | A section without its heading line — what `get_paragraph` returns and `update_paragraph` replaces |
| **heading_path** | `#`-joined chain of a heading's ancestors and itself (`Intro#Background`) — the only stable address |
| **TOC entry** | `MCP::Wiki::TOC::Entry`; `as_hash` is the wire form of `get_toc` |
| **event** | Hashref passed to `on_change` handlers after a write; `type` is `create`·`update`·`rename`·`delete`·`restore` |

## Layers

```
bin/mcp-wiki                  # Getopt::Long -> Server->new -> to_stdio
lib/MCP/Wiki.pm               # $VERSION + POD only
lib/MCP/Wiki/Server.pm        # Moo; the 9 tools, _resolve_page, on_change, auto-commit
lib/MCP/Wiki/Document.pm      # one page: get_toc, get_paragraph, set_paragraph on top of
                              # read_for_update/write_text (also the Server's restore path)
lib/MCP/Wiki/TOC/Parser.pm    # line-based ATX parser -> entries, builds heading_path
lib/MCP/Wiki/TOC/Entry.pm     # value object
lib/MCP/Wiki/Git/History.pm   # Git::Raw: section commits, restore, auto_commit
lib/MCP/Wiki/Git.pm           # deprecated subclass of Git::History, published API only
```

`Document` trusts the `file_path` it gets and uses its `wiki_root` only to name the page in
error messages; confinement is the Server's job. The Server never uses `MCP::Wiki::Git`.

## Tools and events

| Tool | Arguments (`[optional]`) | Event (keys besides `type`) |
|------|--------------------------|-----------------------------|
| `list_pages` | — | — |
| `get_toc` | `page` | — |
| `get_paragraph` | `page`, `heading_path` | — |
| `create_page` | `page`, `[content]`, `[reason]` | `create` {page, reason} |
| `update_paragraph` | `page`, `heading_path`, `content`, `[reason]` | `update` {page, heading_path, reason} |
| `rename_page` | `from`, `to` | `rename` {from, to} — no `page` key |
| `delete_page` | `page` | `delete` {page} |
| `get_section_history` | `page`, `heading_path` | — |
| `restore_section` | `page`, `heading_path`, `commit_hash`, `[reason]` | `restore` {page, heading_path, commit_hash, reason} |

Every tool sets `annotations => $self->_annotations(...)` (read-only, destructive,
idempotent hints; never open-world) — a new tool needs one. `serverInfo.version` is
`$MCP::Wiki::VERSION`. A `heading_path` description says it is the full path from `get_toc`
with an example (t/46 checks the keywords).

`reason` may be `undef`. `page`, `from` and `to` are `_page_name` of the resolved path: relative
to the root as `list_pages` shows it, never the client's spelling (`x/../a.md` → `a.md`, an
in-root symlink → its target); auto-commit stages those names, and the history tools hand
History the same name — it looks the page up in each commit's tree by that string.

## Invariants

**Confinement**
- Every file access of a tool goes through `_resolve_page`. It walks the name component by
  component from the realpath'd root, resolves each existing part at once (`realpath`:
  symlinks, `..`), appends the not-yet-existing rest as plain names and checks
  `$root->subsumes($path)` at every step — a path boundary, so `/wiki-evil` is not under
  `/wiki`. It refuses any `.git` component (any case, in the name and in the resolved
  path), the root itself, any resolved basename not ending in `.md` (any case), and a
  resolved path that exists but is no plain file (a `dir.md` directory, a FIFO). A tool
  that builds a path itself reopens the hole.
- Names are characters, the filesystem is bytes: `_resolve_page` walks the UTF-8 encoding
  of the name and returns a byte path, like the root and everything `realpath` and
  `readdir` give back — mixing the two re-encodes a name into a different file. Names
  going out (`list_pages`, `_page_name`) are decoded; History encodes before touching disk.
- `list_pages` lists exactly the names `_resolve_page` accepts; it enters neither `.git`
  nor directory symlinks, and skips a name that is not valid UTF-8 or a subdirectory it
  cannot read with a `warn` (an unreadable root is still an error).
- `wiki_root` defaults to `.`: the server writes into the directory it was started from.
  Exercise writing tools only against a `Path::Tiny` tempdir.
- Register tools through `_add_tool`, never `$self->server->tool` directly: the wrapper
  refuses any call carrying `root_dir`, so the same page name can never mean another file.

**Handlers**
- Handlers are closures: `code => sub ($tool, $args)`, `$tool` is the `MCP::Tool`, the
  server is the closed-over `$self`. Answer with `$tool->structured_result({...})`, failures
  with `$tool->text_result($msg, 1)`.
- Wrap every call that can die (`_resolve_page`, `_create_document`, file I/O, History) in
  `eval` and answer the failure as a tool result whose prefix says what failed
  (`Cannot read page: …`, `Delete failed: …`). `_add_tool` answers whatever still escapes as
  `<tool> failed: …` — a safety net, not a substitute for the eval. Without it
  `MCP::Server::handle` would answer JSON-RPC -32603 `Internal error`: the session survives,
  but the model gets an opaque error and the message only reaches the server log.
- `_add_tool` passes every error text through `_error_text`: Perl's `at FILE line N.` goes,
  the wiki root is cut from paths (bytes, decoded there) so names stay root-relative. Put
  `$@` in a message freely; never build an absolute path into one yourself. An unknown
  `heading_path` gets `_heading_hint`: the page's paths, at most 50, then `... and N more`.
- The `-e` test before a create or rename is only for the message: a page can appear right
  after it. `_create_exclusive` (`O_EXCL`) and `_move_no_clobber` (`link` + `unlink`; a
  plain move after one more test where there are no hard links) never replace one. t/47
  opens that window by wrapping `Path::Tiny::mkpath`, so the target's `->parent->mkpath`
  stays between test and act.

**Addressing**
- `heading_path` is built in `TOC::Parser::_build_heading_path` as an ancestor stack:
  entering level L pops every open heading of level >= L, then pushes. `# Intro`,
  `## Alpha`, `## Beta`, `# Other` give `Intro`, `Intro#Alpha`, `Intro#Beta`, `Other`;
  `# A`, `### C`, `## B` give `A`, `A#C`, `A#B`.
- Duplicate paths are not disambiguated; every lookup (`Document`, `History`) takes the
  first matching entry.
- The address is a tool argument, the key History matches commits on, and what users have
  stored. Changing how it is built — the stack, the separator, which lines count as
  headings, what their text is — invalidates every stored address: an ADR-grade decision,
  never part of an unrelated change.
- `line_start`/`line_end` (1-based, inclusive) belong to one parse. Every tool call builds a
  fresh `Document` and parses again, and History re-parses each commit's blob; never carry a
  line range from one call or commit to the next.

**Sections**
- Sections are flat: an H1 ends at its first H2 as at any other heading. TOC `line_start`,
  `line_end`, `content_preview` (first 100 chars, then `...`) and `char_count` cover the
  section **including** its heading line.
- `get_paragraph` returns the body; `set_paragraph`/`update_paragraph` replace exactly the
  body and keep the heading. get followed by set writes the file back byte-identical.
- Lines before the first heading belong to no section; no section tool reaches them.
- `Document` reads a page's bytes once per operation and parses and cuts that one string;
  `Document::write_text` is a document's only write; it keeps the page's permission bits
  and refuses a read-only page, leaving it as it is. A page whose first line ends in CRLF
  is worked on as LF text and written back as CRLF. A page that is not valid UTF-8 reads
  leniently (U+FFFD) but is never written: `read_for_update` refuses it.

**Parser**
- Deliberately line-based, not CommonMark. A heading is a line starting at column 0 with
  1–6 `#`, whitespace and text; a trailing `#` run is stripped even without a space before
  it (`# C#` → `C`). A line starting with ```` ``` ```` (any indent) toggles a fence; lines
  indented 4 spaces are skipped.
- Setext headings and headings indented 1–3 spaces are never headings; `~~~` fences, front
  matter and HTML comments are not understood, so a heading-shaped line inside them counts.
  More accuracy means replacing the parser (see Addressing), not special cases in the regex.

**Git and change events**
- `git_history` is lazy: `undef` unless `use_git` is on and `eval { require Git::Raw }`
  succeeds; the history tools then answer "Git history not available". That eval-require is
  the sanctioned exception to `getty-perl-core`'s use-at-the-top rule — `Git::Raw` is a
  `recommends`, never a file-level `use`. Loading `Git::Raw` before `MCP::Server`
  (Mojolicious) segfaults on this build: one more reason it stays lazy, and why t/42 loads
  the server first.
- Only History (and `MCP::Wiki::Git`, its deprecated subclass) calls `Git::Raw`; the Server
  only probes with the require. `Git::Raw` takes and returns bytes: paths and commit messages
  go in encoded as UTF-8, blob text, messages and author come out decoded.
- A commit is signed with the repository's configured identity, else
  `MCP::Wiki <mcp-wiki@localhost>`. The first commit on an unborn branch has no parent; an
  index that matches HEAD commits nothing.
- `git_history` can be passed to `new`. The Server calls only `get_section_commits`,
  `restore_section` and `auto_commit` on it; tests inject stand-ins (t/37 and t/55 record
  what the Server hands over).
- `_fire_on_change` runs after the file is written: auto-commit first, then every handler in
  `eval` with a shallow copy of its own, errors `warn`ed. The write counts as successful
  whatever they do.
- Auto-commit hangs off `_fire_on_change`, not off the tools: a writing tool commits when it
  fires its event, and only then. It needs `use_git` and a `git_history`; `restore` events
  are excluded. `auto_commit` takes a path or a list of paths and stages each as the work
  tree has it — present means added, missing means removed — so a rename commits `from` and
  `to` together and a delete commits the removal. The commit message is the event's
  `reason` alone when it has visible text, else the generated one (`Updated page: m.md
  (Intro#Alpha)`, `Renamed page: a.md -> b.md`).
- `restore_section`: the Server reads the page with `Document::read_for_update` (LF text and
  the page's line ending; a page that is not valid UTF-8 is refused before History is
  asked), hands History the LF text, writes the complete document History returns with
  `Document::write_text` and fires `restore`. Only History patches.

**Declared, not built**
- `commit_reason_required` (`--commit-reason-required`) is accepted and never read.
- `PLAN.md` is the original draft; where it contradicts `lib/`, `lib/` wins.

## Docker

One image, `raudssus/mcp-wiki`, named by `docker_image` in `dist.ini`. The bundle's
`Docker::API` builds it on every `dzil build`/`dzil test` (`DZIL_DOCKER_API_SKIP=1` skips)
and pushes it on `dzil release` — publish gate. The entrypoint drops root to the owner of
`$MCP_WIKI_ROOT` via `setpriv`, no shell in between, so arguments arrive unsplit. t/08 pins
this; changing the registry or the build path is the maintainer's decision.

## Verification

`prove -lr t/` is canonical (recursive). The suite runs without `Git::Raw` and without
network; `t/41` covers `MCP::Wiki::Git` without a repository, and the opt-in files against
the real API (t/42, t/49–t/51, t/54, t/56) skip without it.

| Guard | Holds |
|-------|-------|
| t/05 | cpanfile matches what `lib/` and `bin/` load; `Git::Raw` stays `recommends`; minimum perl 5.020 or later |
| t/06 | README tool table = registered schemas (required/optional); bin POD = `GetOptions` |
| t/07 | no `update_content_hash`, history JSON file, `Digest::SHA`, `to_json`, `Types::Standard` |
| t/08 | Docker setup and the single registry |
| t/34 | request level: `tools/list` schemas = the registered ones; a missing required argument is refused with -32602 |
| t/36 | every tool stays inside the root — extend it for every new tool |
| t/37 | restore writes History's document once, via a stand-in |
| t/39 | event `page`/`from`/`to` are named as `list_pages` names them, whatever the client's spelling; each handler gets its own copy |
| t/42 | real `Git::Raw`: commit chain, author fallback, history, restore, non-ASCII |
| t/43 | non-ASCII names are listed as text and accepted back (`get_toc`, `get_paragraph`, `delete_page`); a name that is not valid UTF-8 is skipped with a warning |
| t/45 | tool errors carry no absolute path and no `at FILE line N.`; an unknown `heading_path` lists the page's paths, at most 50 |
| t/46 | declared arguments, descriptions, every tool's annotations, `serverInfo.version` = `$MCP::Wiki::VERSION` |
| t/47 | create/rename never replace a page that appears between the existence test and the write |

A new or changed tool therefore also needs its README row (t/06), annotations (t/46) and t/36
coverage.
