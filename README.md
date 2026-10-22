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

All inputs except `ref` are required. Metadata values are fixed in each source workflow.

| Input | Contract |
| --- | --- |
| `local_file_path` | Complete source changelog relative to the selected source checkout. |
| `destination_repo` | `metalbear-co/docs-changelog`. |
| `destination_file_path` | `changelog/README.md`, `changelog/mirrord.md`, `changelog/mirrord-vscode.md` or `changelog/mirrord-intellij.md`; an initial `./` is accepted. |
| `git_user`, `git_email` | Destination commit identity, configured only in the isolated checkout. |
| `git_access_token` | Destination contents-write token, separate from `source_token`. |
| `title`, `description` | Nonblank, single-line component metadata. |
| `tags` | Comma-separated nonblank tags. |
| `date` | Fixed initial page date, exactly `YYYY-MM-DD`. |
| `ref` | Optional commit, tag or branch; empty selects the latest published release tag, with no main fallback. |
| `source_token` | Source contents-read token, supplied as `${{ github.token }}` by wrappers. |

| Component | Destination file | Title | Description | Tags | Date |
| --- | --- | --- | --- | --- | --- |
| Operator | `changelog/README.md` | Operator Changelog | The release changelog for the mirrord operator. | `team,enterprise` | `2023-08-15` |
| mirrord | `changelog/mirrord.md` | mirrord Changelog | The release changelog for the mirrord CLI. | `oss,team,enterprise` | `2026-10-21` |
| VS Code | `changelog/mirrord-vscode.md` | VS Code Changelog | The release changelog for the mirrord VS Code extension. | `oss,team,enterprise` | `2026-10-21` |
| IntelliJ | `changelog/mirrord-intellij.md` | IntelliJ Changelog | The release changelog for the mirrord IntelliJ plugin. | `oss,team,enterprise` | `2026-10-21` |

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

Only numeric `[#123]` references to
`https://github.com/metalbear-co/operator/issues/123` are private issue references.
Wrapped references are removed with their leading whitespace. Public issue/PR
links, other labels and external URLs remain. Full inherited IDE history and
plain historical version headings are retained.

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
`operator/public/CHANGELOG.md`). `--workspaces` accepts the coordinator receipt
`{"workspaces":[{"repo":"github:metalbear-co/mirrord","path":"/absolute/issue/workspace"}, ...]}`
for all four source repositories. With it, the driver also exercises source
resolver/SHA-capture blocks and checks release-job dependencies, guards, secrets
and action pins. Without it, workflow integration is explicitly unverified.
The driver covers full histories, component metadata, no-op dates, source SHA
validation, checkout isolation, stale versions, provenance, competing component
writes, same-page conflicts, exhausted retries and transport failure. Inspect
the per-scenario JSON logs in its printed artifact directory on failure.
