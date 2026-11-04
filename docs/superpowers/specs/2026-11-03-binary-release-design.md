# Standalone binaries as a release form — design

Date: 2026-11-03 · Status: approved by the maintainer 2026-11-03, amended the same day
after approval — see "Amendments after approval" (prior art, second consumer). Every
amendment is Claude's call unless it says it is the maintainer's.

## Intent

A user who wants mcp-wiki as an MCP server on their machine — registered in Claude
Desktop, Claude Code or any other MCP client — should not have to install Docker or set
up a Perl environment. They download **one file for their OS**, make it executable and
run `mcp-wiki --wiki-root ~/wiki`. That is the third distribution form next to CPAN and
the Docker image `raudssus/mcp-wiki`.

It is built as a **release form of `[@Author::GETTY]`**, the same way Docker already is
(`docker_image = …`): one line in `dist.ini` and every Getty distribution with a command
line script can ship binaries. mcp-wiki is the first consumer. A dedicated agent owns
the binary build, because the knowledge it needs (per-OS packing, XS pitfalls, runner
image lifecycle) is specialised and keeps changing.

## Goals

- Per-OS binaries on every release, each with `Git::Raw` so the history tools work:
  `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64.exe`.
- Built and attached **automatically** after `dzil release`; no manual step per
  platform. Downloadable from the GitHub Release page of the dist's repository.
- **Install one-liner as the main install path** (maintainer's decision):
  `curl -fsSL https://github.com/<owner>/<repo>/releases/latest/download/install.sh | sh`
  — detects OS and architecture, downloads the matching binary, verifies it against
  `SHA256SUMS`, installs it into the `PATH`. A `curl` download carries no macOS
  quarantine flag, so this path most likely avoids the Gatekeeper block an unsigned
  binary gets after a browser download (unverified: no Mac available).
- `dist.ini` declares the form, symmetric to Docker: `binary = mcp-wiki`. **A dist can
  ship several binaries** (maintainer's requirement) — how many and which depends on
  the dist.
- `dzil build` also builds a binary for the maintainer's own machine as a local check,
  the way it builds the Docker image today (maintainer agreed); skippable by an
  environment variable like `DZIL_DOCKER_API_SKIP`.
- A dedicated binary-build agent (see "The agent").

## Non-goals

- Code signing and notarisation (Apple Developer ID, Windows Authenticode). The spike
  showed `codesign` cannot strictly sign a PAR binary; revisit only with a different
  packer.
- musl/Alpine binaries and glibc older than the Linux build base's (2.28, AlmaLinux 8).
  The Docker image covers those users.
- Native Windows-on-Arm builds (the x64 binary runs there emulated).
- Reproducible builds, package managers (Homebrew tap, winget, scoop, apt).
- Building every platform locally or cross-compiling.
- Any change to mcp-wiki's runtime behaviour, tool surface or `heading_path`.

## Anti-goals — failures even if it "works"

- A binary that links a non-system library. It passes on the runner and breaks on the
  user's machine (the spike's Intel-macOS leg silently linked Homebrew's OpenSSL).
- A release whose asset set looks complete but is not: some legs missing, a
  `SHA256SUMS` that does not cover what is attached, or a binary that quietly lacks
  `Git::Raw` and runs in the degrade path.
- Anything on stdout besides JSON-RPC — it breaks every MCP client.
- A release flow that needs the maintainer to do something per platform.
- Any change in behaviour for dists that declare no binaries — apart from the k17 fix
  (tarball uploaded before publishing, a failed upload fails loudly), which every
  GitHub-hosted dist gets.
- Secrets in public logs or assets.

## Facts and constraints (spike of 2026-11-03)

Validated end to end in a throwaway public repo (deleted afterwards). The reference
implementation — workflow, build, inspect and smoke scripts with full history — is kept
locally at `~/dev/mcp-wiki-binary-spike` (commit 3eef0a1). Results:

| Leg | Runner | Size | Start cold/warm | Verified on |
|---|---|---|---|---|
| linux-x86_64 | `ubuntu-24.04` + `perl:5.40-bullseye` container | 9.9 MB | 0.9/0.3 s | Ubuntu 20.04, 26.04, Debian 11, Rocky 9, Fedora |
| linux-arm64 | `ubuntu-24.04-arm` + same container | 9.8 MB | 0.8/0.3 s | same |
| macos-arm64 | `macos-15`, deployment target 12.0 | 9.5 MB | 0.6/0.2 s | macOS 15, 26 |
| macos-x86_64 | `macos-15-intel`, deployment target 12.0 | 9.2 MB | 1.4/0.4 s | macOS 15/26 Intel, Rosetta |
| windows-x86_64 | `windows-2025`, Strawberry Perl 5.40 | 15 MB | 3.9/0.5 s | Server 2022/2025, Win-on-Arm (emulated) |

What the build has to do, learned the hard way:

- **Own packing perl per OS.** Linux: built inside a bullseye container without crypt
  (`-Ud_crypt -Ud_crypt_r -Ui_crypt`, `-Duseshrplib`) — the stock Debian libperl needs
  `libcrypt.so.1`, missing on Rocky 9/Fedora. macOS: built with
  `MACOSX_DEPLOYMENT_TARGET=12.0`; a cached build needs `install_name_tool` relinking of
  `libperl.dylib` and an ad-hoc re-sign. Windows: Strawberry, put ahead of Git Bash's
  MSYS perl in `PATH`.
- **Git::Raw 0.90 (libgit2 1.5.0, zlib 1.2.12) needs help.** macOS (Xcode 16+ SDK): patch
  the bundled `zutil.h` (`fdopen` macro), as zlib 1.3.1 does. Windows: hide Strawberry's
  OpenSSL/libssh2 headers, else libgit2 fails to compile. macOS Intel: hide Homebrew's
  OpenSSL/libssh2 *headers* (not the prefixes — that breaks Homebrew's curl), else the
  binary links `/usr/local/opt/...`.
- **pp misses runtime `require`s**: `-M MCP::Wiki::Git::History -M Git::Raw`.
- `cpanm --installdeps .` must run from inside the dist (cpanm takes an argument as a
  directory only when it starts with `.` or `/`; Git Bash rewrites `/d/a/...`).
- **Release race:** `GitHub::CreateRelease` publishes the release, then uploads the
  tarball; the `release: published` workflow starts first. Spike workaround: retry the
  download (30 × 10 s). Proper fix: draft → upload → publish (bundle card k17).
- **Checksums only from complete runs** — a partial re-run overwrote `SHA256SUMS`.
- A release created with the workflow's own `GITHUB_TOKEN` would not trigger workflows;
  `dzil release` uses the maintainer's personal token, which does (verified).
- PAR extracts ~20–30 MB per version into `$TMPDIR/par-<user>/cache-<sha1>` (`%TEMP%` on
  Windows) on first start and never cleans up. `PAR_GLOBAL_TMPDIR` moves it.
- The Windows binary carries Strawberry's preinstalled Net::SSLeay/Crypt::SSLeay/CryptX
  as dead weight (most of the 15 MB).
- Linux glibc floor is 2.29: Debian 10 fails, Alpine (also with gcompat) fails.
- Runner images (checked 2026-11-03): macOS 14 retired 2026-11-02, macOS 13 in Dec 2025.
  arm64 labels: `macos-15`, `macos-26` (= `macos-latest`). Intel: `macos-15-intel`,
  `macos-26-intel`. GitHub announced the end of Intel on macOS with the retirement of the
  macOS 15 image in fall 2027; `macos-26-intel` appeared later and no new end date was
  found. Linux/Windows arm64 standard runners exist for public and private repos.
  Public repos run standard runners for free.
- Publish gate: `dzil release` stays the maintainer's explicit go. The binary workflow
  only runs on `release: published` and on manual `workflow_dispatch` for re-runs.

## Amendments after approval (2026-11-03)

Found while planning, after the maintainer approved the draft:

- **Prior art.** Four dists already ship PAR binaries, each with its own
  `release-binaries.yml` and `scripts/`: karr, langertha-knarr, langertha-raider (Linux
  only, `perl:5.40-bookworm`) and locale-simple (Linux plus `macos-14`, broken since that
  image retired on 2026-11-02). Their recipe is the shared skill `perl-par-binary-release`
  (Getty/skills); locale-simple also has an agent `locale-simple-binary-worker`. The
  recipe is stricter than the spike in several places, and this design takes those over.
  The spike is ahead in others: its own no-crypt perl (no `libcrypt.so.1` needed on the
  target), Windows, macOS Intel, Git::Raw. Migrating the four dists to the bundle form is
  not part of this project.
- **Second consumer.** p5-mcp-hub (its k28, k36) packs mcp-hub against this draft and
  filed its needs on the bundle board as k18, plus a PAR bug as k19. Maintainer decisions
  recorded there on 2026-11-03: the ARM Linux asset is `linux-arm64` for all dists, and
  mcp-hub's binary gets TLS with a statically linked OpenSSL (details follow from its
  k36). mcp-hub needs ~30 modules pp cannot see, computed by a dist command rather than
  listed in `dist.ini`; `-X` families; `-a` for an installed dist's data files;
  `PAR_VERBATIM=1`; a verify hook on the build leg; a smoke without perl; required
  modules with namespace globs; and no Windows leg.
- **k19:** when several processes start a PAR binary on a cold cache at once, 1–2 of 3
  crash (segfault or "did not return a true value"); a warm cache is fine. MCP clients
  often start servers in parallel.

What changes in the design below:

1. The shared skill is the existing `perl-par-binary-release`, updated — no new
   `perl-binary-release`. The bundle keys are documented with the bundle's other
   options, in skill `getty-perl-release-author-getty`.
2. The CI side is a **reusable workflow** in the bundle repo
   (`.github/workflows/dzil-binary.yml`, `on: workflow_call`), not a composite action
   the dist calls per leg. It reads the platforms from the dist and builds its own
   matrix, so the dist's `binaries.yml` is a short caller with nothing dist-specific,
   and the publish job knows the complete expected set.
3. The bundle resolves the binary config from `dist.ini` into `META.json` under
   `x_binaries`; the workflow reads it from the release tarball. One resolved source and
   no second `dist.ini` parser.
4. More keys, for mcp-hub: `binary_pp_args` (a command printing extra `pp` arguments),
   `binary_verify` (a check on the build leg, with perl), `binary_platforms` (a subset of
   the five). `binary_require` takes `Name::*` globs and is checked inside the packed
   archive, never against the host's `@INC` (from the recipe). `PAR_VERBATIM=1` on every
   build.
5. Two checks with separate contracts: `binary_verify` on the build leg (perl, unzip and
   git there), `binary_smoke` on clean machines without perl (from the recipe).
6. The library gate reads every shared object inside the unzipped binary, not only the
   ones a session happened to load (from the recipe).
7. Workflow hygiene from the recipe: read-only token except in the publish job,
   `persist-credentials: false`, tag values reach a shell only through `env`, one
   concurrency group per tag, a timeout on every job, a tag/version match check, and a
   **probe run** (dispatch without a tag: build and check, keep workflow artifacts, touch
   no release).
8. `install.sh`/`install.ps1` start each installed binary once to fill the PAR cache
   (k19).
9. The agent is `<prefix>-binary-worker`, the name the existing ones use.
10. Not taken from the recipe: per-platform `.tar.gz` assets and the
    `<name>-<version>-checksums.txt` name. The install scripts are the main path and set
    the executable bit; the release carries raw binaries and one `SHA256SUMS`.
11. After mcp-hub's TLS report (its k36, on bundle k18): `binary_prepare` gets a per-leg
    cache directory that survives runs (mcp-hub's static OpenSSL takes ~6 min uncached)
    and runs with the deps local lib already active, so what it installs with `cpanm`
    lands where the deps install and `pp` look; `MACOSX_DEPLOYMENT_TARGET` holds for the
    whole leg, not only the perl build.

## Design — decided

### Release flow

1. `dzil release` as today: CPAN upload, Docker push, tag, GitHub Release with the CPAN
   tarball. With `binary` set, the release is created **published but not "latest"**
   (`make_latest=false`), tarball uploaded before publishing (k17). It must stay
   published: GitHub starts no workflows for draft releases.
2. `release: published` starts `.github/workflows/binaries.yml` in the dist's repo — a
   short caller of the bundle's reusable workflow
   `Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@<own tag>`.
   Its first job fetches the CPAN tarball from the release (with retry) and reads
   `x_binaries` from the tarball's `META.json`; that decides the legs.
3. Each leg builds every binary the dist declares, sharing one packing perl and one
   deps install: packing perl (cached) → `binary_prepare <cache dir>` → deps into a cached local lib
   → `PAR_VERBATIM=1 pp` per binary (`binary_modules` as `-M`, plus every line
   `binary_pp_args` prints) → **library gate** (unzip the binary; the loader and every
   shared object inside may link only an explicit allowlist of system libraries per OS;
   on Linux the highest `GLIBC_x` symbol version must not exceed the floor the README
   promises) → **required-module gate** (every `binary_require` module, globs expanded,
   is inside the archive) → `binary_verify` → upload as workflow artifact.
4. Smoke job, blocking: every binary runs `binary_smoke` on machines that never built it
   and carry no perl — Linux in clean containers (`almalinux:8` for the glibc floor,
   `almalinux:9` without `libcrypt.so.1`, one Debian-family image; arm64:
   `almalinux:9`), macOS on the other runner generation, Windows on `windows-2022`. The
   job asserts that no build perl is present.
5. Publish job (needs all legs and the smoke job; not in a probe run): only when everything is green,
   attach every binary of every leg, one `SHA256SUMS` over all of them, `install.sh`
   and `install.ps1`, then mark the release **latest**. So `releases/latest/download/install.sh` always points at a
   release with a complete, verified set; during the build and after a red leg it keeps
   serving the previous one.
6. Recovery: a red run is fixed by a full new run via `workflow_dispatch` (all legs,
   ~13 job-minutes with warm caches), which again publishes only when all is green. A
   complete published set is never replaced; a binary found broken later means a new
   CPAN version.
7. Asset names, per binary: `<name>-<version>-<os>-<arch>[.exe]`, e.g.
   `mcp-wiki-0.003-linux-x86_64`. `install.sh` downloads with `curl -f` and exits
   non-zero on any failure.

### Bundle side (`p5-dist-zilla-pluginbundle-author-getty`)

- **Binaries are declared in `dist.ini`, modelled on the Docker form**; the bundle
  resolves them into `META.json` (`x_binaries`), which the local check and the workflow
  both read. **A dist can have several binaries** (maintainer's requirement):
  - Simple form in `[@Author::GETTY]`: `binary = <name>` packs `bin/<name>`,
    repeatable (`binary = foo`, `binary = bar`), all sharing the defaults below.
  - Per-binary defaults in the style of `docker_tags` & co.:
    - `binary_modules` — extra `-M` modules for `pp` (runtime `require`s)
    - `binary_pp_args` — a command whose output lines are appended to the `pp` call
      (computed `-M`, `-X`, `-a`; mcp-hub's `loaded-modules.pl`)
    - `binary_require` — modules that must be inside the archive (`Name::*` globs)
    - `binary_verify` — a command run on the build leg; gets the binary's path
    - `binary_smoke` — a command run on clean machines; gets the binary's path
  - Dist-wide: `binary_platforms` (default: all five) and `binary_prepare` — a command
    run once per leg before the deps install (dependency patches, mcp-hub's static
    OpenSSL), with the deps local lib active and a per-leg cache directory as its
    argument.
  - Per-binary subsections, like `[@Author::GETTY::Docker / name]`:
    `[@Author::GETTY::Binary / <name>]` with `script` (default `bin/<name>`),
    `modules`, `pp_args`, `require`, `verify`, `smoke`, each inherited from the
    `binary_*` defaults unless given. `binary_default = 0` suppresses the auto-default
    built from `binary =`, like `docker_default`.
  - Every command runs from the root of the unpacked dist tarball, so the scripts it
    names must be tracked and shipped.

  A dist without runtime-loaded modules needs one line per binary; mcp-wiki needs a
  handful.
  - On `dzil build`: pack every declared binary for the local machine with the local
    perl and run its verify and smoke commands; output goes next to the build
    directory, never into the dist. Skip with `DZIL_BINARY_SKIP=1` (CI sets it, like
    `DZIL_DOCKER_API_SKIP`). The library gate is not part of the local check: a local
    perl links the host's libraries.
  - On `dzil release`: before anything is uploaded, fail if the repo has no
    `.github/workflows/binaries.yml` calling `dzil-binary.yml` — a dist must never be
    released declaring binaries it cannot build.
  - Without binaries declared: no change (the k17 fix aside).
- **Reusable workflow `dzil-binary.yml`** (own tag, see below) with its scripts in the
  bundle repo: the generic mechanics from the spike and the recipe — tarball fetch with
  retry, the matrix from `x_binaries`, packing perl per OS, cached deps, `pp` per
  binary, the gates, the verify and smoke hooks, asset naming, checksums, install
  scripts, publishing. The per-dist knowledge comes from `x_binaries`, not from workflow
  inputs. Git::Raw's build fixes (header hiding, `zutil.h`) are mcp-wiki's
  `binary_prepare`, not the workflow's.
- **`install.sh` / `install.ps1`**: generic, parameterised with owner, repo and the
  dist's binary names, attached to every release. Without arguments they install every
  binary of the dist; `… | sh -s -- <name> …` installs a selection. `install.sh` resolves the latest tag through the
  `releases/latest` redirect (no API token, no rate limit), downloads the versioned
  asset and `SHA256SUMS`, verifies, installs to `~/.local/bin` (overridable), and says
  so if that directory is not in `PATH`. A version can be pinned by environment
  variable. `install.ps1` is the same for Windows
  (`irm https://github.com/<owner>/<repo>/releases/latest/download/install.ps1 | iex`).
  After installing, each script starts every installed binary once (`--help`, stdin
  from the null device, output discarded, exit status ignored) so the PAR cache is warm
  before an MCP client starts several at once (k19). A platform the dist does not build
  fails with a message naming the ones it does.
- **k17**: upload the tarball before publishing, create the release with
  `make_latest=false` when `binary` is set, and a failed upload fails the release
  loudly. `GitHub::CreateRelease` (TIMLEGGE's plugin) has `draft` but neither
  `make_latest` nor a publish step. **Decided by the maintainer:** a subclass inside
  the bundle takes this over, and the bundle uses it in place of
  `GitHub::CreateRelease` (the builder names it, e.g.
  `Dist::Zilla::Plugin::Author::GETTY::GitHubRelease`). An upstream PR is not part of
  this project — it would be a public write needing its own go.
- **Own tag for the action** (e.g. `binary-v1`), never moving `v1`: 94 workflow files
  under `~/dev` pin `dzil-test@v1`, which lags `main` by 61 commits — moving it would
  change CI everywhere at once. Every tag push needs the maintainer's go.
- **Linux build base**: not on Debian bullseye (out of support since 2026-08-31).
  `almalinux:8` (glibc 2.28, supported until 2029) — mcp-hub's rehearsal built the
  no-crypt perl there and measured floor 2.28; it keeps the floor low and covers Debian
  10 and RHEL 8. Fallback Debian bookworm (floor around 2.34, drops only distros already
  out of support). Pinned by digest. The README promises the floor the library gate
  measures.
- POD for the option and the action, like the Docker section.

### mcp-wiki side

- `dist.ini`: `binary = mcp-wiki`, `binary_modules = MCP::Wiki::Git::History Git::Raw`,
  `binary_require = Git::Raw MCP::Wiki::Git::History`, `binary_verify`, `binary_smoke`,
  `binary_prepare` (Git::Raw's build fixes per OS, installing Git::Raw before the deps
  install).
- `.github/workflows/binaries.yml`: the short caller of `dzil-binary.yml`.
- Verify (build leg; perl and git present): the spike's stdio session in `--git` mode
  against a fresh `git init` repo — initialize, `tools/list` (exactly 15),
  `create_page`, `update_paragraph`, `get_section_history` — then `git log` shows both
  commits and stdout is JSON-RPC only.
- Smoke (clean machine; no perl, no git): the same session in POSIX sh against a
  repository laid out by hand (`.git/HEAD`, `objects/`, `refs/heads/`, `config`);
  `get_section_history` must list both commits, which proves Git::Raw writes on the
  target. Checks by `grep`.
- Both scripts live in `scripts/`, tracked so the tarball ships them — not under `t/`
  (they test a binary, not the dist).
- README: "Install" section — one-liner (Linux/macOS, Windows), direct download, the
  glibc floor the gate measures (2.28 with the AlmaLinux 8 base), Docker for
  Alpine/older distros, and the macOS fallback for a browser download
  (`xattr -d com.apple.quarantine mcp-wiki`).
- k60 (the "Git is not available" warning shows Perl's file and line — in a binary the
  PAR temp path) becomes visible to binary users; fix it before the first binary release.

### The agent

The maintainer asked for an agent that owns binary generation. Following the house
pattern (knowledge in skills, agents are roles):

- **Shared skill** in Getty/skills: the existing `perl-par-binary-release`, updated —
  the bundle form as the path for `[@Author::GETTY]` dists, the per-dist recipe kept for
  the others; the packing perl per OS, XS/Git::Raw pitfalls, the gates, the k19 race,
  current runner labels and how to check them. The `binary_*` keys go into
  `getty-perl-release-author-getty`. Installed with skilletor where needed.
- **Role** `<prefix>-binary-worker` (the name locale-simple and mcp-hub already use):
  owns the binary's scripts, the `binary_*` keys, `binaries.yml`, dependency patches,
  diagnosing failed legs. Leaves a commit-ready tree; never commits (release-manager),
  never releases, never pushes.
- **mcp-wiki**: `.claude/agents/mcp-wiki-binary-worker.md`, briefed with
  `perl-par-binary-release`, `getty-perl-release-author-getty`, `mcp-wiki-core`,
  `getty-perl-core`, `kanban-issues-karr-ticket`; a row in the lane tables of
  `.claude/rules/mcp-wiki-rules.md` and `CLAUDE.md`.
- **Bundle repo**: the action and the option are worked by that repo's own team, briefed
  with the same skill; work there goes through that repo's karr board.

### Order of work

1. Skills: `perl-par-binary-release` and `getty-perl-release-author-getty` (Getty/skills)
   — the agents need them before they exist.
2. Bundle repo: k17, the `binary*` options and `x_binaries`, `dzil-binary.yml` + install
   scripts (ported from the spike and the recipe), POD. Validated in a throwaway public
   repo the same way as the spike before the workflow gets its own tag (maintainer's go
   for the tag push).
3. mcp-wiki: agent + lane tables, `dist.ini` keys, caller workflow, verify and smoke
   scripts, README, k60.
4. First real run with the next mcp-wiki release — on the maintainer's go.

## Left to the builder

- File layout of the workflow's scripts in the bundle repo; how a probe run gets its
  tarball.
- Cache keys; the exact Perl 5.40.x pin.
- Trimming the Windows dead weight.
- How `x_binaries` is assembled from several plugin instances (the shape is fixed in the
  bundle plan).

## Calls made by Claude, not by the maintainer

- Pinned runner labels (`ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-15`,
  `macos-15-intel`, `windows-2025`) instead of `-latest`, so image migrations never
  change binaries silently; the agent bumps them.
- All-or-nothing publishing (no partial asset sets).
- `Git::Raw` is required in mcp-wiki's binaries: a leg without it fails instead of
  shipping the degrade path.
- `install.ps1` for Windows next to `install.sh`.
- The local binary on `dzil build` is a check, not a release artifact.
- Multiple binaries modelled on Docker's subsections; one packing perl and deps install
  per leg shared by all binaries of a dist; one `SHA256SUMS`; the install scripts
  install every binary unless given names.
- Agent as a per-repo file + shared skill, not yet a skilletor-shipped agent.
- `macos-x86_64` ships while Intel runners exist; dropping it is one matrix line.
- The release stays published but not "latest" until the binaries are complete; the
  publish job marks it latest.
- The whole binary config in `dist.ini` (`binary_*` keys), one source for the local
  check and CI.
- A blocking portability job per release, a library allowlist and a glibc-version
  check instead of a plain "non-system library" test.
- Recovery = full re-run; a complete published set is never replaced.
- Own tag for `dzil-binary`; `v1` stays where it is.
- Linux build base AlmaLinux 8 (fallback bookworm) instead of the unsupported bullseye.
- Everything listed under "Amendments after approval" — except the two maintainer
  decisions recorded in k18.

## Open risks

- Git::Raw/libgit2 breaks again with the next SDK or toolchain; the gates catch it, a
  person or the agent has to fix it.
- macOS Gatekeeper after a browser download and Windows SmartScreen/Defender: not
  verifiable without real machines; the one-liner is the mitigation.
- Intel macOS runners end (announced fall 2027).
- 9–15 MB binaries with a 0.6–4 s cold start; the PAR cache grows per version.
- k19: only the install scripts warm the cache. A user who downloads by hand and lets an
  MCP client start several servers at once can still hit the crash on the first start.
- mcp-hub's static OpenSSL (its k36, `scripts/build-binary-openssl.sh`) is verified on
  an AlmaLinux-8 rehearsal only; the arm64 and macOS legs, and `MACOSX_DEPLOYMENT_TARGET`
  reaching OpenSSL's compile, first meet reality in mcp-hub's own probe run.
