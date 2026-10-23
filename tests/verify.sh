#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit
umask 077

fail() { printf 'Verification failed: %s\n' "$*" >&2; exit 1; }
trap 'printf "Verification command failed at line %s\n" "$LINENO" >&2' ERR

usage() {
    cat <<'EOF'
Usage: bash tests/verify.sh --artifacts DIRECTORY --sources DIRECTORY [--workspaces FILE]
Requires Bash 4.4+, Git, rust-script, Mike Farah yq v4, jq 1.6+ and GNU coreutils.
Sources are pinned histories; workspaces is the optional W0 JSON receipt.
EOF
}
artifacts= sources= workspaces=
while (( $# )); do
    case "$1" in
        --help) usage; exit 0 ;;
        --artifacts|--sources|--workspaces)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
            case "$1" in
                --artifacts) artifacts=$2 ;;
                --sources) sources=$2 ;;
                --workspaces) workspaces=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[[ -n "$artifacts" && -n "$sources" ]] || fail '--artifacts and --sources are required; see action README'
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || fail 'Bash 4.4+ is required'
for dependency in git rust-script yq jq realpath stat mktemp sha256sum id env; do
    command -v "$dependency" >/dev/null || fail "Missing dependency: $dependency (see action README)"
done
[[ $(yq --version) == *'github.com/mikefarah/yq/'*'version v4.'* ]] || fail 'Mike Farah yq v4 is required'
jq_version=$(jq --version)
[[ "$jq_version" =~ ^jq-([0-9]+)\.([0-9]+) ]] || fail 'Cannot determine jq version'
(( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 6) )) || fail 'jq 1.6+ is required'

# Check each component before normalization, so even a link followed by /.. is
# refused. Reject newlines so the component scan cannot miss a later symlink.
# The artifact parent and its new private child must belong to us.
[[ "$artifacts" == /* ]] || artifacts="$PWD/$artifacts"
[[ "$artifacts" != *$'\n'* ]] || fail 'Newline in artifact path is unsupported'
prefix=/
IFS=/ read -r -a parts <<< "$artifacts"
for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    prefix="${prefix%/}/$part"
    [[ ! -L "$prefix" ]] || fail 'Symlink in artifact path'
done
requested=$(realpath --canonicalize-missing --no-symlinks -- "$artifacts")
owner=$(id --user)
if [[ -e "$requested" ]]; then
    [[ -d "$requested" && $(stat --format '%u' -- "$requested") == "$owner" ]] || fail 'Artifact directory must be owned by the current user'
fi
mkdir -p -- "$requested"
[[ $(stat --format '%u' -- "$requested") == "$owner" ]] || fail 'Artifact directory must be owned by the current user'
root=$(mktemp --directory --tmpdir="$requested" 'verify.XXXXXXXX')
printf 'Verification artifacts: %s\n' "$root"
action_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
sources=$(realpath --canonicalize-existing -- "$sources")
[[ -z "$workspaces" ]] || workspaces=$(realpath --canonicalize-existing -- "$workspaces")
jq --null-input --arg bash "$BASH_VERSION" --arg jq "$jq_version" --arg yq "$(yq --version)" \
    '{bash:$bash,jq:$jq,yq:$yq}' > "$root/tool-versions.json"
yq --output-format=json '.' "$action_directory/action.yml" > "$root/action.json"
jq --exit-status '
    .inputs.date.required == false and .inputs.date.default == "2026-10-21" and
    ([.runs.steps[] | select(.id == "render") | .env.CHANGELOG_DATE] == ["${{ inputs.date }}"])
' "$root/action.json" >/dev/null
default_date=$(jq --exit-status --raw-output '.inputs.date.default' "$root/action.json")
for name in validate resolve source render publish; do
    jq --exit-status --raw-output --arg id "$name" \
        '[.runs.steps[] | select(.id == $id)] | if length == 1 then .[0].run else error("Missing or duplicate action block") end | select(type == "string" and length > 0)' \
        "$root/action.json" > "$root/$name.bash"
done
publisher="$root/publish.bash"
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Actual action blocks receive only data inputs and a small environment. Exit
# capture is explicit: expected failures must remain observable under set -e.
# stdout/stderr are files as well as JSON fields so byte comparisons lose nothing.
execute() {
    local script=$1 directory=$2 log=$3 status=0 key
    shift 3
    local -a environment=("PATH=$PATH" "HOME=$HOME" GIT_CONFIG_NOSYSTEM=1
        GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=file)
    for key in CARGO_BUILD_JOBS RUST_TEST_THREADS NEXTEST_TEST_THREADS; do
        [[ ! -v "$key" ]] || environment+=("$key=${!key}")
    done
    (cd -- "$directory" && env --ignore-environment "${environment[@]}" "$@" bash "$script") \
        > "$log.stdout" 2> "$log.stderr" || status=$?
    jq --null-input --argjson exit_code "$status" --rawfile stdout "$log.stdout" --rawfile stderr "$log.stderr" \
        '{exit_code:$exit_code,stdout:$stdout,stderr:$stderr}' > "$log"
    result_log=$log
    result_status=$status
}
expect_exit() {
    [[ "$result_status" == "$1" ]] || fail "Expected exit $1, got $result_status: $result_log"
}
expect_failure() { [[ "$result_status" != 0 ]] || fail "Expected failure: $result_log"; }
equal() { [[ "$1" == "$2" ]] || fail "Values differ: ${3:-assertion}"; }
contains() { jq --exit-status --raw-input --slurp --arg text "$2" 'contains($text)' "$1" >/dev/null || fail "Missing expected text in $1"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "Unexpected path: $1"; }
git_at() {
    local directory=$1
    shift
    env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
        git -C "$directory" "$@"
}
fixture() {
    local directory="$root/$1"
    mkdir -- "$directory"
    git_at "$directory" init --bare --initial-branch main origin.git >/dev/null
    git_at "$directory" clone "$directory/origin.git" seed >/dev/null
    git_at "$directory/seed" config user.name Fixture
    git_at "$directory/seed" config user.email fixture@example.com
    printf 'unrelated content' > "$directory/seed/unrelated.md"
    git_at "$directory/seed" add -- unrelated.md
    git_at "$directory/seed" commit --message initial >/dev/null
    git_at "$directory/seed" push origin HEAD:main >/dev/null
    git_at "$directory" clone "$directory/origin.git" destination >/dev/null
}
candidate() {
    printf -- '---\ntitle: Fixture Changelog\nlastmod: %sT00:00:00.000Z\n---\n\n## %s - 2026-10-21\n\n%s\n' \
        "${4:-2026-10-21}" "$2" "$3" > "$root/$1.md"
}
publish() {
    local test=$1 file=$2 page=$3 source_sha=$4 name=$5
    execute "$publisher" "$test/destination" "$test/$name.json" \
        "GITHUB_WORKSPACE=$test" DESTINATION_DIRECTORY=destination "CANDIDATE_FILE=$file" \
        "DESTINATION_FILE=$page" "SOURCE_SHA=$source_sha" GIT_USER=Fixture GIT_EMAIL=fixture@example.com
}
# Independent expected release boundaries normalize only linked headings, not
# any of the renderer's filtering or publication algorithms.
release_headings() {
    jq --raw-input --slurp '[split("\n")[] | select(startswith("## ")) | sub("^## \\[(?<version>[^\\]]+)\\]\\([^)]*\\)"; "## \(.version)")]' "$1"
}
output_value() {
    jq --exit-status --raw-input --slurp --raw-output --arg key "$2=" \
        '[split("\n")[] | select(startswith($key)) | ltrimstr($key)] | first // error("Missing action output")' "$1"
}

# Full histories stay private. Compare bytes and independently retained ordered
# release boundaries rather than constructing expectations with production code.
for component in operator mirrord mirrord-vscode mirrord-intellij; do
    relative=CHANGELOG.md tags=oss,team,enterprise date=$default_date
    case "$component" in
        operator) relative=public/CHANGELOG.md; title='Operator Changelog'; tags=team,enterprise; date=2023-08-15 ;;
        mirrord) title='mirrord Changelog' ;;
        mirrord-vscode) title='VS Code Changelog' ;;
        mirrord-intellij) title='IntelliJ Changelog' ;;
    esac
    source="$sources/$component/$relative"
    before=$(sha256sum -- "$source")
    cat > "$root/render-$component.bash" <<'EOF'
set -euo pipefail
rust-script "$ACTION_DIRECTORY/src/main.rs" < "$SOURCE_FILE"
EOF
    execute "$root/render-$component.bash" "$root" "$root/render-$component.json" \
        "ACTION_DIRECTORY=$action_directory" "SOURCE_FILE=$source" "CHANGELOG_TITLE=$title" \
        'CHANGELOG_DESCRIPTION=Public release history.' "CHANGELOG_TAGS=$tags" "CHANGELOG_DATE=$date"
    expect_exit 0
    equal "$(release_headings "$result_log.stdout")" "$(release_headings "$source")" "$component release headings"
    equal "$(sha256sum -- "$source")" "$before" "$component source bytes"
    cp -- "$result_log.stdout" "$root/$component.md"
    yq --front-matter=extract --output-format=json '.' "$root/$component.md" > "$root/$component.metadata.json"
    jq --exit-status --arg title "$title" --arg tags "$tags" \
        '.title == $title and .tags == ($tags | split(",")) and .weight == 100' "$root/$component.metadata.json" >/dev/null
done
printf 'Complete histories and component metadata passed\n'

fixture publication
base="$root/publication"
candidate first 3.9.0 'First release' 2026-10-19
first="$root/first.md"
publish "$base" "$first" changelog/mirrord.md "$sha" initial; expect_exit 0
head=$(git_at "$base/destination" rev-parse HEAD)
candidate next-day 3.9.0 'First release'
publish "$base" "$root/next-day.md" changelog/mirrord.md "$sha" unchanged; expect_exit 0
contains "$result_log.stdout" 'retaining existing lastmod'
# Compare only successful observations: an assertion can otherwise mask failed
# command-substitution status, especially when the expected output is empty.
observed=$(git_at "$base/destination" rev-parse HEAD) || fail 'Cannot observe publication HEAD'
equal "$observed" "$head"
cmp -- "$base/destination/changelog/mirrord.md" "$first"
candidate corrected 3.9.0 'Corrected renderer output'
corrected="$root/corrected.md"
publish "$base" "$corrected" changelog/mirrord.md "$other_sha" different-source; expect_exit 1
publish "$base" "$corrected" changelog/mirrord.md "$sha" same-source; expect_exit 0
candidate newer 3.10.0 'Newer release'
newer="$root/newer.md"
publish "$base" "$newer" changelog/mirrord.md "$other_sha" numeric-newer; expect_exit 0
head=$(git_at "$base/destination" rev-parse HEAD)
publish "$base" "$first" changelog/mirrord.md "$sha" stale; expect_exit 0
contains "$result_log.stdout" 'Skipping stale'
observed=$(git_at "$base/destination" rev-parse HEAD) || fail 'Cannot observe publication HEAD'
equal "$observed" "$head"
observed=$(git_at "$base/destination" diff-tree --no-commit-id --name-only --root -r HEAD) || fail 'Cannot observe published paths'
equal "$observed" changelog/mirrord.md
observed=$(git_at "$base/destination" show HEAD:unrelated.md) || fail 'Cannot observe unrelated publication content'
equal "$observed" 'unrelated content'
observed=$(git_at "$base/destination" log -1 --format=%B) || fail 'Cannot observe provenance trailer'
[[ "$observed" == *"Changelog-Source-SHA: $other_sha"* ]] || fail 'Missing provenance trailer'
fixture missing-provenance
missing="$root/missing-provenance"
mkdir -- "$missing/seed/changelog"
cp -- "$first" "$missing/seed/changelog/mirrord.md"
git_at "$missing/seed" add -- changelog/mirrord.md
git_at "$missing/seed" commit --message 'Manual page without provenance' >/dev/null
git_at "$missing/seed" push origin HEAD:main >/dev/null
git_at "$missing/destination" pull --ff-only >/dev/null
publish "$missing" "$corrected" changelog/mirrord.md "$sha" missing; expect_exit 1
printf 'No-op, numeric ordering and same-version provenance passed\n'

# Both writers start before publication; only real Git transport timing is
# interposed in the race cases below, leaving production retry decisions intact.
fixture different-components
competing="$root/different-components"
git_at "$competing" clone "$competing/origin.git" second >/dev/null
publish "$competing" "$first" changelog/mirrord.md "$sha" first; expect_exit 0
execute "$publisher" "$competing/second" "$competing/retry.json" \
    "GITHUB_WORKSPACE=$competing" DESTINATION_DIRECTORY=second "CANDIDATE_FILE=$newer" \
    DESTINATION_FILE=changelog/mirrord-vscode.md "SOURCE_SHA=$sha" GIT_USER=Fixture GIT_EMAIL=fixture@example.com
expect_exit 0
contains "$result_log.stdout" 'push attempt 2/3'
observed=$(git_at "$competing/second" show HEAD:changelog/mirrord.md) || fail 'Cannot observe competing mirrord page'
equal "$observed" "$(cat -- "$first")"
observed=$(git_at "$competing/second" show HEAD:changelog/mirrord-vscode.md) || fail 'Cannot observe competing VS Code page'
equal "$observed" "$(cat -- "$newer")"
printf 'Competing component writes passed\n'
cat > "$root/hooked-publish.bash" <<'EOF'
git() {
  if [[ "$1" == push ]]; then
    command git -C "$COMPETITOR" pull --ff-only >/dev/null
    if [[ "$RACE_KIND" == same-page ]]; then
      mkdir -p "$COMPETITOR/changelog"
      cp "$RACE_CANDIDATE" "$COMPETITOR/changelog/mirrord.md"
      command git -C "$COMPETITOR" add -- changelog/mirrord.md
    else
      printf "contention\n" >> "$COMPETITOR/unrelated.md"
      command git -C "$COMPETITOR" add -- unrelated.md
    fi
    command git -C "$COMPETITOR" commit -m "Competing page edit" >/dev/null
    command git -C "$COMPETITOR" push origin HEAD:main
  fi
  command git "$@"
}
EOF
cat -- "$publisher" >> "$root/hooked-publish.bash"
for kind in same-page exhaustion; do
    fixture "$kind"
    race="$root/$kind"
    candidate "race-$kind" 3.9.0 'Concurrent manual edit'
    execute "$root/hooked-publish.bash" "$race/destination" "$race/outcome.json" \
        "GITHUB_WORKSPACE=$race" DESTINATION_DIRECTORY=destination "CANDIDATE_FILE=$first" \
        DESTINATION_FILE=changelog/mirrord.md "SOURCE_SHA=$sha" GIT_USER=Fixture GIT_EMAIL=fixture@example.com \
        "COMPETITOR=$race/seed" "RACE_KIND=$kind" "RACE_CANDIDATE=$root/race-$kind.md"
    expect_exit 1
    if [[ "$kind" == same-page ]]; then
        contains "$result_log.stderr" 'Concurrent same-version page change'
        observed=$(git_at "$race/seed" show HEAD:changelog/mirrord.md) || fail 'Cannot observe competing page edit'
        equal "$observed" "$(cat -- "$root/race-$kind.md")"
    else
        contains "$result_log.stderr" 'exhausted three push attempts'
        equal "$(jq --raw-input --slurp '[split("\n")[] | select(startswith("Changelog push attempt"))] | length' "$result_log.stdout")" 3
        observed=$(git_at "$race/seed" ls-tree --name-only HEAD changelog) || fail 'Cannot observe retry-budget publication tree'
        equal "$observed" ''
    fi
done
fixture denied
denied="$root/denied"
git_at "$denied/destination" remote set-url --push origin "$denied/nonexistent.git"
publish "$denied" "$first" changelog/mirrord.md "$sha" denied; expect_exit 1
contains "$result_log.stderr" 'Push failed without remote advancement'
observed=$(git_at "$denied/seed" ls-tree --name-only HEAD changelog) || fail 'Cannot observe denied-transport publication tree'
equal "$observed" ''
printf 'Concurrent same-page conflict, retry budget and transport failure passed\n'

# Execute actual env-only rendering against an immutable source commit.
fixture source-checkout
source="$root/source-checkout"
printf '## 1.0.0\n\nPublic release.\n' > "$source/seed/CHANGELOG.md"
git_at "$source/seed" add -- CHANGELOG.md
git_at "$source/seed" commit --message release >/dev/null
source_sha=$(git_at "$source/seed" rev-parse HEAD)
output="$root/render-output"
: > "$output"
render_env=("SOURCE_SHA=$source_sha" "SOURCE_FILE=$source/seed/CHANGELOG.md"
    "ACTION_DIRECTORY=$action_directory" "RUNNER_TEMP=$root" "GITHUB_OUTPUT=$output"
    'CHANGELOG_TITLE=Fixture Changelog' 'CHANGELOG_DESCRIPTION=Public releases.'
    CHANGELOG_TAGS=oss,team "CHANGELOG_DATE=$default_date")
execute "$root/render.bash" "$source/seed" "$root/render-step.json" "${render_env[@]}"; expect_exit 0
page=$(output_value "$output" candidate)
yq --front-matter=extract --output-format=json '.' "$page" > "$root/default-date.metadata.json"
jq --exit-status '.date == "2026-10-21T00:00:00.000Z"' "$root/default-date.metadata.json" >/dev/null
execute "$root/render.bash" "$source/seed" "$root/override-date.json" "${render_env[@]}" \
    CHANGELOG_DATE=2023-08-15 "GITHUB_OUTPUT=$root/override-date.output"; expect_exit 0
page=$(output_value "$root/override-date.output" candidate)
yq --front-matter=extract --output-format=json '.' "$page" > "$root/override-date.metadata.json"
jq --exit-status '.date == "2023-08-15T00:00:00.000Z"' "$root/override-date.metadata.json" >/dev/null
execute "$root/render.bash" "$source/seed" "$root/bad-sha.json" "${render_env[@]}" "SOURCE_SHA=$sha"; expect_exit 1
index=0
for value in 'bad date' '2026-02-30'; do
    execute "$root/render.bash" "$source/seed" "$root/bad-date-$index.json" "${render_env[@]}" "CHANGELOG_DATE=$value"
    expect_failure
    index=$((index + 1))
done

# GitHub downloads the action outside the caller checkout. A misleading caller
# changelog must survive rendering and destination retries without being read.
downloaded="$root/downloaded-action"
mkdir -p -- "$downloaded/src"
cp -- "$action_directory/src/main.rs" "$downloaded/src/main.rs"
renderer_hash=$(sha256sum -- "$downloaded/src/main.rs")
fixture caller-workspace
caller="$root/caller-workspace"
printf 'Caller content must not be rendered or deleted.' > "$caller/seed/CHANGELOG.md"
git_at "$caller/seed" add -- CHANGELOG.md
git_at "$caller/seed" commit --message 'Caller checkout' >/dev/null
caller_sha=$(git_at "$caller/seed" rev-parse HEAD)
validation=("GITHUB_WORKSPACE=$caller/seed" "ACTION_DIRECTORY=$downloaded"
    DESTINATION_REPO=metalbear-co/docs-changelog DESTINATION_FILE=./changelog/mirrord.md
    SOURCE_FILE=./CHANGELOG.md "GITHUB_OUTPUT=$output")
execute "$root/validate.bash" "$root" "$root/validate.json" "${validation[@]}"; expect_exit 0
contains "$output" 'source_directory=release-changelog-docs-source'
contains "$output" 'directory=release-changelog-docs-destination'
for directory in release-changelog-docs-source release-changelog-docs-destination; do
    collision="$caller/seed/$directory"
    mkdir -- "$collision"
    printf 'Preserve preexisting checkout.' > "$collision/sentinel"
    execute "$root/validate.bash" "$root" "$root/existing-$directory.json" "${validation[@]}"; expect_exit 1
    contains "$result_log.stderr" 'Checkout directory already exists'
    equal "$(cat -- "$collision/sentinel")" 'Preserve preexisting checkout.'
    rm -r -- "$collision"
    printf 'Preserve preexisting file.' > "$collision"
    execute "$root/validate.bash" "$root" "$root/existing-file-$directory.json" "${validation[@]}"; expect_exit 1
    equal "$(cat -- "$collision")" 'Preserve preexisting file.'
    rm -- "$collision"
    ln --symbolic -- "$downloaded" "$collision"
    execute "$root/validate.bash" "$root" "$root/symlink-$directory.json" "${validation[@]}"; expect_exit 1
    rm -- "$collision"
done
execute "$root/validate.bash" "$root" "$root/overlapping-action.json" "${validation[@]}" "ACTION_DIRECTORY=$caller/seed"; expect_exit 1
contains "$result_log.stderr" 'Checkout overlaps action directory'
execute "$root/validate.bash" "$root" "$root/invalid-page.json" "${validation[@]}" DESTINATION_FILE=../README.md; expect_exit 1
execute "$root/validate.bash" "$root" "$root/invalid-repository.json" "${validation[@]}" DESTINATION_REPO=other/repo; expect_exit 1
index=0
for file in '' '../CHANGELOG.md' '/CHANGELOG.md' $'CHANGELOG.md\nother.md'; do
    execute "$root/validate.bash" "$root" "$root/invalid-path-$index.json" "${validation[@]}" "SOURCE_FILE=$file"; expect_exit 1
    index=$((index + 1))
done
isolated_source="$caller/seed/release-changelog-docs-source"
source_file=$(output_value "$output" source_file)
equal "$source_file" CHANGELOG.md
pattern_template=$(jq --raw-output '.runs.steps[] | select(.name == "Checkout changelog source") | .with["sparse-checkout"]' "$root/action.json")
expression='${{ steps.validate.outputs.source_file }}'
pattern=${pattern_template//"$expression"/"$source_file"}
git_at "$caller/seed" clone --no-checkout "$source/seed" "$isolated_source" >/dev/null
printf '%s\n' "$pattern" > "$root/isolated-sparse.pattern"
cat > "$root/sparse.bash" <<'EOF'
set -euo pipefail
git sparse-checkout set --no-cone --stdin < "$SPARSE_PATTERN"
EOF
execute "$root/sparse.bash" "$isolated_source" "$root/isolated-sparse.json" "SPARSE_PATTERN=$root/isolated-sparse.pattern"; expect_exit 0
git_at "$isolated_source" checkout --detach "$source_sha" >/dev/null
absent "$isolated_source/unrelated.md"
source_vars=("SELECTED_REF=$source_sha" "SOURCE_FILE=$source_file" "GITHUB_OUTPUT=$output")
execute "$root/source.bash" "$isolated_source" "$root/isolated-source.json" "${source_vars[@]}"; expect_exit 0
execute "$root/source.bash" "$isolated_source" "$root/isolated-mismatch.json" "${source_vars[@]}" "SELECTED_REF=$sha"; expect_exit 1
index=0
for file in missing.md empty.md ../CHANGELOG.md; do
    [[ "$file" != empty.md ]] || : > "$isolated_source/$file"
    execute "$root/source.bash" "$isolated_source" "$root/invalid-source-$index.json" "${source_vars[@]}" "SOURCE_FILE=$file"; expect_exit 1
    index=$((index + 1))
done
ln --symbolic -- "$caller/seed/CHANGELOG.md" "$isolated_source/outside.md"
execute "$root/source.bash" "$isolated_source" "$root/outside-symlink.json" "${source_vars[@]}" SOURCE_FILE=outside.md; expect_exit 1
: > "$output"
execute "$root/render.bash" "$isolated_source" "$root/isolated-render.json" "${render_env[@]}" \
    "ACTION_DIRECTORY=$downloaded" "SOURCE_FILE=$source_file"; expect_exit 0
rendered=$(output_value "$output" candidate)
contains "$rendered" 'Public release.'
jq --exit-status --raw-input --slurp 'contains("Caller content") | not' "$rendered" >/dev/null
fixture isolated-docs
isolated_docs="$root/isolated-docs"
destination="$caller/seed/release-changelog-docs-destination"
git_at "$caller/seed" clone "$isolated_docs/origin.git" "$destination" >/dev/null
printf 'Concurrent unrelated docs content' > "$isolated_docs/seed/unrelated.md"
git_at "$isolated_docs/seed" add -- unrelated.md
git_at "$isolated_docs/seed" commit --message 'Competing docs update' >/dev/null
git_at "$isolated_docs/seed" push origin HEAD:main >/dev/null
execute "$publisher" "$destination" "$root/isolated-publish.json" \
    "GITHUB_WORKSPACE=$caller/seed" DESTINATION_DIRECTORY=release-changelog-docs-destination \
    "CANDIDATE_FILE=$rendered" DESTINATION_FILE=changelog/mirrord.md "SOURCE_SHA=$source_sha" \
    GIT_USER=Fixture GIT_EMAIL=fixture@example.com
expect_exit 0
contains "$result_log.stdout" 'push attempt 2/3'
observed=$(git_at "$destination" show HEAD:changelog/mirrord.md) || fail 'Cannot observe isolated published page'
equal "$observed" "$(cat -- "$rendered")"
observed=$(git_at "$destination" show HEAD:unrelated.md) || fail 'Cannot observe concurrent docs content'
equal "$observed" 'Concurrent unrelated docs content'
observed=$(git_at "$isolated_source" rev-parse HEAD) || fail 'Cannot observe isolated source HEAD'
equal "$observed" "$source_sha"
observed=$(git_at "$caller/seed" rev-parse HEAD) || fail 'Cannot observe caller HEAD'
equal "$observed" "$caller_sha"
equal "$(cat -- "$caller/seed/CHANGELOG.md")" 'Caller content must not be rendered or deleted.'
equal "$(sha256sum -- "$downloaded/src/main.rs")" "$renderer_hash"
observed=$(git_at "$caller/seed" show HEAD:unrelated.md) || fail 'Cannot observe unrelated caller content'
equal "$observed" 'unrelated content'
printf 'Source SHA, render validation and remote-action checkout isolation passed\n'

if [[ -z "$workspaces" ]]; then
    printf 'Workflow integration UNVERIFIED: pass --workspaces with the W0 workspace receipt\n'
else
    # All expressions below are literal YAML/JSON data, never shell source.
    # Parse each actual workflow once, then inspect its structural contracts.
    for component in operator mirrord mirrord-vscode mirrord-intellij; do
        workspace=$(jq --exit-status --raw-output --arg repo "github:metalbear-co/$component" \
            '[.workspaces[] | select(.repo == $repo)] | if length == 1 then .[0].path else error("Missing or duplicate workspace") end' "$workspaces")
        update="$root/update-$component.json"
        release="$root/release-$component.json"
        yq --output-format=json '.' "$workspace/.github/workflows/changelog-update.yaml" > "$update"
        yq --output-format=json '.' "$workspace/.github/workflows/release.yaml" > "$release"
        expected_source=CHANGELOG.md expected_page="changelog/$component.md" expected_date=2026-10-21 secret=CHANGELOG_PAT
        expected_needs='["validate_release_request","release","release_gh"]'
        expected_ref='${{ needs.release.outputs.sha }}'
        case "$component" in
            operator) expected_source=public/CHANGELOG.md; expected_page=changelog/README.md; expected_date=2023-08-15; secret=OPERATOR_CHANGELOG_PAT
                expected_needs='["validate_release_request","create-release"]'; expected_ref='${{ needs.validate_release_request.outputs.sha }}' ;;
            mirrord) expected_needs='["validate_release_request","release_gh"]'; expected_ref='${{ needs.validate_release_request.outputs.sha }}' ;;
        esac
        jq --exit-status --argjson needs "$expected_needs" --arg ref "$expected_ref" --arg secret "$secret" '
            .jobs["update-changelog-web-docs"] |
            .needs == $needs and (.if | contains("needs.validate_release_request.outputs.should_release == '\''true'\''")) and
            .uses == "./.github/workflows/changelog-update.yaml" and .with.ref == $ref and (.secrets | keys) == [$secret]
        ' "$release" >/dev/null
        jq --exit-status --arg secret "$secret" --arg source "$expected_source" --arg page "$expected_page" --arg date "$expected_date" '
            .jobs["build-and-publish"] as $job | $job.steps[0] as $action |
            $job.permissions.contents == "read" and ($job.steps | length) == 1 and
            ($action.uses | test("^metalbear-co/release-changelog-docs@[0-9a-f]{40}$")) and
            $action.with.ref == "${{ inputs.ref }}" and $action.with.source_token == "${{ github.token }}" and
            ($action.with | has("source_sha") | not) and ($action.with | has("checkout_directory") | not) and
            ([.on.workflow_dispatch,.on.workflow_call] | all(.inputs.ref.default == "" and .inputs.ref.required == false and .inputs.ref.type == "string")) and
            (.on.workflow_call.secrets | keys) == [$secret] and .on.workflow_call.secrets[$secret].required == true and
            $action.with.git_access_token == ("${{ secrets." + $secret + " }}") and
            $action.with.destination_repo == "metalbear-co/docs-changelog" and
            ($action.with.local_file_path | sub("^\\./"; "")) == $source and
            ($action.with.destination_file_path | sub("^\\./"; "")) == $page and
            (if $page == "changelog/README.md" then $action.with.date == $date else ($action.with | has("date") | not) end)
        ' "$update" >/dev/null
        jq --exit-status '
            (.runs.steps | map(select(.id == "validate"))[0]) as $validate |
            (.runs.steps | map(select(.id == "resolve"))[0]) as $resolve |
            (.runs.steps | map(select(.id == "source"))[0]) as $source |
            (.runs.steps | map(select(.id == "render"))[0]) as $render |
            (.runs.steps | map(select(.id == "publish"))[0]) as $publish |
            (.runs.steps | map(select(.name == "Checkout changelog source"))[0].with) as $checkout |
            (.runs.steps | map(select(.name == "Checkout destination main"))[0].with) as $destination |
            $checkout.repository == "${{ github.repository }}" and $checkout.ref == "${{ steps.resolve.outputs.ref }}" and
            $checkout.token == "${{ inputs.source_token }}" and $checkout.path == "${{ steps.validate.outputs.source_directory }}" and
            $checkout["persist-credentials"] == false and $checkout["sparse-checkout"] == "/${{ steps.validate.outputs.source_file }}" and
            $checkout["sparse-checkout-cone-mode"] == false and $validate.env.SOURCE_FILE == "${{ inputs.local_file_path }}" and
            $source["working-directory"] == "${{ steps.validate.outputs.source_directory }}" and $source.env.SOURCE_FILE == "${{ steps.validate.outputs.source_file }}" and
            .outputs.source_sha.value == "${{ steps.source.outputs.sha }}" and $resolve.env.GH_TOKEN == "${{ inputs.source_token }}" and
            $render["working-directory"] == "${{ steps.validate.outputs.source_directory }}" and $render.env.ACTION_DIRECTORY == "${{ github.action_path }}" and
            $render.env.SOURCE_SHA == "${{ steps.source.outputs.sha }}" and $render.env.SOURCE_FILE == "${{ steps.validate.outputs.source_file }}" and
            $publish.env.SOURCE_SHA == "${{ steps.source.outputs.sha }}" and $destination.path == "${{ steps.validate.outputs.directory }}" and
            $destination.token == "${{ inputs.git_access_token }}"
        ' "$root/action.json" >/dev/null
        script="$root/resolve-$component.bash"
        cat > "$script" <<'EOF'
gh() { if [[ "$LATEST_STATUS" == missing ]]; then return 1; fi; printf '%s\n' "$LATEST_TAG"; }
EOF
        cat -- "$root/resolve.bash" >> "$script"
        output="$root/resolve-$component.output"
        : > "$output"
        vars=(REQUESTED_REF= "GITHUB_OUTPUT=$output" "GITHUB_REPOSITORY=metalbear-co/$component" LATEST_TAG=v3.10.0 LATEST_STATUS=present)
        execute "$script" "$root" "$root/resolve-$component.json" "${vars[@]}"; expect_exit 0
        contains "$output" 'ref=refs/tags/v3.10.0'
        execute "$script" "$root" "$root/missing-latest-$component.json" "${vars[@]}" LATEST_STATUS=missing; expect_failure
        execute "$script" "$root" "$root/empty-latest-$component.json" "${vars[@]}" LATEST_TAG=; expect_failure
        index=0
        for requested_ref in v3.9.0 'bad ref' refs/tags/missing ''; do
            execute "$script" "$root" "$root/requested-$component-$index.json" "${vars[@]}" "REQUESTED_REF=$requested_ref" LATEST_STATUS=missing
            if [[ -z "$requested_ref" || "$requested_ref" == 'bad ref' ]]; then expect_failure
            else expect_exit 0; contains "$output" "ref=$requested_ref"; fi
            index=$((index + 1))
        done

        # Use the actual wrapper input, actual validated output and actual
        # non-cone checkout pattern before exercising actual source/render blocks.
        fixture "resolver-$component"
        checkout="$root/resolver-$component"
        file="$checkout/seed/$expected_source"
        mkdir -p -- "$(dirname -- "$file")" "$checkout/seed/nested" "$checkout/seed/public"
        printf '## 3.10.0\n\nRelease tree.\n' > "$file"
        printf 'Must not select a nested namesake.' > "$checkout/seed/nested/CHANGELOG.md"
        printf 'Must not select a neighboring file.' > "$checkout/seed/public/unrelated.md"
        git_at "$checkout/seed" add -- "$expected_source" nested/CHANGELOG.md public/unrelated.md
        git_at "$checkout/seed" commit --message release >/dev/null
        expected_sha=$(git_at "$checkout/seed" rev-parse HEAD)
        git_at "$checkout/seed" tag --annotate v3.10.0 --message release
        git_at "$checkout/seed" checkout --detach refs/tags/v3.10.0 >/dev/null
        capture_output="$root/capture-$component.output"
        : > "$capture_output"
        validated="$root/validate-$component.output"
        local_file=$(jq --raw-output '.jobs["build-and-publish"].steps[0].with.local_file_path' "$update")
        destination_file=$(jq --raw-output '.jobs["build-and-publish"].steps[0].with.destination_file_path' "$update")
        execute "$root/validate.bash" "$root" "$root/validate-$component.json" \
            "GITHUB_WORKSPACE=$checkout" "ACTION_DIRECTORY=$action_directory" DESTINATION_REPO=metalbear-co/docs-changelog \
            "DESTINATION_FILE=$destination_file" "SOURCE_FILE=$local_file" "GITHUB_OUTPUT=$validated"
        expect_exit 0
        source_file=$(output_value "$validated" source_file)
        equal "$source_file" "$expected_source"
        source_directory=$(output_value "$validated" source_directory)
        sparse="$checkout/$source_directory"
        git_at "$checkout" clone --no-checkout "$checkout/seed" "$sparse" >/dev/null
        pattern=${pattern_template//"$expression"/"$source_file"}
        printf '%s\n' "$pattern" > "$root/sparse-$component.pattern"
        execute "$root/sparse.bash" "$sparse" "$root/sparse-$component.json" "SPARSE_PATTERN=$root/sparse-$component.pattern"; expect_exit 0
        git_at "$sparse" checkout --detach refs/tags/v3.10.0 >/dev/null
        cmp -- "$sparse/$source_file" "$file"
        for unrelated in unrelated.md nested/CHANGELOG.md public/unrelated.md; do absent "$sparse/$unrelated"; done
        capture_vars=(SELECTED_REF=refs/tags/v3.10.0 "SOURCE_FILE=$source_file" "GITHUB_OUTPUT=$capture_output")
        execute "$root/source.bash" "$sparse" "$root/capture-$component.json" "${capture_vars[@]}"; expect_exit 0
        contains "$capture_output" "sha=$expected_sha"
        execute "$root/source.bash" "$sparse" "$root/automatic-$component.json" "${capture_vars[@]}" "SELECTED_REF=$expected_sha"; expect_exit 0
        execute "$root/source.bash" "$sparse" "$root/mismatch-$component.json" "${capture_vars[@]}" "SELECTED_REF=$sha"; expect_failure
        cat > "$root/missing-ref.bash" <<'EOF'
set -euo pipefail
git checkout --detach refs/tags/missing
EOF
        execute "$root/missing-ref.bash" "$sparse" "$root/missing-ref-$component.json"; expect_failure
        rendered_output="$root/sparse-render-$component.output"
        title=$(jq --raw-output '.jobs["build-and-publish"].steps[0].with.title' "$update")
        description=$(jq --raw-output '.jobs["build-and-publish"].steps[0].with.description' "$update")
        tags=$(jq --raw-output '.jobs["build-and-publish"].steps[0].with.tags' "$update")
        date=$(jq --exit-status --raw-output --arg default "$default_date" \
            '.jobs["build-and-publish"].steps[0].with | if has("date") then .date else $default end' "$update")
        execute "$root/render.bash" "$sparse" "$root/sparse-render-$component.json" \
            "SOURCE_SHA=$expected_sha" "SOURCE_FILE=$source_file" "ACTION_DIRECTORY=$action_directory" \
            "RUNNER_TEMP=$root" "GITHUB_OUTPUT=$rendered_output" "CHANGELOG_TITLE=$title" \
            "CHANGELOG_DESCRIPTION=$description" "CHANGELOG_TAGS=$tags" "CHANGELOG_DATE=$date"
        expect_exit 0
        page=$(output_value "$rendered_output" candidate)
        contains "$page" 'Release tree.'
        yq --front-matter=extract --output-format=json '.' "$page" > "$root/sparse-render-$component.metadata.json"
        jq --exit-status --arg date "$expected_date" '.date == ($date + "T00:00:00.000Z")' \
            "$root/sparse-render-$component.metadata.json" >/dev/null
        jq --exit-status --argjson headings "$(release_headings "$page")" '$headings == ["## 3.10.0"]' \
            --null-input >/dev/null
        if [[ "$component" == mirrord-vscode || "$component" == mirrord-intellij ]]; then
            jq --exit-status '
                .jobs.release as $job |
                ($job.steps | to_entries | map(select(.value.id == "source"))[0].key) as $index |
                $job.outputs.sha == "${{ steps.source.outputs.sha }}" and
                ($job.steps[$index - 1].uses | contains("actions/checkout@")) and
                ($job.steps[$index].run | contains("git rev-parse HEAD"))
            ' "$release" >/dev/null
        fi
    done
    printf 'Source workflow resolver behavior and release wiring passed\n'
fi
printf 'Focused changelog verification passed\n'
