# mcp-wiki as standalone binaries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mcp-wiki declares one binary, `mcp-wiki`, with Git::Raw inside; its scripts
prove the binary on the build machine and on clean machines; users install it with one
line.

**Architecture:** mcp-wiki is the first consumer of the bundle's binary release form
(bundle plan `2026-11-03-binary-bundle.md`). This repo supplies only what is
mcp-wiki-specific: the `binary*` keys in `dist.ini`, the caller workflow, three scripts
(prepare: Git::Raw build fixes; verify: build leg with perl and git; smoke: clean
machine without either), the README section, the agent that owns this lane, and k60.

**Tech Stack:** Perl 5.40, Moo, Git::Raw 0.90, bash (verify, prepare), POSIX sh (smoke),
GitHub Actions caller workflow.

**Spec:** `docs/superpowers/specs/2026-11-03-binary-release-design.md` — read it first,
including "Amendments after approval". Reference: `~/dev/mcp-wiki-binary-spike` (commit
3eef0a1): `smoke/requests.jsonl`, `smoke/check.pl`, `build/hide-ssl.sh`, `build/build.sh`.

**Order across plans:** bundle Tasks 1–6 → this plan's Tasks 1–6 → bundle Task 7
(end-to-end, with mcp-wiki as the test dist) → maintainer's go for `binary-v1` and the
bundle's CPAN release → this plan's Task 7.

**Lanes:** agent setup → main agent; k60 code, scripts, `dist.ini`, workflow, README
section → `mcp-wiki-binary-worker` once Task 1 exists (k60 → `mcp-wiki-worker`); tests →
`mcp-wiki-test-writer`; commits, `Changes`, cards → `mcp-wiki-release-manager`.

## Global Constraints

- Binary name `mcp-wiki`; assets `mcp-wiki-<version>-<platform>[.exe]` for `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64`.
- Git::Raw is required in the binary: a leg without it fails, never ships the degrade path.
- Nothing on stdout except JSON-RPC.
- No change to runtime behaviour, tool surface or `heading_path` (k60 changes only a warning's wording).
- The suite stays green with and without Git::Raw (`PERL5OPT=-MTest::Without::Module=Git::Raw prove -lr t/`).
- Write tools only against tempdirs, never the checkout or `$HOME`.
- Until the bundle is released, build with the development bundle: `PERL5LIB=$HOME/dev/p5-dist-zilla-pluginbundle-author-getty/lib:$PERL5LIB`. Never install it over the maintainer's bundle.
- Pushes, tags, `dzil release`, public repos: maintainer's explicit go only.

## Review Focus

- **The hand-made repository in the smoke** (no git on the target): if libgit2 rejects the layout, every clean-machine cell fails for a reason unrelated to the binary. Pinned by `smoke_script_passes_against_perl` (Task 3), which runs the smoke against the Perl code with real Git::Raw.
- **Windows paths**: the binary gets a POSIX path from Git Bash and cannot open the wiki. Pinned in Task 3: verify converts with `cygpath -w` when present; exercised by the Windows leg in bundle Task 7.
- **The prepare script on the maintainer's machine** hides the host's OpenSSL headers. Pinned by `prepare_refuses_outside_ci` (Task 4).
- **Scripts missing from the tarball** (untracked or without the executable bit): the workflow cannot run them. Pinned by `binary_scripts_tracked_and_executable` and the tarball check (Task 5).
- **A degraded binary**: Git::Raw packed but failing to load prints "Git is not available" and runs on. Pinned by `verify_fails_on_degrade_warning` (Task 3).

---

### Task 1: The `mcp-wiki-binary-worker` agent

**Files:**
- Create: `.claude/agents/mcp-wiki-binary-worker.md`
- Modify: `.claude/skilletor.json` (via `skilletor install perl-par-binary-release@getty --project`)
- Modify: `.claude/rules/mcp-wiki-rules.md` (lane table + "Behavior-relevant" list), `CLAUDE.md` (delegation table)

Modelled on `~/dev/locale-simple/.claude/agents/locale-simple-binary-worker.md`.
Frontmatter: `model: inherit`; `briefing.skills`: `mcp-wiki-core`,
`perl-par-binary-release`, `getty-perl-release-author-getty`, `getty-perl-core`,
`kanban-issues-karr-ticket`. Body: lane = `scripts/binary-*`, the `binary*` keys in
`dist.ini`, `.github/workflows/binaries.yml`, the README install section; the binary
packs what `mcp-wiki-worker` writes (behaviour problems go as a card note to that
worker); names fixed as in Global Constraints; never commits, tags, pushes or releases;
never edits `lib/` or the shared skills. Ends the conventions paragraph with "The
conventions above are non-negotiable — apply silently, do not restate."

- [ ] **Step 1:** Install the skill, write the agent, add the lane rows: `| Standalone
  binary: scripts/binary-*, binary keys, binaries.yml, README install section |
  mcp-wiki-binary-worker |`.
- [ ] **Step 2:** Hook check from skill `getty-agent-team` Step 8 with
  `subagent_type: mcp-wiki-binary-worker` — `updatedInput.prompt` holds all five skill
  bodies and the marker.
- [ ] **Step 3:** Commit (release-manager). The agent is spawnable from the next session.

### Task 2: k60 — the Git warning without Perl's file and line

**Files:**
- Modify: `lib/MCP/Wiki/Server.pm:106`
- Test: `t/62-git-startup-warning.t`

- [ ] **Step 1: Extend the test** (test-writer): start the server on a tempdir that is no
  git repository, with `git => 1`; capture the warning.

```perl
is $warning,
  "Git is not available, the wiki is served without history and commits: Not a git repository: $root\n";
unlike $warning, qr/ at \S+ line \d+/;
```

- [ ] **Step 2:** `prove -lv t/62-git-startup-warning.t` — FAIL (the reason ends with
  " at …/History.pm line N.").
- [ ] **Step 3: Implement** (mcp-wiki-worker): strip the trailing location from `$reason`
  the way tool errors already are (comment near `Server.pm:387`).
- [ ] **Step 4:** `prove -lr t/` and the Git::Raw-less run — PASS.
- [ ] **Step 5:** Commit (release-manager), k60 → done.

### Task 3: Verify and smoke scripts

**Files:**
- Create: `scripts/binary-verify.sh` (bash; build leg — perl and git present)
- Create: `scripts/binary-smoke.sh` (POSIX sh; clean machine — no perl, no git)
- Test: `t/70-binary-scripts.t`

**Interfaces:**
- Both: `<script> <binary>`; exit 0 and a final `verify: OK` / `smoke: OK`, or exit 1
  with `FAIL: <reason>`. Both send the spike's session (`smoke/requests.jsonl`: initialize,
  `notifications/initialized`, `tools/list`, `create_page` "smoke.md" with reason
  "smoke: create page", `update_paragraph` `Intro#Alpha` with reason "smoke: update
  Alpha", `get_section_history` `Intro#Alpha`) to `<binary> --wiki-root <dir> --git`.
- Verify: `git init` a temp wiki; fresh `PAR_GLOBAL_TMPDIR` in the temp dir for a cold
  first start, then a second (warm) start on the same cache; checks with perl
  (`JSON::PP`): every stdout line is JSON-RPC 2.0, every id answered without `error`,
  exactly 15 tools, no `isError`, the history lists both reasons, `git log --format=%s`
  shows both, stderr has no "Git is not available". Paths go through `cygpath -w` when
  that exists (Windows).
- Smoke: lays out the repository by hand — `.git/HEAD` (`ref: refs/heads/main`),
  `.git/objects/`, `.git/refs/heads/`, `.git/config` (`[core]`,
  `repositoryformatversion = 0`, `bare = false`); checks with `grep`: no `"error"`, no
  `"isError":true`, 15 tool names in the `tools/list` answer, both reasons in the
  history answer, stderr has no "Git is not available".

- [ ] **Step 1: Write the failing test** (test-writer). It writes a wrapper "binary"
  into a tempdir — `#!/bin/sh` + `exec <$^X> -I<abs lib> <abs bin/mcp-wiki> "$@"` — and
  runs both scripts against it. `plan skip_all` without Git::Raw.

```perl
# verify_script_passes_against_perl
is system('bash', 'scripts/binary-verify.sh', $wrapper), 0;
# smoke_script_passes_against_perl
is system('sh', 'scripts/binary-smoke.sh', $wrapper), 0;
# verify_fails_on_degrade_warning: a wrapper that prints the warning to stderr first
isnt system('bash', 'scripts/binary-verify.sh', $degraded), 0;
# smoke_fails_on_wrong_tool_count: a wrapper that answers tools/list with 14 tools
isnt system('sh', 'scripts/binary-smoke.sh', $short), 0;
```

- [ ] **Step 2:** `prove -lv t/70-binary-scripts.t` — FAIL (scripts missing).
- [ ] **Step 3: Implement** both scripts (mcp-wiki-binary-worker); `git add`, then
  `git update-index --chmod=+x scripts/binary-verify.sh scripts/binary-smoke.sh`.
- [ ] **Step 4:** `prove -lr t/` — PASS; the Git::Raw-less run skips the file;
  `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.10.0 /mnt/scripts/binary-verify.sh /mnt/scripts/binary-smoke.sh` clean.
- [ ] **Step 5:** Commit (release-manager).

### Task 4: Prepare script — Git::Raw's build fixes

**Files:**
- Create: `scripts/binary-prepare.sh` (bash)
- Test: `t/70-binary-scripts.t` (one more case)

Runs once per leg before the deps install, with the packing perl on `PATH`, the deps
local lib active and a per-leg cache directory as its only argument (bundle plan, Global
Constraints). Ports the spike: hide the OpenSSL/libssh2 headers Git::Raw's probe would find (Linux: the
container's, if any; macOS: Homebrew's under `/usr/local` — headers only; Windows:
Strawberry's `c/include`), on macOS patch `deps/libgit2/deps/zlib/zutil.h` in a fetched
`Git-Raw-0.90` (`s/^#if defined(MACOS) || defined(TARGET_OS_MAC)$/#if defined(MACOS)/`),
then `cpanm` Git::Raw from that directory (absolute path) into the active local lib so
`--installdeps` finds it installed. The fetched `Git-Raw-0.90` tarball is kept in the
cache directory and taken from there on the next run. Nothing is restored: runners are throwaway, which is why the script refuses
to run anywhere else.

- [ ] **Step 1: Write the failing test** (test-writer):

```perl
# prepare_refuses_outside_ci: GITHUB_ACTIONS unset
my $out = `env -u GITHUB_ACTIONS bash scripts/binary-prepare.sh 2>&1`;
isnt $? >> 8, 0;
like $out, qr/only on a CI runner/;
```

- [ ] **Step 2:** `prove -lv t/70-binary-scripts.t` — the new case FAILS (script missing).
- [ ] **Step 3: Implement** (mcp-wiki-binary-worker), tracked and executable as in Task 3.
- [ ] **Step 4:** `prove -lr t/` — PASS; shellcheck clean. The real proof is the five
  legs in bundle Task 7 (`lib-gate.pl` rejects a binary that links `libssl`/`libssh2`).
- [ ] **Step 5:** Commit (release-manager).

### Task 5: Declare the binary — `dist.ini`, caller workflow, CI

**Files:**
- Modify: `dist.ini`
- Create: `.github/workflows/binaries.yml`
- Modify: `.github/workflows/ci.yml` (`DZIL_BINARY_SKIP: 1` beside `DZIL_DOCKER_API_SKIP: 1`)
- Test: `t/09-binary.t` (modelled on `t/08-docker.t`)

`dist.ini`, in `[@Author::GETTY]`:

```ini
binary = mcp-wiki
binary_modules = MCP::Wiki::Git::History Git::Raw
binary_require = Git::Raw MCP::Wiki::Git::History
binary_prepare = scripts/binary-prepare.sh
binary_verify = scripts/binary-verify.sh
binary_smoke = scripts/binary-smoke.sh
```

`.github/workflows/binaries.yml`: the caller from bundle plan Task 6, verbatim.

- [ ] **Step 1: Write the failing test** (test-writer):

```perl
# dist_ini_declares_binary: the six lines above, exact values
# caller_workflow_pinned:   binaries.yml contains
#   'uses: Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@binary-v1'
#   and 'release:' with 'types: [published]'
# binary_scripts_tracked_and_executable:
#   `git ls-files -s scripts/binary-*.sh` -> three entries, each mode 100755
# ci_skips_local_binary: ci.yml sets DZIL_BINARY_SKIP: 1
```

- [ ] **Step 2:** `prove -lv t/09-binary.t` — FAIL.
- [ ] **Step 3: Implement** (mcp-wiki-binary-worker).
- [ ] **Step 4:** `prove -lr t/` — PASS. Then the tarball check with the development
  bundle: `PERL5LIB=$HOME/dev/p5-dist-zilla-pluginbundle-author-getty/lib:$PERL5LIB DZIL_DOCKER_API_SKIP=1 dzil build`
  — the local binary check runs (pp, verify, smoke against `MCP-Wiki-<v>-binaries/mcp-wiki`)
  and passes; `tar tzf MCP-Wiki-*.tar.gz | grep -c 'scripts/binary-'` prints `3`; the
  built `META.json` `x_binaries` equals the shape in bundle plan Task 2 with the values
  above (no `pp_args`).
- [ ] **Step 5:** Commit (release-manager).

### Task 6: README — "Install the binary"

**Files:**
- Modify: `README.md` (a section before "Install with Docker")

Content: the one-liners
`curl -fsSL https://github.com/Getty/p5-mcp-wiki/releases/latest/download/install.sh | sh`
and `irm https://github.com/Getty/p5-mcp-wiki/releases/latest/download/install.ps1 | iex`;
`MCP_WIKI_VERSION` and `MCP_WIKI_INSTALL_DIR`; the direct download with the
`SHA256SUMS` check (`sha256sum -c`, macOS `shasum -a 256 -c`) and `chmod +x`; Linux
needs glibc 2.28 or newer, Alpine and older systems use the Docker image; macOS after a
browser download: `xattr -d com.apple.quarantine mcp-wiki`; an MCP client entry using
the installed path with `--wiki-root` and `--git`; the first start unpacks ~20–30 MB
into the temp dir (`PAR_GLOBAL_TMPDIR` moves it, to an existing directory only — PAR ignores a missing one silently); after a direct download, run
`mcp-wiki --help` once before an MCP client starts several servers (k19 on the bundle
board — the install scripts do this themselves).

- [ ] **Step 1** (mcp-wiki-binary-worker): write the section; `prove -lv
  t/06-readme-tools.t` still PASS (tool table untouched).
- [ ] **Step 2:** Commit (release-manager).

### Task 7: First real run — maintainer's go

Prerequisites: bundle Task 7 green, `binary-v1` pushed, the bundle released to CPAN with
the binary form, this repo's `Changes` names the binaries.

- [ ] **Step 1** (release-manager): pre-release audit, including `dzil build` with the
  released bundle and the checks of Task 5 Step 4.
- [ ] **Step 2** (maintainer): `dzil release`.
- [ ] **Step 3:** Watch the `binaries` run once it finishes (no poll loop): expected 5
  legs, 7 smoke cells, publish green, release marked latest with 5 binaries,
  `SHA256SUMS`, `install.sh`, `install.ps1`. A red run: fix, then a full re-run by
  `workflow_dispatch` with the tag; a binary found broken after publishing means a new
  CPAN version.
- [ ] **Step 4:** Install with the one-liner on this machine into a temp dir
  (`MCP_WIKI_INSTALL_DIR`), run `scripts/binary-verify.sh` against it — `verify: OK`.
