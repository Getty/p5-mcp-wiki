# Binary release form in [@Author::GETTY] — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `binary = <name>` in `[@Author::GETTY]` makes every release of a dist ship
verified standalone binaries for up to five platforms plus install scripts, attached
automatically after `dzil release`.

**Architecture:** The bundle resolves the `binary*` keys into `META.json` (`x_binaries`)
and packs a local check binary on `dzil build`. A subclass of `GitHub::CreateRelease`
creates the release as draft, uploads the tarball, then publishes it — not "latest" when
binaries are declared (k17). A reusable workflow `dzil-binary.yml` reads `x_binaries` from
the release tarball, builds and gates every binary per platform, smokes them on clean
machines and publishes the complete set, `SHA256SUMS` and the install scripts, then marks
the release latest.

**Tech Stack:** Perl 5.40, Moose (bundle), Dist::Zilla 6, PAR::Packer, Archive::Zip,
JSON::PP, GitHub Actions (reusable workflow), POSIX sh, PowerShell.

**Spec:** `/home/getty/dev/p5-mcp-wiki/docs/superpowers/specs/2026-11-03-binary-release-design.md`
— read it first, including "Amendments after approval". Reference implementation:
`~/dev/mcp-wiki-binary-spike` (commit 3eef0a1). Prior-art recipe: skill
`perl-par-binary-release` and `~/dev/locale-simple/.github/workflows/release-binaries.yml`.

**Repo:** `~/dev/p5-dist-zilla-pluginbundle-author-getty`. Lanes: tests →
`dist-zilla-pluginbundle-author-getty-test-writer`; code, workflow, scripts, POD →
`dist-zilla-pluginbundle-author-getty-worker`; commits and `Changes` →
`dist-zilla-pluginbundle-author-getty-release-manager`. Board: this repo's karr (k17,
k18, k19 and the umbrella card for this plan). k17 → Task 1; k18 → Tasks 2–6; k19 →
Task 5 and Task 7 Step 5.

## Global Constraints

- Platforms, in this order: `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-x86_64`, `windows-x86_64`.
- Asset name: `<name>-<version>-<platform>`, plus `.exe` on `windows-x86_64`. One `SHA256SUMS`, one `install.sh`, one `install.ps1` per release.
- Build runners, pinned: `ubuntu-24.04` (+ container `almalinux:8` pinned by digest), `ubuntu-24.04-arm` (same container), `macos-15`, `macos-15-intel`, `windows-2025`.
- Smoke cells: linux-x86_64 → `almalinux:8`, `almalinux:9`, `debian:bookworm-slim`; linux-arm64 → `almalinux:9`; macos-arm64 → `macos-26`; macos-x86_64 → `macos-26-intel`; windows-x86_64 → `windows-2022`.
- Packing perl: 5.40.x built per leg, `cpanm` in its `bin`. Linux: `-Ud_crypt -Ud_crypt_r -Ui_crypt -Duseshrplib`; macOS: `MACOSX_DEPLOYMENT_TARGET=12.0`, exported for the whole leg (perl build, `prepare`, deps, `pp`) so a dist's own C builds honour it (mcp-hub's static OpenSSL); Windows: Strawberry Perl 5.40, ahead of Git Bash's perl in `PATH`.
- Build-leg tools a `prepare` or `verify` may rely on: `curl`, a C compiler, `make`, `tar`, `patch`, `unzip`, `git` (Linux: `dnf install` in the container — `almalinux:8` ships none of `git`, `perl`, `unzip`; macOS: the runner image; Windows: Strawberry's `gcc`/`gmake`, Git Bash's tools). mcp-wiki's verify needs `git` for its history check.
- `prepare` sees `GITHUB_ACTIONS=true` (a job `container:` passes it; a bare `docker run` would need `-e GITHUB_ACTIONS`): a dist's prepare may refuse to run anywhere else, as mcp-wiki's does. The local check on `dzil build` (Task 3) never runs `prepare`.
- Every `pp` call runs with `PAR_VERBATIM=1`.
- Linux glibc floor: the highest `GLIBC_x.y` in any packed object must be ≤ `2.28`.
- `DZIL_BINARY_SKIP=1` skips the local build; CI sets it.
- Own tag `binary-v1` for the workflow; `v1` never moves. Pushing any tag, any push, `dzil release`, a CPAN upload: maintainer's explicit go only.
- Dists without `binary` keys: no change except k17 (draft → upload → publish, loud upload failure).
- Commands from `x_binaries` run from the root of the unpacked dist tarball; `verify` and `smoke` get the binary's absolute path appended as the last argument; `prepare` gets the absolute path of a per-leg cache directory appended (restored and saved by the workflow, key `prepare-<platform>-<prepare_key>`); `pp_args` gets no argument.
- `prepare` runs once per leg after the packing perl and before the deps install, with the packing perl's `bin` first on `PATH` and the deps local lib already active (`PERL5LIB`, `PERL_MM_OPT`, `PERL_MB_OPT`, `PERL_LOCAL_LIB_ROOT` and its `bin` on `PATH`, as local::lib sets them): what it installs with `cpanm` lands where `--installdeps` and `pp` look, never in the packing perl, whose cache stays clean. mcp-hub's `build-binary-openssl.sh` (its k36) relies on exactly this.

## Review Focus

- **Upstream drift of `GitHub::CreateRelease`**: a new upstream version renames or re-signs `_create_release`, and the subclass is silently bypassed, bringing the race back. Pinned by `parent_still_calls_create_release_with_six_args` (Task 1).
- **Arguments with spaces from `binary_pp_args`** (`-a "/opt/x y/res;lib/res"`): one output line is one argument, never word-split. Pinned by `pp_args_lines_are_single_arguments` (Task 3) and `argv_keeps_spaces` (Task 4).
- **Re-running the workflow for a release that already has binaries**: a complete or partial set is never replaced. Pinned by `refuses_when_any_asset_exists` (Task 5).
- **A dist that declares no Windows (mcp-hub)**: the matrix, the expected set and both install scripts know only the declared platforms; a Windows user gets a clear message. Pinned by `plan_subset_platforms` (Task 4), `expected_set_follows_platforms` (Task 5) and `unsupported_platform_names_built_ones` (Task 5).
- **A trial release (`prerelease`)** must not be marked latest by the publish job. Pinned by `prerelease_is_never_marked_latest` (Task 5).

---

### Task 0: Brief the bundle team for binary work

**Files:**
- Modify: `.claude/skilletor.json` (via skilletor)
- Modify: `.claude/agents/dist-zilla-pluginbundle-author-getty-worker.md` (`briefing.skills`)

The main agent of the bundle repo does this; it is team setup, not behavior code.

- [ ] **Step 1:** `skilletor install perl-par-binary-release@getty --project`, then add
  `perl-par-binary-release` to the worker's `briefing.skills`.
- [ ] **Step 2:** Prove the briefing resolves with the hook check from skill
  `getty-agent-team` (Step 8): the `updatedInput.prompt` contains the skill body.
- [ ] **Step 3:** Commit through the release-manager: `skilletor.json`, the agent file,
  `settings.json` if skilletor touched it.

### Task 1: k17 — `Author::GETTY::GitHubRelease`

**Files:**
- Create: `lib/Dist/Zilla/Plugin/Author/GETTY/GitHubRelease.pm`
- Modify: `lib/Dist/Zilla/PluginBundle/Author/GETTY.pm` (the `GitHub::CreateRelease` block in `configure`, ~line 1463)
- Test: `t/github_release.t`

**Interfaces:**
- Produces: package `Dist::Zilla::Plugin::Author::GETTY::GitHubRelease`, `extends 'Dist::Zilla::Plugin::GitHub::CreateRelease'`; attribute `make_latest` (ro, Bool, lazy; default false when any plugin in `$self->zilla->plugins` isa `Dist::Zilla::Plugin::Author::GETTY::Binary`, else true); overrides `_create_release($tag, $branch, $title, $notes, $filename, $cpan_tar)`.
- Consumes: nothing from other tasks (the `Binary` package name is fixed here, built in Task 2).

- [ ] **Step 1: Write the failing tests** (test-writer). Mock `Config::Identity::load_check`
  and `Pithub::Repos::Releases` (`create`, `assets->create`, `update`) with `local *…`;
  record calls in order.

```perl
# creates_as_draft_then_publishes
is_deeply [map { $_->[0] } @calls], [qw(create asset update)];
is ${ $calls[0][1]{data}{draft} }, 1;
is $calls[1][1]{name}, 'Foo-1.0.tar.gz';
is_deeply $calls[2][1]{data}, { draft => \0, make_latest => 'true' };

# failed_upload_dies_and_never_publishes   (asset code 422)
like $@, qr/could not attach Foo-1\.0\.tar\.gz.*draft release left in place/s;
ok !grep { $_->[0] eq 'update' } @calls;

# failed_publish_dies                     (update code 500)
like $@, qr/could not publish the GitHub release/;

# parent_still_calls_create_release_with_six_args
#   wrap the subclass's _create_release, run after_release('Foo-1.0.tar.gz'),
#   assert it was entered exactly once with 6 arguments after $self.

# bundle_uses_subclass
ok  grep { $_->isa('Dist::Zilla::Plugin::Author::GETTY::GitHubRelease') } @plugins;
ok !grep { ref($_) eq 'Dist::Zilla::Plugin::GitHub::CreateRelease' } @plugins;
```

- [ ] **Step 2:** `prove -lv t/github_release.t` — FAIL (`Can't locate …GitHubRelease.pm`).
- [ ] **Step 3: Implement** (worker). `_create_release` creates the release with
  `draft => \1` (same fields as the parent otherwise), uploads the tarball, dies unless
  the asset answer is `201` (message names the file and says the draft stays for
  inspection), then `update(release_id => …, data => { draft => \0, make_latest =>
  'true'|'false' })` and dies unless `200`. The bundle passes the same `branch` and
  `notes_from` it passes today.
- [ ] **Step 4:** `prove -lv t/github_release.t` and `prove -lr t/` — PASS.
- [ ] **Step 5:** Commit (release-manager), note on k17, k17 → done.

### Task 2: `binary*` keys, subsections, `x_binaries`

**Files:**
- Create: `lib/Dist/Zilla/PluginBundle/Author/GETTY/Binary.pm` (subsection bundle, modelled on `GETTY/Docker.pm`)
- Create: `lib/Dist/Zilla/Plugin/Author/GETTY/Binary.pm` (one instance per binary; `MetaProvider`)
- Modify: `lib/Dist/Zilla/PluginBundle/Author/GETTY.pm` (`our %BINARY_DEFAULTS` beside `%DOCKER_DEFAULTS`; `mvp_multivalue_args` += `binary binary_modules binary_require binary_platforms`; `_binary_default`; `configure` adds one `@Author::GETTY::Binary` per `binary` entry unless `binary_default = 0`)
- Test: `t/binary-config.t`

**Interfaces:**
- Produces: `Dist::Zilla::Plugin::Author::GETTY::Binary` with ro attributes `binary_name` (Str), `script` (Str), `modules` (ArrayRef[Str]), `pp_args` (Maybe[Str]), `require_modules` (ArrayRef[Str]; dist.ini and `x_binaries` call it `require`), `verify` (Maybe[Str]), `smoke` (Maybe[Str]), `platforms` (ArrayRef[Str]), `prepare` (Maybe[Str]).
- Produces: `META.json` key `x_binaries`, exactly this shape (the four command keys appear only when set; `modules` and `require` always, possibly empty):

```json
"x_binaries": {
  "platforms": ["linux-x86_64", "linux-arm64", "macos-arm64", "macos-x86_64", "windows-x86_64"],
  "prepare": "scripts/binary-prepare.sh",
  "binaries": {
    "mcp-wiki": {
      "script": "bin/mcp-wiki",
      "modules": ["MCP::Wiki::Git::History", "Git::Raw"],
      "require": ["Git::Raw", "MCP::Wiki::Git::History"],
      "pp_args": "perl -Ilib scripts/loaded-modules.pl --pp-args",
      "verify": "scripts/binary-verify.sh",
      "smoke": "scripts/binary-smoke.sh"
    }
  }
}
```

- [ ] **Step 1: Write the failing tests** (test-writer), with the `build_dist` helper
  pattern of `t/docker-subsection.t`, reading `META.json` from the built dist:

```perl
# simple_form:        binary = foo
is $x->{binaries}{foo}{script}, 'bin/foo';
is_deeply $x->{platforms}, [qw(linux-x86_64 linux-arm64 macos-arm64 macos-x86_64 windows-x86_64)];
is_deeply $x->{binaries}{foo}{modules}, [];
# two_binaries_share_defaults: binary = foo / binary = bar / binary_modules = A B / binary_smoke = s.sh
is_deeply $x->{binaries}{$_}{modules}, [qw(A B)] for qw(foo bar);
is $x->{binaries}{bar}{smoke}, 's.sh';
# subsection_overrides: binary_default = 0, binary_smoke = s.sh,
#   [@Author::GETTY::Binary / baz] script = script/baz.pl, modules = C
is $x->{binaries}{baz}{script}, 'script/baz.pl';
is_deeply $x->{binaries}{baz}{modules}, ['C'];
is $x->{binaries}{baz}{smoke}, 's.sh';
# platform_subset:    binary_platforms = linux-x86_64 macos-arm64
is_deeply $x->{platforms}, [qw(linux-x86_64 macos-arm64)];
# unknown_platform_croaks:  binary_platforms = linux-mips   -> qr/unknown platform linux-mips/
# bad_name_croaks:          binary = ../x                   -> qr/binary name/
# missing_script_fails_build: binary = foo, no bin/foo       -> qr{bin/foo}
# needs_github_release:     binary = foo, no_github_release = 1 -> qr/needs the GitHub release/
# no_binary_no_change:      no binary keys -> no x_binaries, no plugin isa ...::Binary
# make_latest_false_with_binaries: binary = foo -> the GitHubRelease plugin's make_latest is false
```

- [ ] **Step 2:** `prove -lv t/binary-config.t` — FAIL.
- [ ] **Step 3: Implement** (worker). Name rule: `/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/`.
  Whitespace splitting of multi-values as `Docker.pm`'s `_normalize_tags` does. How the
  instances combine into one `x_binaries` is the worker's choice (spec: left to the
  builder) — the test fixes the result.
- [ ] **Step 4:** `prove -lr t/` — PASS; the bundle's own `dzil build` still works
  (it dogfoods itself).
- [ ] **Step 5:** Commit (release-manager).

### Task 3: Local check on `dzil build`, workflow check on `dzil release`

**Files:**
- Modify: `lib/Dist/Zilla/Plugin/Author/GETTY/Binary.pm` (roles `AfterBuild`, `BeforeRelease`)
- Modify: `.github/actions/dzil-test/action.yml` (`DZIL_BINARY_SKIP: 1` in the env of the `Run dzil` step)
- Test: `t/binary-build.t`

**Interfaces:**
- Consumes: the attributes from Task 2.
- Produces: local binaries at `<build_root>-binaries/<name>` (a sibling of the build
  directory, so a dist's `/<Dist>-*` ignore pattern covers it); `after_build`,
  `before_release`.

- [ ] **Step 1: Write the failing tests** (test-writer). A fake `pp` and fake verify /
  smoke scripts in a temp `PATH` record their argv (one line per argument) and env:

```perl
# skip_env:                    DZIL_BINARY_SKIP=1 -> fake pp never called
# packs_with_args:             binary = foo, binary_modules = A,
#                              binary_pp_args = 'printf "%s\n" -a "/x y;lib/z"'
is_deeply \@pp_argv, ['-o', "$sib/foo", '-I', "$build/lib", '-M', 'A', '-a', '/x y;lib/z', "$build/bin/foo"];
is $pp_env{PAR_VERBATIM}, 1;
# pp_args_lines_are_single_arguments: the '-a' value above arrives as ONE argument
# verify_and_smoke_get_binary_path: recorded "verify $sib/foo" and "smoke $sib/foo"
# verify_failure_fails_build:  verify exits 1 -> build dies naming the command
# missing_pp_dies_with_hint:   no pp on PATH -> qr/PAR::Packer.*DZIL_BINARY_SKIP=1/s
# release_without_workflow_dies: before_release -> qr{\.github/workflows/binaries\.yml}
# release_with_workflow_passes:  file contains
#   'uses: Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@binary-v1'
```

- [ ] **Step 2:** `prove -lv t/binary-build.t` — FAIL.
- [ ] **Step 3: Implement** (worker). Commands run with the build root as cwd, through
  `sh -c`; `pp_args` output is split on newlines only. The library gate is not part of
  the local check (spec).
- [ ] **Step 4:** `prove -lr t/` — PASS.
- [ ] **Step 5:** Commit (release-manager).

### Task 4: Build-leg helpers — matrix, `pp` argv, the two gates

**Files:**
- Create: `.github/dzil-binary/plan.pl`, `.github/dzil-binary/pp-args.pl`, `.github/dzil-binary/require-gate.pl`, `.github/dzil-binary/lib-gate.pl`
- Test: `t/binary-scripts.t` (the scripts are `require`d as modulinos: `main()` only when run as a script)

**Interfaces:**
- `plan.pl <META.json>` → prints three lines, `legs=<json>`, `smoke=<json>` and `prepare_key=<hex>`, for `$GITHUB_OUTPUT`; `prepare_key` is the sha256 of the file the prepare command's first word names, relative to the `META.json`'s directory, or `none` without `prepare`. A leg: `{platform, runner, container?}`; a smoke cell: `{platform, runner, image?}` — values from Global Constraints.
- `pp-args.pl <META.json> <name> <out> <dist_root>` → the full `pp` argv, NUL-separated (`-o <out> -I lib -M … <pp_args lines> <script>`).
- `require-gate.pl <binary> <module|Glob::*>…` → exit 0 or exit 1 listing the missing ones; reads the archive with Archive::Zip (a PAR::Packer dependency, present on every leg), never `@INC`.
- `lib-gate.pl <binary> <linux|macos|windows>` → unpacks the archive to a temp dir, lists what the loader and every shared object inside link (`ldd`, `otool -L`, `objdump -p`), allows the OS system set plus libraries packed in the archive itself, and on Linux checks the highest `GLIBC_x.y` (`objdump -T`) against `2.28`. Pure functions `violations(\%links, \@allowed, \@packed)` and `glibc_max(@versions)` carry the logic.

- [ ] **Step 1: Write the failing tests** (test-writer); archives built in the test with
  `IO::Compress::Zip`:

```perl
# plan_all_platforms:      5 legs, 7 smoke cells, runners as pinned
# plan_subset_platforms:   platforms [linux-x86_64, macos-arm64] -> 2 legs, 4 smoke cells
# plan_rejects_bad_meta:   no x_binaries -> exit 1, qr/x_binaries/
# plan_prepare_key:        prepare 'scripts/p.sh' -> sha256 of that file; file changed -> other key; no prepare -> 'none'
# plan_prepare_missing:    prepare names a file not in the dist -> exit 1, qr/prepare/
# argv_keeps_spaces:       pp_args printing '-a' and '/x y;lib/z' -> two argv entries, second has the space
# argv_order:              -o, -I lib, -M per module, pp_args lines, script last
# require_exact_and_glob:  zip with lib/Git/Raw.pm, lib/Foo/A.pm -> 'Git::Raw' 'Foo::*' pass
# require_missing_listed:  'Bar::Baz' -> exit 1, output names lib/Bar/Baz.pm
# violations_allows_system_and_packed: libc.so.6 + libperl.so (packed) -> no violation
# violations_flags_foreign: libssl.so.3 -> violation naming the object that links it
# glibc_floor:             glibc_max('2.17','2.28','2.3.4') eq '2.28'; '2.29' fails the gate
```

- [ ] **Step 2:** `prove -lv t/binary-scripts.t` — FAIL.
- [ ] **Step 3: Implement** (worker). System sets: Linux `libc libm libpthread libdl
  librt libutil libgcc_s ld-linux-* linux-vdso`; macOS anything under `/usr/lib/` or
  `/System/`; Windows DLLs present in `C:\Windows\System32` or named `api-ms-*`.
- [ ] **Step 4:** `prove -lr t/` — PASS.
- [ ] **Step 5:** Commit (release-manager).

### Task 5: Install scripts and publish helpers

**Files:**
- Create: `.github/dzil-binary/install.sh.in`, `.github/dzil-binary/install.ps1.in`, `.github/dzil-binary/publish.pl`
- Test: `t/binary-install.t`, `t/binary-publish.t`

**Interfaces:**
- `publish.pl render <META.json> <owner> <repo> <tag> <dir>` → writes `install.sh` and `install.ps1` from the templates. Placeholders: `@OWNER@ @REPO@ @TAG@ @VERSION@ @BINARIES@ @PLATFORMS@ @ENV@` (`@ENV@` = dist name upper-cased, `-` → `_`, e.g. `MCP_WIKI`).
- `publish.pl expected <META.json> <version>` → the expected asset names, one per line.
- `publish.pl sums <dir>` → writes `<dir>/SHA256SUMS` (`sha256sum` format) over the expected binaries.
- `publish.pl check <META.json> <version> <dl-dir> <release-json>` → exit 1 when an expected binary is missing in `dl-dir`, or when the release already carries any expected asset; prints `latest=true|false` (false for a prerelease).
- `install.sh` env: `<ENV>_VERSION` (pin), `<ENV>_INSTALL_DIR` (default `~/.local/bin`), `<ENV>_PLATFORM` (override detection), `<ENV>_BASE_URL` (default `https://github.com/<owner>/<repo>/releases`); args: binary names (default all). It carries its release's tag and version, so it needs no API call; with `<ENV>_VERSION` it builds the tag with the same prefix.

- [ ] **Step 1: Write the failing tests** (test-writer). `t/binary-install.t` renders
  `install.sh` for a dist with binaries `foo` and `bar`, serves a fake release from a
  temp dir via `<ENV>_BASE_URL=file://…`, fake binaries record their argv; skip unless
  `curl` and `sha256sum` or `shasum` exist:

```perl
# installs_all:              both in INSTALL_DIR, mode 0755
# installs_selection:        sh install.sh bar -> only bar
# unknown_name:              sh install.sh nope -> exit !=0, output names foo and bar
# checksum_mismatch:         tampered foo -> exit !=0, nothing left in INSTALL_DIR
# unsupported_platform_names_built_ones: PLATFORM=windows-x86_64 with platforms [linux-x86_64]
#                            -> exit !=0, output names linux-x86_64
# warms_cache:               each installed binary ran once with --help (k19)
# creates_install_dir:       INSTALL_DIR absent -> created
# path_hint:                 INSTALL_DIR not in PATH -> output says so
# t/binary-publish.t:
# expected_set_follows_platforms: foo, bar x [linux-x86_64, windows-x86_64]
#   -> foo-1.0-linux-x86_64 foo-1.0-windows-x86_64.exe bar-1.0-linux-x86_64 bar-1.0-windows-x86_64.exe
# missing_binary_fails:      one absent in dl-dir -> exit 1 naming it
# refuses_when_any_asset_exists: release json lists foo-1.0-linux-x86_64 -> exit 1
# prerelease_is_never_marked_latest: release json prerelease=true -> latest=false
# sums_cover_expected_only:  SHA256SUMS has one line per expected binary, no tarball line
```

- [ ] **Step 2:** `prove -lv t/binary-install.t t/binary-publish.t` — FAIL.
- [ ] **Step 3: Implement** (worker). `install.sh` is POSIX sh, `curl -fsSL`, verifies
  before installing, installs through a temp file in the target dir plus `mv`, and runs
  each binary once with `--help </dev/null >/dev/null 2>&1 || true`. `install.ps1` does
  the same with `Invoke-WebRequest`, `Get-FileHash -Algorithm SHA256`, default dir
  `%LOCALAPPDATA%\Programs\<dist>`; it is first run on a Windows runner in Task 7 (no
  `pwsh` on the dev box).
- [ ] **Step 4:** `prove -lr t/` — PASS; `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.10.0 /mnt/.github/dzil-binary/install.sh.in` clean.
- [ ] **Step 5:** Commit (release-manager).

### Task 6: The reusable workflow `dzil-binary.yml`

**Files:**
- Create: `.github/dzil-binary/build-perl.sh` (port of the spike's `build/build-perl.sh`), `.github/dzil-binary/build-leg.sh`
- Create: `.github/workflows/dzil-binary.yml`

**Interfaces:**
- Consumes: Tasks 4 and 5 scripts.
- Produces: `on: workflow_call` with inputs `tag` (string, empty = probe run) and
  `bundle_ref` (string, default `binary-v1`; the ref of this repo the scripts are checked
  out from). The caller every dist copies — exact:

```yaml
name: binaries
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      tag:
        description: Release tag to build and attach; empty = probe run
        required: false
jobs:
  binaries:
    permissions:
      contents: write
    uses: Getty/p5-dist-zilla-pluginbundle-author-getty/.github/workflows/dzil-binary.yml@binary-v1
    with:
      tag: ${{ github.event.release.tag_name || inputs.tag }}
```

Jobs: `plan` (tag: download the CPAN tarball asset from the release, 30 × 10 s retry;
probe: `dzil build` through the `dzil-test` action with `command: build`; then
`plan.pl`, tag/version match unless probe) → `build` (matrix `legs`:
`build-perl.sh` (cache via `actions/cache/restore` before and `actions/cache/save` right
after it, never a post-job save, so nothing installed later lands in it) → local lib
activated → `prepare <cache dir>` → `cpanm --installdeps .` into that local lib (cache
key: platform + perl version + sha256 of `META.json`'s prereqs + `prepare_key`) →
per binary `pp` with `pp-args.pl` → `lib-gate.pl` → `require-gate.pl` → `verify` →
artifact) → `smoke` (matrix `smoke`: Linux via `docker run` of the clean image with the
unpacked tarball mounted, first deleting any system perl (`debian:*-slim` ships `perl-base` as Essential: `rm -f /usr/bin/perl /usr/bin/perl5*` in the throwaway container), then asserting no perl on `PATH` and no build perl; macOS/Windows
on a runner without setup-perl) → `publish` (tag only; `publish.pl check`, `sums`,
`render`, `gh release upload`, then `gh release edit --latest` when `latest=true`).
Hygiene: workflow default `permissions: contents: read`, only `publish` writes;
`persist-credentials: false`; tag values only through `env`; `concurrency:
dzil-binary-<tag or ref>`, `cancel-in-progress: false`; `timeout-minutes` build 60
(cold perl build), smoke 30, publish 15.

- [ ] **Step 1:** `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7` — clean.
- [ ] **Step 2:** `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.10.0 /mnt/.github/dzil-binary/build-perl.sh /mnt/.github/dzil-binary/build-leg.sh` — clean.
- [ ] **Step 3:** `prove -lr t/` — PASS (unchanged).
- [ ] **Step 4:** Commit (release-manager). The end-to-end proof is Task 7.

### Task 7: End-to-end in a throwaway repo, then the tag

Needs the maintainer's go at execution time: creating a public throwaway repo, pushing
to it, creating a release there and deleting the repo afterwards (the spike's go covered
the spike only). Runs after the mcp-wiki plan's Tasks 1–5, because mcp-wiki is the test
dist.

- [ ] **Step 1:** Push the bundle's working branch to GitHub (part of this task's go).
  Create the throwaway repo from mcp-wiki's tracked tree; its `binaries.yml` is the
  caller from Task 6 with `@<branch>` and `bundle_ref: <branch>`.
- [ ] **Step 2: Probe run** (dispatch without tag) — expected: all 5 legs and 7 smoke
  cells green, artifacts named `mcp-wiki-probe-<sha7>-<platform>[.exe]`, no release
  touched. Then a second probe run: perl, prepare and local-lib caches hit on every leg
  (cache step logs), mcp-wiki's prepare takes its Git-Raw tarball from the cache
  directory, and the restored packing perl's own `site_perl` holds no `Git/Raw.pm`.
- [ ] **Step 3: Release run** — `dzil release` of the throwaway dist with `no_cpan = 1`
  (the k17 subclass creates the release). Expected: release published, not latest,
  tarball present when `plan` starts (no retry needed); after the run: 5 binaries,
  `SHA256SUMS`, `install.sh`, `install.ps1`, release marked latest.
- [ ] **Step 4: Re-run refused** — dispatch with the same tag: `publish` fails with the
  "already carries" message; assets unchanged.
- [ ] **Step 5: Install** — `curl -fsSL …/releases/latest/download/install.sh | sh` on
  Linux and macOS runners, `irm …/install.ps1 | iex` on `windows-2022`; then a three-way
  concurrent first start of the installed binary succeeds (k19).
- [ ] **Step 6:** Delete the throwaway repo; record run URLs and results on the umbrella
  card.
- [ ] **Step 7:** Switch defaults to `binary-v1`, then ask the maintainer for the go to
  push the tag `binary-v1`. Never move `v1`.

### Task 8: POD, skill reference, release readiness

**Files:**
- Modify: `lib/Dist/Zilla/PluginBundle/Author/GETTY.pm` (POD section "Binaries" after the Docker section: SYNOPSIS, every `binary*` key, the caller workflow verbatim, `DZIL_BINARY_SKIP`)
- Modify: `lib/Dist/Zilla/PluginBundle/Author/GETTY/Binary.pm`, `lib/Dist/Zilla/Plugin/Author/GETTY/Binary.pm`, `lib/Dist/Zilla/Plugin/Author/GETTY/GitHubRelease.pm` (POD)
- Modify: `cpanfile` (`PAR::Packer` under `recommends`, used only by the local check)

- [ ] **Step 1** (worker): POD as listed; `podchecker` clean; `prove -lr t/` — PASS.
- [ ] **Step 2** (release-manager): `Changes` entry, commit, pre-release audit. The CPAN
  release of the bundle is the maintainer's go; it must precede the first mcp-wiki
  release that declares binaries.
