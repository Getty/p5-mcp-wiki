# MCP-Wiki House Rules

The shared house rules (engineering discipline, delegation lock, publish gate, karr, CPAN
release) come from skilletor bundle `getty-cpan-dist@getty` as `.claude/rules/.local.*.md`; if
missing, run `skilletor sync` and publish nothing until they load. This file adds what is true
only here, and wins where it differs.

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

## Release and deviations

`dzil release` uploads to CPAN **and** pushes the Docker image `raudssus/mcp-wiki`; it and
any `docker push` fall under the publish gate. `dzil build` builds the image locally too —
`DZIL_DOCKER_API_SKIP=1` skips it. `t/08-docker.t` pins the Docker setup; changing the
registry or the build path is the maintainer's decision. One board, no cross-repo handoff;
the public tracker is GitHub issues on `Getty/p5-mcp-wiki` plus CPAN RT.

## Hazards — the background is in skill `mcp-wiki-core`

- **This server writes to a real user's files.** `wiki_root` defaults to `.` — never exercise
  write tools against the checkout or `$HOME`, always a `Path::Tiny` tempdir.
- **`_resolve_page` is the only thing confining a tool call.** Route every file access
  through it and extend `t/36-server-path-security.t` with the new tool.
- **`heading_path` is a stored address, not an implementation detail.** Changing how it is
  built — or how the parser finds headings — invalidates addresses users already hold: an
  ADR-grade decision, never slipped into an unrelated change.
- **`PLAN.md` is a draft, not a spec.** When it contradicts `lib/`, `lib/` wins.
- **The suite stays green with and without `Git::Raw`.** It is installed here, so the
  real-API tests run; the degrade path ("Git history not available") is a feature — check it
  with `PERL5OPT=-MTest::Without::Module=Git::Raw prove -lr t/`.

## Perl specifics — reference, don't restate

Module loading, Moo, cpanfile pinning: `getty-perl-core`, `getty-perl-moo`. The
`[@Author::GETTY]` bundle, POD, `{{$NEXT}}`: `getty-perl-release-author-getty`. dist.ini:
`perl-release-dist-ini`. MCP server setup: `perl-mcp`.
