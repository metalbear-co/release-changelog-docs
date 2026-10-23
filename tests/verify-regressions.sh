#!/usr/bin/env bash
set -euo pipefail
umask 077

# Run the real path guard and extracted observation statements without rendering
# private histories again. The optional helper argument tests an older candidate.
[[ $# == 1 || $# == 2 ]] || { printf 'Usage: bash tests/verify-regressions.sh OWNED_DIRECTORY [HELPER]\n' >&2; exit 1; }
[[ -d "$1" && ! -L "$1" && $(stat --format '%u' -- "$1") == "$(id --user)" ]] || exit 1
root=$(mktemp --directory --tmpdir="$1" 'regressions.XXXXXXXX')
helper=$(realpath --canonicalize-existing -- "${2:-$(dirname -- "${BASH_SOURCE[0]}")/verify.sh}")
printf 'Regression artifacts: %s\n' "$root"
failed=0

record() {
    local name=$1 expected=$2 actual=$3
    shift 3
    jq --compact-output --null-input --arg name "$name" --arg cwd "$PWD" \
        --argjson expected "$expected" --argjson actual "$actual" --args \
        '{name:$name,cwd:$cwd,expected:$expected,actual:$actual,argv:$ARGS.positional}' -- "$@" >> "$root/results.jsonl"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Regression failed: %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
        failed=1
    fi
}

mkdir -- "$root/line"$'\n' "$root/target"
ln --symbolic -- "$root/target" "$root/line"$'\n'"/link"
args=(bash "$helper" --artifacts "$root/line"$'\n'"/link/child" --sources "$root/no-sources")
status=0
"${args[@]}" > "$root/path.stdout" 2> "$root/path.stderr" || status=$?
record newline-path-exit 1 "$status" "${args[@]}"
followed=false
[[ ! -e "$root/target/child" && ! -L "$root/target/child" ]] || followed=true
jq --null-input --argjson exit_code "$status" --argjson followed_symlink "$followed" \
    --rawfile stdout "$root/path.stdout" --rawfile stderr "$root/path.stderr" \
    '{exit_code:$exit_code,followed_symlink:$followed_symlink,stdout:$stdout,stderr:$stderr}' > "$root/path-result.json"
record hidden-symlink-untouched false "$followed" "${args[@]}"
status=0
jq --exit-status --raw-input --slurp 'contains("Newline in artifact path")' "$root/path.stderr" >/dev/null || status=$?
record newline-diagnostic 0 "$status" jq --exit-status --raw-input --slurp 'contains("Newline in artifact path")' "$root/path.stderr"

# Extract the actual functions and each actual ls-tree assertion, including its
# checked assignment when present. No replacement Git/assertion implementation.
{
    printf 'set -euo pipefail\nshopt -s inherit_errexit\n'
    awk '/^fail\(\)/ || /^trap / { print } /^expect_exit\(\)/ { copying=1 } /^fixture\(\)/ { copying=0 } copying { print }' "$helper"
} > "$root/support.bash"
for observation in race denied; do
    script="$root/$observation.bash"
    cp -- "$root/support.bash" "$script"
    printf '%s=$1\n' "$observation" >> "$script"
    awk -v observation="$observation" '
        index($0, "git_at \"$" observation "/seed\" ls-tree ") { copying=1; found++ }
        copying { print; if ($0 ~ /^[[:space:]]*equal /) copying=0 }
        END { if (found != 1 || copying) exit 1 }
    ' "$helper" >> "$script"
    printf 'printf "ASSERTION PASSED\\n"\n' >> "$script"
    # A missing repository must fail even though Git emits no stdout.
    for control in missing empty populated; do
        directory="$root/$observation-$control"
        expected=1
        if [[ "$control" != missing ]]; then
            mkdir -- "$directory"
            env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git init --initial-branch main "$directory/seed" >/dev/null
            if [[ "$control" == populated ]]; then
                mkdir -- "$directory/seed/changelog"
                printf 'Published page\n' > "$directory/seed/changelog/page.md"
                env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$directory/seed" add -- changelog/page.md
            else
                expected=0
            fi
            env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$directory/seed" \
                -c user.name=Fixture -c user.email=fixture@example.com commit --allow-empty --message control >/dev/null
        fi
        status=0
        bash "$script" "$directory" > "$root/$observation-$control.stdout" 2> "$root/$observation-$control.stderr" || status=$?
        record "$observation-$control" "$expected" "$status" bash "$script" "$directory"
        jq --null-input --argjson exit_code "$status" --rawfile stdout "$root/$observation-$control.stdout" \
            --rawfile stderr "$root/$observation-$control.stderr" \
            '{exit_code:$exit_code,stdout:$stdout,stderr:$stderr}' > "$root/$observation-$control.json"
    done
done
[[ "$failed" == 0 ]] || exit 1
printf 'Artifact path and Git observation regressions passed\n'
