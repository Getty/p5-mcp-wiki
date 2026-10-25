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
lib/MCP/Wiki/Git.pm          # deprecated subclass of Git::History, unused by the server
bin/mcp-wiki                 # CLI runner
t/                           # Test::More, tempdir-based, run without Git::Raw
```

A section is addressed by its `heading_path` (`Intro#Background`), never by
line numbers — those are only valid for the one parse run they came from.

## Key Commands

```bash
prove -lr t/            # canonical — recursive; plain `prove -l t/` silently skips subdirectories
prove -lv t/10-toc.t    # single test
dzil build              # build distribution and Docker image (needs a container engine)
DZIL_DOCKER_API_SKIP=1 dzil build   # distribution only, no engine contact
```

`Git::Raw` is not installed on this machine, and the suite must stay green without
it: `git_history` then returns `undef` and the history tools answer cleanly with
"not available". That is a feature, not a gap.

## State of the code

`PLAN.md` is the original draft, not a description of the current state — content
hashing, conflict markers, `Git::Blame` and async callbacks in it do not exist. On
contradiction `lib/` wins.

Known defects and product proposals are karr cards (`karr list`), not prose in
the docs; work one only when it is the card you hold.

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
| Commits, `Changes`, card → done, pre-release audit | `mcp-wiki-release-manager` |

The agents get their skills via `briefing.skills` (see `.claude/agents/`); the
main agent delegates instead of loading them itself. Skill sources live under
`.claude/skills/`.
