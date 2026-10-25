# CLAUDE.md

**MCP::Wiki** is a stdio MCP server that manages a directory full of Markdown files as a
wiki: extract the TOC, read and write sections paragraph by paragraph, optionally
commit per change and restore sections from the Git history. One
distribution, one entry point (`bin/mcp-wiki`), shipped via CPAN and a
Docker image.

## Project structure

```
lib/MCP/Wiki/Server.pm       # Moo; registers the 9 MCP tools, on_change, auto-commit
lib/MCP/Wiki/Document.pm     # read/write a single page
lib/MCP/Wiki/TOC/Parser.pm   # line-based ATX parser -> entry list
lib/MCP/Wiki/TOC/Entry.pm    # value object; as_hash is the wire form of the TOC
lib/MCP/Wiki/Git/History.pm  # Git::Raw: section history, restore, auto-commit
lib/MCP/Wiki/Git.pm          # legacy code, not used by the server
bin/mcp-wiki                 # CLI runner
t/                           # Test::More, tempdir-based, run without Git::Raw
```

A section is addressed by its `heading_path` (`Intro#Background`), never by
line numbers — those are only valid for the one parse run they came from.

## Key Commands

```bash
prove -lr t/            # canonical — recursive; plain `prove -l t/` silently skips subdirectories
prove -lv t/10-toc.t    # single test
dzil build              # build distribution
```

`Git::Raw` is not installed on this machine, and the suite must stay green without
it: `git_history` then returns `undef` and the history tools answer cleanly with
"not available". That is a feature, not a gap.

## State of the code

`PLAN.md` is the original draft, not a description of the current state — content
hashing, conflict markers, `Git::Blame` and async callbacks in it do not exist. On
contradiction `lib/` wins.

Three verified defects are known and filed as karr tickets (heading_path collects
siblings instead of ancestors, get/set_paragraph are not round-trip safe,
restore_section applies its patch twice). Mechanics and blast radius are in
skill `mcp-wiki-core`; do not fix them on the side.

A page is a `.md` file under `wiki_root`, outside of `.git`. Every
file access by a tool goes through `_resolve_page` in `Server.pm`; the model is described in
skill `mcp-wiki-core`, guarded by `t/36-server-path-security.t`.

## Delegation

Do not touch behavior-relevant code yourself; hand it to the right agent —
the principle is the shared rule `getty-agent-delegation` (skilletor bundle
`getty-cpan-dist@getty`), the lanes are in `.claude/rules/mcp-wiki-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug, Docker | `mcp-wiki-worker` (default) |
| Write or extend tests | `mcp-wiki-test-writer` |
| Pre-release audit | `mcp-wiki-release-manager` |

The agents get their skills via `briefing.skills` (see `.claude/agents/`); the
main agent delegates instead of loading them itself. Skill sources live under
`.claude/skills/`.
