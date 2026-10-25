# MCP-Wiki House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Markdown wiki MCP server with TOC extraction and git history. Read first: `Server.pm` (the
tool closures), `Document.pm` and `TOC/Parser.pm` form one chain — the parser's
`heading_path` is the address every tool and the git history depend on.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code, Docker | `mcp-wiki-worker` (default) |
| Write/extend tests | `mcp-wiki-test-writer` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-wiki-release-manager` |
| Read-only research, audit, gap analysis | `mcp-wiki-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, the MCP tool surface and its wire format,
`heading_path` construction, TOC parsing, path validation, the git history/restore path,
`on_change`, the Dockerfile and entrypoint, tests. Pure prose docs and `Changes` notes are not.

## Release

`maint/release-after.pl` and any `docker push` fall under the publish gate like the CPAN
upload.

## Deviations from the house rules

One board, no cross-repo handoff. The public tracker is GitHub issues on `Getty/p5-mcp-wiki`
plus CPAN RT.

## Hazards — the background is in skill `mcp-wiki-core`

- **This server writes to a real user's files.** `wiki_root` defaults to `.` — never exercise
  write tools against the checkout or `$HOME`, always a `Path::Tiny` tempdir.
- **`_resolve_page` is the only thing confining a tool call.** Route every file access
  through it and extend `t/36-server-path-security.t` with the new tool.
- **`heading_path` is a stored address, not an implementation detail.** Fixing its
  construction invalidates every address users already hold — an ADR-grade decision, do not
  slip it into an unrelated change.
- **Three known defects are ticketed, not hidden** — heading_path ancestry, the
  get/set_paragraph off-by-one and restore_section applying its patch twice. Do not
  "discover" them again as new findings, and do not fix them opportunistically — take the
  ticket or leave them.
- **`PLAN.md` is a draft, not a spec.** When it contradicts `lib/`, `lib/` wins.
- **The Docker setup is declared WIP by its own commit message** (9e571a6); registry targets
  in `dist.ini` and `maint/release-after.pl` disagree. It needs a decision, not incremental
  polish.
- **Tests must stay green without `Git::Raw`** — it is not installed here, and the
  graceful-degrade path is a feature.

## Perl specifics — reference, don't restate

Module loading, Moo patterns, cpanfile pinning: skills `getty-perl-core`, `getty-perl-moo`.
`[@Author::GETTY]` bundle (bumps `$VERSION` and tags on release), POD, `{{$NEXT}}`: skill
`getty-perl-release-author-getty`. dist.ini mechanics: `perl-release-dist-ini`. MCP server
setup: `perl-mcp`.
