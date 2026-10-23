# Release changelog docs

This composite action adapts the production `metalbear-co/ci/changelog-cleaning`
Rust renderer. It reads a complete towncrier history from the source checkout,
renders a public page, and commits that page to `metalbear-co/docs-changelog` on
`main`. GitBook publishes the destination content to the website. Source changelogs
and release notes stay owned by their product repositories.

The action resolves a source ref in the caller repository, checks it out in a
dedicated workspace child, and captures its full commit SHA internally. Automatic
publication follows successful product release jobs and uses their exact checkout
SHA. With `ref` empty, the action selects GitHub's latest published non-prerelease
release and resolves its tag once; an explicit ref supports recovery. Missing
releases/refs fail rather than fall back to `main`.

## Inputs

All inputs except `date`, `ref` and `public_source_url` are required. Component
metadata stays fixed; source workflows supply it, while the action provides the
default page date.

| Input | Contract |
| --- | --- |
| `local_file_path` | Complete source changelog relative to the selected source checkout. |
| `destination_repo` | `metalbear-co/docs-changelog`. |
| `destination_file_path` | `changelog/README.md`, `changelog/mirrord.md`, `changelog/mirrord-vscode.md` or `changelog/mirrord-intellij.md`; an initial `./` is accepted. |
| `git_user`, `git_email` | Destination commit identity, configured only in the isolated checkout. |
| `git_access_token` | Destination contents-write token, separate from `source_token`. |
| `title`, `description` | Nonblank, single-line component metadata. |
| `tags` | Comma-separated nonblank tags. |
| `date` | Optional fixed initial page date, exactly `YYYY-MM-DD`; defaults to `2026-10-21`. |
| `ref` | Optional commit, tag or branch; empty selects the latest published release tag, with no main fallback. |
| `public_source_url` | Optional canonical public source repository URL; empty (the default) preserves relative links. Allowed roots are `https://github.com/metalbear-co/mirrord`, `https://github.com/metalbear-co/mirrord-vscode` and `https://github.com/metalbear-co/mirrord-intellij`. Operator leaves it unset. |
| `source_token` | Source contents-read token, supplied as `${{ github.token }}` by wrappers. |

| Component | Destination file | Title | Description | Tags | Date |
| --- | --- | --- | --- | --- | --- |
| Operator | `changelog/README.md` | Operator Changelog | The release changelog for the mirrord operator. | `team,enterprise` | `2023-08-15` |
| mirrord | `changelog/mirrord.md` | mirrord Changelog | The release changelog for the mirrord CLI. | `oss,team,enterprise` | `2026-10-21` |
| VS Code | `changelog/mirrord-vscode.md` | VS Code Changelog | The release changelog for the mirrord VS Code extension. | `oss,team,enterprise` | `2026-10-21` |
| IntelliJ | `changelog/mirrord-intellij.md` | IntelliJ Changelog | The release changelog for the mirrord IntelliJ plugin. | `oss,team,enterprise` | `2026-10-21` |

The page `date` records when the component page was introduced, independently of
the release dates in its history and the render-time `lastmod`. Its fixed default
keeps that page metadata stable across releases without repeating it in each
source workflow. Callers can override it to preserve a legacy page date:
Operator supplies `2023-08-15`, while the other components omit the input.

The `source_sha` output is the full lowercase SHA captured from the actual source checkout.
An exact SHA ref must match that checkout. Missing refs, missing/empty source files,
and paths outside the source checkout fail before rendering.

The action reserves `release-changelog-docs-source` and
`release-changelog-docs-destination` under `GITHUB_WORKSPACE`. Both must be absent
and must not overlap the action directory. Caller files stay outside both
checkouts; the renderer is located through `github.action_path`, which can be
outside the caller checkout.

## Rendering contract

The Rust stdin-to-Markdown script uses the existing `fancy-regex` and `chrono`
dependencies through `rust-script`. It removes the introduction only through the
exact towncrier marker, normalizes linked release headings, and omits `Internal`
categories through the next peer category, release or end of file. Heading-like
text inside prose or fenced code does not end an Internal category. Empty releases
receive `No significant changes.`; existing maintenance messages survive.

Inside Internal, fence markers must have at most three leading ASCII spaces.
Four spaces or a tab mark indented code, so those markers must not hide the next
public category or release. Real fences stay private until a matching marker of
at least the opening length has only spaces or tabs after it; headings inside an
unclosed fence stay private through end of file. Historical public fences retain
their permissive handling, including issue links after closing markers.

Only numeric `[#123]` references to
`https://github.com/metalbear-co/operator/issues/123` are private issue references.
Wrapped references are removed with their leading whitespace. Public issue/PR
links, other labels and external URLs remain. Full inherited IDE history and
plain historical version headings are retained.

Public callers can opt into source-relative inline link rebasing with
`public_source_url`. The renderer reads this as `PUBLIC_SOURCE_URL`, together
with the existing verified `SOURCE_SHA` and normalized `SOURCE_FILE`. It emits
`<public_source_url>/blob/<SOURCE_SHA>/<resolved-path>` so moved histories keep
their source repository and selected snapshot. Destinations resolve lexically
against the changelog's parent directory: `.` and `..` collapse without going
above the repository root, and query/fragment suffixes retain their bytes. No
target lookup is performed. Inherited links can still name files absent at that
snapshot, including IntelliJ's telemetry file in older releases; rebasing does
not repair missing historical targets or redirect IDE links to another repo.

Enabled context requires one of the exact public URL roots above (no trailing
slash), a 40-digit lowercase hexadecimal SHA, and a nonempty normalized relative
source file path. Path segments accept only ASCII letters, digits, `.`, `_`, `~`
and `-`; empty, `.` and `..` segments are rejected. Invalid enabled context fails
before page output. With `PUBLIC_SOURCE_URL` unset or empty, standalone renderer
calls retain existing behavior without requiring either source variable. A
private repository URL is never inferred from Git, the environment or metadata.

Rebasing supports ordinary single-line `[label](relative/path)` links, including
labels with inline backtick code, and optional query/fragment suffixes. Paths use
the same unreserved ASCII characters plus `/` and relative `.`/`..` segments.
Code spans (including multiple backticks and spans crossing lines), fenced code,
four-space/tab-indented code and ambiguous HTML/container lines are preserved.
Inline code requires an equal-length closing backtick run within the same public
paragraph or list item; unmatched backticks remain literal and cannot suppress
links in later blocks or releases. Excluded continuation lines can close a valid
span while retaining their original bytes.
Absolute schemes, protocol-relative URLs, root-relative paths, query-only and
fragment-only links are preserved. Reference links/definitions, images, nested
labels, HTML, angle-bracket destinations, multiline links, titles, escaped or
parenthesized destinations and above-root traversal are outside this bounded
syntax and remain unchanged. These link boundaries do not change existing
release-heading normalization or private issue removal.

Frontmatter keeps the existing layout, `draft: false`, `images: []`, `weight: 100`,
`toc: true` and UTC midnight timestamps. Arbitrary single-line title/tag scalars
are quoted when needed. An unchanged rerun ignores only frontmatter `lastmod`
when comparing pages and preserves the existing file and date.

At a fixed date, the original Operator rendering is byte-compatible except for
the Internal-only `3.135.1` release: the old whitespace-sensitive empty-release
regex left it blank, while the new renderer adds `No significant changes.`.
The short-spacing and end-of-file cases have explicit regression fixtures.

## Publication and recovery

The source checkout survives destination checkout and retries. Rendering completes
in `RUNNER_TEMP` before the action checks out the destination. Only the selected
page is staged; there is no blanket add or cleanup of source files.

The first release heading must contain a numeric `major.minor.patch` version,
optionally prefixed with `v`; each integer is limited to nine digits. Comparison
is numeric, so `3.10.0` is newer than `3.9.0`. An older candidate is a successful
stale skip, including explicit historical recovery refs. Historical later
headings need not satisfy this publication guard.

Changed same-version content requires the most recent commit touching that page
to carry exactly `Changelog-Source-SHA: <source_sha>`. This permits a renderer or
metadata refresh from the same source and rejects ambiguous changes from another
source or an untracked manual edit. Identical content needs no provenance commit.
Existing pages without a trailer can therefore pass an unchanged refresh, but a
same-version correction requires a separately reviewed page commit or the next
release. There is no override flag or sidecar state file.

Each content commit has subject `Update <component> changelog` and the source SHA
trailer. Pushes never force. On rejection, the action fetches `main`; it retries
only if the remote advanced, resetting only the disposable destination checkout.
The version and no-op checks run again. A concurrent same-version edit fails
visibly; a concurrent different-component update survives. At most three pushes
are attempted. A rejection without remote advancement reports an error so auth,
branch protection and network failures do not masquerade as contention.

Migrate Operator away from the old writer before enabling the other publishers;
the old writer has none of these collision safeguards. Pin every source caller
to a reviewed, remotely available full action SHA. Confirm org action policy,
destination token contents-write access, direct-push branch protection and GitBook
preview access before activation. Operator retains `OPERATOR_CHANGELOG_PAT`; the
new callers use `CHANGELOG_PAT`. Source `contents: read` access is separate.

A failed docs publication does not invalidate the product release. Recover by
running its manual changelog workflow for the desired release; rerunning product
publication is unnecessary. Preview/live GitBook sync and hosted Actions execution
require rollout verification beyond the local checks below.

## Maintenance checks

Run these Bash commands from the repository root. Use an owned issue run
directory for artifacts, and supply pinned source histories outside this public
repository. Full private Operator history must never be committed as a fixture.

```bash
CARGO_BUILD_JOBS=5 RUST_TEST_THREADS=5 NEXTEST_TEST_THREADS=5 rust-script --test src/main.rs
rustfmt --check src/main.rs
bash -n tests/verify.sh
bash -n tests/verify-regressions.sh
CARGO_BUILD_JOBS=5 RUST_TEST_THREADS=5 NEXTEST_TEST_THREADS=5 bash tests/verify.sh --artifacts /tmp/cor-987/runs/run_10caf8529c58/verification --sources /tmp/cor-987/runs/run_10caf8529c58/receipts/latest-releases --workspaces /tmp/cor-987/runs/run_10caf8529c58/receipts/workspaces.json
bash tests/verify-regressions.sh /tmp/cor-987/runs/run_10caf8529c58/verification
git diff --check
```

The focused CI workflow runs Rust tests and formatting. The broader Bash driver
requires Bash 4.4 or later, Git, `rust-script`, GNU coreutils, Mike Farah's `yq`
v4 and `jq` 1.6 or later. It was verified with `yq` v4.54.1 and `jq` 1.8.1.
Install those development tools separately; the driver reports missing dependencies
and never downloads tools itself. The `yq` executable must be Mike Farah's Go
implementation, because other tools with that name have different interfaces.
These are local verification dependencies, with no change to action dependencies.
The driver converts each actual YAML file to JSON once with `yq`, then uses `jq`
to extract the actual path-validation, resolver, source-validation, render and
publish blocks from root `action.yml` and check workflow contracts structurally.
It creates
unique owned artifact subdirectories, refuses symlinked artifact paths, clears
credentials/global Git configuration from Bash fixtures, and restricts Git
transport to local files. No real remote is written.

`--sources` contains `<repo>/CHANGELOG.md` (Operator uses
`operator/public/CHANGELOG.md`) and each component's `manifest.json`, whose
`commit_sha` pins source-relative links and whose `sha256` checks the history
bytes. The stdin artifact filename stays separate from renderer `SOURCE_FILE`.
`--workspaces` accepts the coordinator receipt
`{"workspaces":[{"repo":"github:metalbear-co/mirrord","path":"/absolute/issue/workspace"}, ...]}`
for all four source repositories. With it, saved full-history page candidates
use the actual wrapper metadata and public URL inputs, and the driver exercises
source resolver/SHA-capture blocks and checks release-job dependencies, guards, secrets
and action pins. Without it, workflow integration is explicitly unverified.
The driver covers full histories, component metadata, the effective default page
date and explicit legacy override through the action render block, no-op dates,
source SHA validation, checkout isolation, stale versions, provenance, competing
component writes, same-page conflicts, exhausted retries and transport failure.
It also checks the three public URL opt-ins and Operator's empty context,
exact pinned link output through the actual render block, default standalone
compatibility and rejection of invalid context before page output.
Inspect the per-scenario JSON logs in its printed artifact directory on failure.
