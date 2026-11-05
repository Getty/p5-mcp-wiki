# Binary knowledge in the shared skills — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The two skills the binary agents are briefed with describe the bundle's binary
form, the current runners and everything the spike learned, so a `*-binary-worker`
needs no second source.

**Architecture:** Two skills in two repos. `perl-par-binary-release` (Getty/skills,
`~/dev/skills/perl/perl-par-binary-release/`) keeps the per-dist recipe and gains the
bundle form and the per-OS knowledge; `getty-perl-release-author-getty` (Getty/karr,
`~/dev/karr/.claude/skills/getty-perl-release-author-getty/SKILL.md`) gains the
`binary*` keys next to the Docker keys.

**Tech Stack:** Markdown skills, skilletor, briefing.

**Spec:** `/home/getty/dev/p5-mcp-wiki/docs/superpowers/specs/2026-11-03-binary-release-design.md`
("Facts and constraints", "Amendments after approval"); bundle plan
`2026-11-03-binary-bundle.md` (the keys, `x_binaries`, the caller workflow).

## Global Constraints

- Edit skills only at their source, never an installed copy (skill `getty-skill-library`).
- Writing rules: skill `skill-authoring`; `SKILL.md` holds the decisions, detail goes to `references/`.
- Getty/skills has no agent team and no karr board: a session in `~/dev/skills` does Task 1 and commits it there. Getty/karr has a team: Task 2 is a card on karr's board for `karr-doc-writer`.
- ARM Linux asset name `linux-arm64` (maintainer's decision 2026-11-03, bundle k18); locale-simple's released `linux-aarch64` assets stay as they are.
- Push of either repo: maintainer's go.

## Review Focus

- **A worker on a per-dist dist (locale-simple, karr) reads the bundle section and rebuilds its workflow on a form it does not use.** The skill says in its first lines which path applies to which dist. Checked by Task 1 Step 3.
- **Stale dates and labels**: runner labels and retirement dates rot. The skill names how to check them (GitHub's runner-images README and changelog) next to every label it pins. Checked by Task 1 Step 3.
- **The bundle section documents keys before the bundle has them.** Task 2 runs after bundle Task 8 and copies from the bundle's POD.
- **Briefing breaks** when the skill grows past what the agents can hold, or the description stops matching. Checked by Task 1 Step 4.
- None further found: the remaining failure modes belong to the code plans.

---

### Task 1: Update `perl-par-binary-release`

**Files:**
- Modify: `~/dev/skills/perl/perl-par-binary-release/SKILL.md`
- Modify: `~/dev/skills/perl/perl-par-binary-release/references/workflow.md`, `references/pipeline.md`
- Create: `~/dev/skills/perl/perl-par-binary-release/references/platforms.md`
- Modify: `~/dev/skills/perl/README.md`, `~/dev/skills/README.md` if the description changes

Content:
1. **Which path** (top of `SKILL.md`): an `[@Author::GETTY]` dist uses the bundle form —
   `binary = <name>` and the `binary_*` keys, `x_binaries` in `META.json`, the caller
   workflow calling `dzil-binary.yml@binary-v1`; the dist writes only its prepare,
   verify and smoke scripts (and a `pp_args` command when pp's scanner misses modules).
   The contracts of the four commands, verbatim from bundle plan Global Constraints.
   Every other dist, and the four that still carry their own workflow (karr,
   langertha-knarr, langertha-raider, locale-simple), uses the per-dist recipe below.
2. **Drift in the recipe**: `macos-14` → build `macos-15`, smoke `macos-15` + `macos-26`;
   `perl:5.40-bullseye` is out of support since 2026-08-31 → the no-crypt perl on
   `almalinux:8` (floor 2.28, no `libcrypt.so.1`) or `perl:5.40-bookworm` with
   `libcrypt` documented; `linux-aarch64` → `linux-arm64` for new dists.
3. **`references/platforms.md`** — the spike's lessons, each with the reason: the
   no-crypt perl (`-Ud_crypt -Ud_crypt_r -Ui_crypt -Duseshrplib`); macOS deployment
   target 12.0, `install_name_tool` relink of `libperl.dylib` and ad-hoc re-sign of a
   cached perl, `codesign` cannot strictly sign a PAR binary, a `curl` download carries
   no quarantine flag; Windows: Strawberry ahead of Git Bash's perl, `cpanm` takes a
   directory only when it starts with `.` or `/`, Strawberry's preinstalled SSL modules
   as dead weight; Git::Raw 0.90: `zutil.h` patch on Xcode 16+, hide OpenSSL/libssh2
   headers (headers only on Intel macOS); `pp` misses runtime `require`s; the PAR cache
   location and `PAR_GLOBAL_TMPDIR` (existing directory only, a missing one is silently ignored) vs `PAR_GLOBAL_TEMP` (the exact cache dir); the k19 cold-cache race and the warm start after
   install; the release race and the draft → upload → publish fix; how to check runner
   labels and retirements.

- [ ] **Step 1:** `stat -c '%h' SKILL.md` prints `1` (plain file, no hardlink).
- [ ] **Step 2:** Write the changes above with skill `skill-authoring`.
- [ ] **Step 3:** Read `SKILL.md` as a locale-simple binary worker and as an mcp-wiki
  binary worker: each finds its path in the first section; every pinned label has its
  "how to check" next to it.
- [ ] **Step 4:** `wc -l SKILL.md` ≤ 180; the description still starts with "Use when"
  and names both paths; `skilletor sync` in `~/dev/p5-mcp-wiki` installs the new text;
  the briefing hook check for `mcp-wiki-binary-worker` shows it.
- [ ] **Step 5:** Commit in `~/dev/skills` (main agent; no release-manager there), commit
  style per skill `getty-git-commit-style`.

### Task 2: `binary*` keys in `getty-perl-release-author-getty`

After bundle plan Task 8. A card on karr's board (`cd ~/dev/karr && karr create …`) for
`karr-doc-writer`, with this content:

**Files:**
- Modify: `~/dev/karr/.claude/skills/getty-perl-release-author-getty/SKILL.md` (a `### Binary` block after `### Docker`)

- [ ] **Step 1:** One line per key in the style of the Docker block — `binary`,
  `binary_modules`, `binary_pp_args`, `binary_require`, `binary_verify`,
  `binary_smoke`, `binary_platforms`, `binary_prepare`, `binary_default`,
  `[@Author::GETTY::Binary / name]` — plus one line each for the caller workflow and
  `DZIL_BINARY_SKIP=1`, copied from the bundle's POD; pointer to skill
  `perl-par-binary-release` for everything about packing.
- [ ] **Step 2:** `stat -c '%h'` is `1`; `skilletor sync` in `~/dev/p5-mcp-wiki` pulls
  it.
- [ ] **Step 3:** Commit through `karr-release-manager`.
