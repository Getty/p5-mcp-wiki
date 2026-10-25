---
name: mcp-wiki-core
description: Load before editing p5-mcp-wiki — MCP::Wiki::Server tool surface, heading_path as section identity, TOC parser, optional Git::Raw history, path security model.
user-invocable: false
model: inherit
---

# mcp-wiki-core

MCP::Wiki is a stdio MCP server that manages a directory full of Markdown files as a
wiki: extract the TOC, read/write sections paragraph by paragraph, optionally commit per
change and restore sections from the Git history. One product, one
distribution, one entry point (`bin/mcp-wiki`).

## Vocabulary

| Term | Meaning |
|------|---------|
| **page** | A `.md` file under the wiki_root and outside of `.git`, addressed **relative** to the wiki_root (`sub/dir/page.md`) |
| **wiki_root** | Base directory; fixed at server start, no tool call can change it |
| **section** | Range from one heading to the next heading (of any level) |
| **heading_path** | `#`-separated chain that identifies a section — the only stable address |
| **TOC entry** | `MCP::Wiki::TOC::Entry`, a heading plus line range and preview |
| **on_change** | Callback chain; fires after writing, carries `{ type, page, ... }` |
| **event type** | `create` · `update` · `rename` · `delete` · `restore` |

## Layer Map

```
bin/mcp-wiki                     # CLI: Getopt::Long -> Server->new -> to_stdio
lib/MCP/Wiki.pm                  # only $VERSION + POD, no code
lib/MCP/Wiki/Server.pm           # Moo; 9 tools in _setup_tools; on_change; Git auto-commit
lib/MCP/Wiki/Document.pm         # a single page: content/get_toc/get_paragraph/set_paragraph
lib/MCP/Wiki/TOC/Parser.pm       # line-based ATX parser -> entry list
lib/MCP/Wiki/TOC/Entry.pm        # value object + as_hash (the wire form of the TOC)
lib/MCP/Wiki/Git/History.pm      # Git::Raw: section history, restore, auto_commit
lib/MCP/Wiki/Git.pm              # legacy code, NOT used by the server (see below)
```

Tools: `list_pages` `get_toc` `get_paragraph` `create_page` `update_paragraph`
`rename_page` `delete_page` `get_section_history` `restore_section`.

## Core invariants

- **Every file access by a tool goes through `_resolve_page`.** The client is a
  language model that reads unchecked wiki content; the page name is the only thing that
  keeps a call inside the wiki. The helper walks the name component by component from the
  resolved root, resolves existing parts immediately via `realpath` (symlinks, `..`)
  and appends the not-yet-existing rest as plain names. Rejected is anything that
  leaves the root (checked at every step with `subsumes`, i.e. at the path boundary:
  `/wiki-evil` is not under `/wiki`), anything with a component `.git` (any
  casing, in the name as well as in the resolved path) and anything that is not a `.md` file. A
  tool that builds a path itself reopens the hole. `list_pages` lists exactly
  what `_resolve_page` accepts, and does not enter `.git`.
- **`wiki_root` defaults to `.`** (`bin/mcp-wiki`). The server therefore writes into
  the directory it was started from — a careless test run or manual step
  changes real files. Writing tools must only be tested against a
  `Path::Tiny` tempdir, never against the checkout or `$HOME`.
- **There is no `root_dir`.** Tools are registered via `_add_tool`; the wrapper
  rejects any call with `root_dir` instead of running it against the configured root,
  where the same page name can mean a different file. New tools also go
  through `_add_tool`, never directly through `$server->tool`.
- **`heading_path` is the section identity, line numbers are not.** Every
  tool call builds a fresh `Document` and parses again; `line_start`/`line_end` are the
  result of *this* parse run and worthless after any change. Never carry a line range
  across two calls — not in the history either, which is exactly why the
  blob of every commit is parsed anew. The address is the argument of four tools and
  the key the Git history matches on; a correction of how it is built invalidates
  all addresses users already hold — ADR grade, not on the side.
- **Tool handlers are closures, not methods.** `code => sub ($tool, $args)` — `$tool`
  is the `MCP::Tool` instance, not the server. The server comes in through the closure variable
  `$self`. Output exclusively via `$tool->structured_result(...)` or
  `$tool->text_result($msg, 1)` for errors. Details: skill `perl-mcp`.
- **Errors are tool results, not exceptions.** Every handler wraps `_create_document`
  in `eval` and answers with `text_result(..., 1)`. A `die` that propagates up to the transport
  kills the stdio session — when extending the tools, carry the `eval` frame
  along.
- **Git is optional and lazy.** `git_history` returns `undef` when `use_git` is off
  **or** `Git::Raw` is missing (`_build_git_history` checks both via `eval require`).
  The history tools then answer cleanly with "Git history not available". This
  softness is intentional: the distribution must stay installable and testable without Git::Raw.
  Do not introduce a file-level `use Git::Raw`.
- **Auto-commit hangs off `_fire_on_change`, not off the tools.** A new writing
  tool commits automatically as soon as it calls `_fire_on_change` — and only then.
  `restore` is excluded from auto-commit (`$event->{type} ne 'restore'`).
- **on_change handlers must not cause a failure.** Handlers run in `eval`, errors
  are `warn`ed; the write still counts as successful. This order —
  write the file first, then callbacks — is the guarantee consumers build on.
- **The TOC parser is deliberately line-based, not CommonMark.** It knows ATX headings
  (`#`..`######`), toggles on ```` ``` ```` lines and skips 4-space indent.
  It does **not** recognize setext headings (`===`/`---`), HTML comments or table cells.
  Whoever wants real AST accuracy swaps out the parser — instead of patching special case after special case
  into the regex.
- **A section ends at the *next* heading, whatever its level.** An H1
  therefore does not contain its H2 children; `content_preview` and `char_count` always refer
  to this flat range — including the heading line itself.

## Sharp edges — verified, not assumed

These three are defects, not conventions. Do not "fix them along the way", do not
rework them without a ticket — but never document them as correct behavior either.

- **`_build_heading_path` does not build an ancestor chain.** It collects *all* preceding
  headings with `level <= current level`, so siblings too. With
  `# Intro / ## Alpha / ## Beta / # Other` you get `Intro#Alpha#Beta` and `Intro#Other`
  instead of `Intro#Beta` and `Other`. That makes every section addressed via `heading_path`
  order-dependent: an inserted sibling section changes the address of all
  following ones. Correct would be a stack that clears everything `>= level` when entering a
  level.
- **`get_paragraph` and `set_paragraph` are not round-trip safe.** `get` returns the
  section **including** the heading line (`line_start-1 .. line_end-1`); `set` replaces
  from the line *after* the heading, but with the length including the heading — so
  one line too many. `set_paragraph($p, get_paragraph($p)->{content})` duplicates the
  heading and eats the first line of the following section.
- **`restore_section` applies the patch twice.** `Git::History::restore_section`
  already returns the **complete new document** in `content`; `Server.pm` passes
  exactly that to `$doc->set_paragraph($heading_path, ...)` and thereby writes the
  whole document into one section. Either History returns only the section text,
  or Server writes the file directly — not both.

## Legacy code

- **`lib/MCP/Wiki/Git.pm` is dead.** The server uses exclusively
  `MCP::Wiki::Git::History`. Both classes have `repo`/`auto_commit`; the variant in
  `Git.pm` passes an index entry as the parent list to `create_commit` and so cannot
  work. No callers, no tests — a candidate for deletion, not for further
  maintenance.
- **`_build_history_file` / `.mcp-wiki-history.json`** is built, but nobody
  reads or writes it. The history comes entirely from the Git blobs.
- **`update_content_hash`**, `Digest::SHA` in `Server.pm`, `to_json`,
  `Types::Standard` in `Entry.pm` and `commit_reason_required`: imported or
  declared as attributes, evaluated nowhere. `PLAN.md` additionally describes content hashing,
  conflict markers, `MCP::Wiki::Git::Blame` and async callbacks — none of that exists.
  **`PLAN.md` is a draft, not a specification of the current state.**

## Docker setup — WIP

The Docker setup is WIP according to its own commit message (9e571a6). The registry targets in
`dist.ini` and in `maint/release-after.pl` contradict each other. That needs a
decision, not creeping polish.

## Verification

`prove -lr t/` is the canonical signal — recursive, so subdirectories created later
under `t/` are not silently skipped. `dzil test` is the
release equivalent.

The tests run without `Git::Raw` and without network; `t/40-git.t` deliberately only checks
that the module fails cleanly without Git::Raw. That must stay that way.
