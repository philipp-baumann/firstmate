#!/usr/bin/env bash
# Live drive for branch fm/forgejo-cli-alternatives (commit 1c1d3c3 "Refuse a
# malformed forge binding instead of falling back to tea").
#
# Runs the real firstmate entry points (bin/fm-project-mode.sh,
# bin/fm-pr-check.sh, bin/fm-pr-merge.sh) and the real bin/fm-pr-lib.sh read
# path that bin/fm-teardown.sh / bin/fm-crew-state.sh call, inside a throwaway
# FM_HOME lab (state/, data/projects.md, config/). The only simulated component
# is the external Forgejo CLI binary `tea`, replaced by a shim that logs every
# invocation and answers `login list` / `api`; no live Forgejo host or host
# login exists in this environment. Every assertion is about firstmate's own
# decision (refuse vs. fall through to tea, and whether tea was touched).
#
# Bash 5 is used because the host /bin/bash is 4.4 and a pre-existing, unrelated
# nounset bug in bin/fm-wake-lib.sh (`${!:-}` at line 770, reached by
# fm-pr-merge.sh and by fm-pr-check.sh on a non-Forgejo path) aborts those
# scripts before the code under test. fm-wake-lib.sh is untouched by this branch.
#
# Usage: live-drive.sh <repo-root>
set -u
ROOT=${1:?usage: live-drive.sh <repo-root>}
B5=${FM_BASH5:-/tmp/fm-b5/bin/bash}
cd "$ROOT" || exit 1
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-cli-lab.XXXXXX") || exit 1
trap 'rm -rf "$lab"' EXIT

mkdir -p "$lab/data" "$lab/state" "$lab/config" "$lab/bin" "$lab/wt"
cat > "$lab/data/projects.md" <<'MD'
# Projects

- proj-broken [no-mistakes forge=forgejo:fgg] - malformed CLI fixture (added 2026-01-01)
- proj-empty [no-mistakes forge=forgejo:] - empty CLI fixture (added 2026-01-01)
- proj-fj [no-mistakes forge=forgejo:fj] - named fj fixture (added 2026-01-01)
- proj-tea [no-mistakes forge=forgejo:tea] - named tea fixture (added 2026-01-01)
- proj-plain [no-mistakes forge=forgejo] - binding with no CLI (added 2026-01-01)
- proj-local [local-only forge=forgejo] - local-only with a forge (added 2026-01-01)
MD
git -C "$lab/wt" init -q
git -C "$lab/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$lab/wt" update-ref refs/remotes/origin/main "$(git -C "$lab/wt" rev-parse HEAD)"

# External Forgejo CLI stand-in: logs every call, answers a login and a record.
cat > "$lab/bin/tea" <<'SH'
#!/usr/bin/env bash
printf 'tea %s\n' "$*" >> "$FM_TEA_LOG"
case "${1:-}" in
  login) printf '[{"name":"main","url":"https://forgejo.example"}]\n' ;;
  api) printf '{"state":"closed","merged":%s,"head":{"sha":"0123456789abcdef0123456789abcdef01234567"}}\n' "${FM_TEA_MERGED:-true}" ;;
esac
exit 0
SH
chmod +x "$lab/bin/tea"

noise() { grep -v 'WATCHER DOWN\|supervision\|supervision protocol\|guarded operation\|repair a missing\|extensions\|●'; }

run_mode() {  # <project>
  printf '\n-- bin/fm-project-mode.sh --forge-cli %s\n' "$1"
  FM_HOME="$lab" FM_DATA_OVERRIDE="$lab/data" "$B5" bin/fm-project-mode.sh --forge-cli "$1"
  printf 'exit=%s\n' "$?"
}

new_home() {  # <name>: isolated FM_HOME carrying the registry
  mkdir -p "$lab/$1/state" "$lab/$1/config" "$lab/$1/data"
  cp "$lab/data/projects.md" "$lab/$1/data/projects.md"
}

write_meta() {  # <home> <id> <project> <url>
  printf 'window=fm-%s\nworktree=%s\nproject=%s\npr=%s\n' "$2" "$lab/wt" "$lab/$3" "$4" \
    > "$lab/$1/state/$2.meta"
}

drive_check() {  # <home> <id> <url>
  : > "$lab/tea.log"
  env PATH="$B5DIR:$lab/bin:$PATH" FM_HOME="$lab/$1" FM_CONFIG_OVERRIDE="$lab/$1/config" \
    FM_TEA_LOG="$lab/tea.log" FM_GATE_REFUSE_BYPASS=1 \
    "$B5" bin/fm-pr-check.sh "$2" "$3" 2>&1 | noise
  printf 'exit=%s\n' "${PIPESTATUS[0]}"
  printf 'tea invocations: %s\n' "$(wc -l < "$lab/tea.log" | tr -d ' ')"
  sed 's/^/  tea> /' "$lab/tea.log"
  printf 'state dir: %s\n' "$(ls "$lab/$1/state" | tr '\n' ' ')"
}

drive_merge() {  # <home> <id> <url>
  : > "$lab/tea.log"
  env PATH="$B5DIR:$lab/bin:$PATH" FM_HOME="$lab/$1" FM_CONFIG_OVERRIDE="$lab/$1/config" \
    FM_TEA_LOG="$lab/tea.log" FM_GATE_REFUSE_BYPASS=1 \
    "$B5" bin/fm-pr-merge.sh "$2" "$3" 2>&1 | noise | head -20
  printf 'exit=%s\n' "${PIPESTATUS[0]}"
  printf 'tea invocations: %s\n' "$(wc -l < "$lab/tea.log" | tr -d ' ')"
  printf 'meta after: %s pr= line(s)\n' "$(grep -c '^pr=' "$lab/$1/state/$2.meta" || true)"
}

drive_teardown_read() {  # <label> <home> <id>
  printf '\n-- teardown-shape read (%s): fm_pr_forgejo_cli_preference "$META" || true, then fm_pr_forgejo_read_record\n' "$1"
  : > "$lab/tea.log"
  FM_TEA_LOG="$lab/tea.log" PATH="$B5DIR:$lab/bin:$PATH" "$B5" -c '
    set -eu
    . "$1/bin/fm-pr-lib.sh"
    fm_pr_forgejo_cli_preference "$2" || true
    printf "FM_PR_FORGEJO_CLI_PREFERENCE=%s\n" "$FM_PR_FORGEJO_CLI_PREFERENCE"
    fm_pr_forgejo_read_record forgejo.example o/r 7 "$FM_PR_FORGEJO_CLI_PREFERENCE"
    printf "record: merged=%s state=%s\n" "$FM_PR_RECORD_MERGED" "$FM_PR_RECORD_STATE"
  ' _ "$ROOT" "$lab/$2/state/$3.meta"
  printf 'exit=%s\n' "$?"
  printf 'tea invocations: %s\n' "$(wc -l < "$lab/tea.log" | tr -d ' ')"
}

B5DIR=$(dirname "$B5")
export B5DIR

echo '===== S1: the registry parser refuses malformed Forgejo CLI bindings'
for p in proj-broken proj-empty proj-fj proj-tea proj-plain proj-local; do run_mode "$p"; done
printf '\n-- unknown project (fallback must stay auto)\n'
FM_HOME="$lab" FM_DATA_OVERRIDE="$lab/data" "$B5" bin/fm-project-mode.sh --forge-cli proj-unknown
printf 'exit=%s\n' "$?"
printf '\n-- absent registry (fallback must stay auto)\n'
mkdir -p "$lab/noreg"
FM_HOME="$lab/noreg" "$B5" bin/fm-project-mode.sh --forge-cli proj-anything
printf 'exit=%s\n' "$?"

echo
echo '===== S2: arming refuses a malformed binding (forge=forgejo:fgg), arms nothing, never runs tea'
new_home homeBroken
write_meta homeBroken task-broken proj-broken https://forgejo.example/o/r/pulls/7
drive_check homeBroken task-broken https://forgejo.example/o/r/pulls/7

echo
echo '===== S3: the merge path refuses a malformed binding (forge=forgejo:fgg), records nothing, never runs tea'
drive_merge homeBroken task-broken https://forgejo.example/o/r/pulls/7

echo
echo '===== S4: adversarial - other parser refusals propagate too (not special-cased to a bad CLI name)'
new_home homeEmpty
write_meta homeEmpty task-empty proj-empty https://forgejo.example/o/r/pulls/9
drive_check homeEmpty task-empty https://forgejo.example/o/r/pulls/9
new_home homeLocal
write_meta homeLocal task-local proj-local https://forgejo.example/o/r/pulls/9
drive_check homeLocal task-local https://forgejo.example/o/r/pulls/9

echo
echo '===== S5: fallback preserved - a binding that names no CLI still arms through tea'
new_home homePlain
write_meta homePlain task-plain proj-plain https://forgejo.example/o/r/pulls/8
drive_check homePlain task-plain https://forgejo.example/o/r/pulls/8
printf '\n-- and a binding that names tea explicitly still arms through tea\n'
new_home homeTea
write_meta homeTea task-tea proj-tea https://forgejo.example/o/r/pulls/8
drive_check homeTea task-tea https://forgejo.example/o/r/pulls/8
printf '\n-- and an absent registry still arms through tea\n'
mkdir -p "$lab/homeFresh/state" "$lab/homeFresh/config"
write_meta homeFresh task-fresh proj-plain https://forgejo.example/o/r/pulls/8
drive_check homeFresh task-fresh https://forgejo.example/o/r/pulls/8

echo
echo '===== S6: the read path (teardown / crew-state) keeps the auto fallback and does not abort'
drive_teardown_read 'malformed binding' homeBroken task-broken
drive_teardown_read 'valid binding naming no CLI' homePlain task-plain
