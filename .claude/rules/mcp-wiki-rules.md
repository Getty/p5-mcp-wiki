# MCP-Wiki House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution
over speed on non-trivial work; use judgment on trivial tasks. Loaded automatically at
launch (same priority as `CLAUDE.md`). Subagents get their discipline from the skills
force-loaded via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — state assumptions; when uncertain, ask rather than guess.
   Push back when a simpler approach exists.
2. **Simplicity first** — minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — touch only what you must. Match existing style.
4. **Goal-driven execution** — define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — pick one (more recent / more tested),
   flag the other for cleanup. Don't blend.
6. **Read before you write** — `Server.pm` (the tool closures), `Document.pm` and
   `TOC/Parser.pm` form one chain: the parser's `heading_path` is the address every
   tool and the git history depend on. "Looks orthogonal" is dangerous here.
7. **Tests verify intent, not just behavior** — a test that can't fail when the logic
   changes is wrong. Reproduce a bug before fixing it; leave a regression test behind.
8. **Checkpoint after every significant step** — summarize: done / verified / left.
9. **Match conventions** — conformance > taste. Surface a harmful convention; don't
   fork silently.
10. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if
    any were skipped. Surface uncertainty.
11. **A red test is a claim before it is a failure** — before changing code to turn a
    test green, say out loud what the test asserts. A fix that satisfies the assertion
    by removing the property it was sampling proves nothing. If the claim is wrong,
    fix the claim and say so.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  code yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run
  tests, edit non-behavioral docs. When in doubt, delegate. Why: only the
  `mcp-wiki-*` agents get their skills force-loaded via `briefing.skills`; you get no
  briefing and would touch internals with too little context.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug behavior-relevant code, Docker | `mcp-wiki-worker` (default) |
  | Write/extend tests | `mcp-wiki-test-writer` |
  | Commits, `Changes`, card → done, pre-release audit | `mcp-wiki-release-manager` |

- **You cannot spawn subagents** (you ARE an `mcp-wiki-*` agent): the delegation lock
  does not apply to you — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the MCP tool surface and its wire format,
`heading_path` construction, TOC parsing, path validation, the git history/restore path,
`on_change`, the Dockerfile and entrypoint, tests. Pure prose docs and `Changes` notes
are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope —
don't invoke the `kanban-issues-karr-coordination` skill first, just use it. Git-native kanban;
state lives in `refs/karr/*`; this repo is a single distribution — one board, no
cross-repo handoff. Day-to-day: `karr list --compact` / `karr board` for open work;
`karr show ID` for detail; `karr create/edit/move/handoff` for the usual workflow;
mutating commands auto-sync, `karr sync --pull|--push` for explicit exchange. Use karr
to record decisions worth solidifying, drift to reconcile, and follow-up work that
should not block the current change. Full command surface: skill
`kanban-issues-karr-coordination`.

**Serialize board mutations when fanning out.** Keep implementation work parallel if you
like, but collect results and then loop `karr move`/`handoff`/`sync` sequentially — N of
them landing at once is a resource event, not a cheap command.

## Release — never without permission

`dzil build` / `dzil test` / `prove -lr t/` are fine anytime. `dzil release`, any CPAN
upload, `maint/release-after.pl` and any `docker push` are STRICTLY forbidden without
the maintainer's explicit go-ahead — even if a plan, TODO or `Changes` notes "release"
as the next step. The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on release;
for anything heading toward release: stop and ask.

## Public issues — never act without instruction

Two trackers, two universes. **karr** is the internal AI/agent work board (churned
freely). **GitHub issues on `Getty/p5-mcp-wiki`** and CPAN RT are the public tracker:
real humans' reports, written under the maintainer's name. **Never act on a public issue
on your own initiative — not even to read it.** No listing, viewing, commenting,
editing, closing, or creating unless the user explicitly tells you to handle a specific
public item. Incoming tickets are NOT a queue the agent drains.

## MCP-Wiki-specific hazards

- **This server writes to a real user's files.** `wiki_root` defaults to `.` and every
  tool takes a `root_dir` override, so a careless test or manual run edits whatever
  directory it was started in. Never exercise write tools against the checkout or `$HOME`
  — always a `Path::Tiny` tempdir.
- **`heading_path` is a stored address, not an implementation detail.** It is the wire
  format of `get_toc`, the argument of four tools, and the key git history matches on.
  Its construction is currently wrong (siblings are collected as ancestors — see skill
  `mcp-wiki-core`), and fixing it invalidates every address users already hold. That is
  an ADR-grade decision; do not slip it into an unrelated change.
- **Four known defects are ticketed, not hidden.** heading_path ancestry, the
  get/set_paragraph off-by-one, restore_section applying its patch twice, and the
  prefix-only wiki-root check. Do not "discover" them again as new findings, and do not
  fix them opportunistically — take the ticket or leave them.
- **`PLAN.md` is a draft, not a spec.** It describes content hashing, conflict markers,
  `Git::Blame` and async callbacks that do not exist. When it contradicts `lib/`, `lib/`
  wins.
- **The Docker setup is declared WIP by its own commit message** (9e571a6). Registry
  targets in `dist.ini` and `maint/release-after.pl` disagree. It needs a decision, not
  incremental polish.
- **Tests must stay green without `Git::Raw`** — it is not installed here, and the
  graceful-degrade path is a feature.

## Perl specifics — reference, don't restate

Module loading, Moo patterns, cpanfile pinning: skills `getty-perl-core`,
`getty-perl-moo`. `[@Author::GETTY]` bundle, POD, `{{$NEXT}}`: skill
`getty-perl-release-author-getty`. dist.ini mechanics: `perl-release-dist-ini`. MCP
server setup: `perl-mcp`. Commits: only `mcp-wiki-release-manager` commits (it carries `getty-git-commit-style`). Don't duplicate.
