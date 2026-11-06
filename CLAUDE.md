# CLAUDE.md

**MCP::Wiki** is a stdio MCP server that manages a directory full of Markdown files as a
wiki: list and search pages, extract the TOC, read and edit one section at a time,
optionally commit per change and restore sections from the Git history. One distribution,
one entry point (`bin/mcp-wiki`), shipped via CPAN and a Docker image.

## Project structure

```
lib/MCP/Wiki/Server.pm       # Moo; registers the 15 MCP tools, on_change, auto-commit
lib/MCP/Wiki/Document.pm     # one page: TOC, sections, preamble, hashes, structure edits
lib/MCP/Wiki/TOC/Parser.pm   # line-based ATX parser -> entry list
lib/MCP/Wiki/TOC/Entry.pm    # value object; as_hash is the wire form of the TOC
lib/MCP/Wiki/Git/History.pm  # Git::Raw: section history, restore, auto-commit
lib/MCP/Wiki/Git.pm          # deprecated subclass of Git::History, unused by the server
bin/mcp-wiki                 # CLI runner
scripts/binary-*.sh          # standalone binary: prepare (CI build leg), verify, smoke
t/                           # Test::More, tempdir-based
```

A section is addressed by its `heading_path` (`Intro#Background`), never by line numbers.

## Key commands

```bash
prove -lr t/            # canonical — recursive; plain `prove -l t/` silently skips subdirectories
prove -lv t/10-toc.t    # single test
PERL5OPT=-MTest::Without::Module=Git::Raw prove -lr t/   # the same without Git::Raw
DZIL_DOCKER_API_SKIP=1 dzil build   # distribution only; plain `dzil build` also builds the image
```

`Git::Raw` is optional (`recommends`): with it the real-API history tests run, without it
the history tools answer "not available" and those tests skip. Both stay green.

`PLAN.md` is the original draft, not the current state; on contradiction `lib/` wins.
Known defects and product proposals are karr cards (`karr list`).

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle in the shared rule `getty-agent-delegation` (skilletor bundle
`getty-cpan-dist@getty`), lanes in `.claude/rules/mcp-wiki-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug, Docker | `mcp-wiki-worker` (default) |
| Write or extend tests | `mcp-wiki-test-writer` |
| Standalone binary: `scripts/binary-*`, `binary` keys, `binaries.yml`, README install section | `mcp-wiki-binary-worker` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-wiki-release-manager` |
| Read-only research, audit, gap analysis | `mcp-wiki-worker` ("read-only, change nothing") |

Every subagent is a `mcp-wiki-*` agent — never the built-in `general-purpose`/`Explore`/`Plan`.

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main agent
delegates rather than loading them. The project's own skill lives under
`.claude/skills/mcp-wiki-core/`; the shared ones come from `.claude/skilletor.json`
(`skilletor sync`).
