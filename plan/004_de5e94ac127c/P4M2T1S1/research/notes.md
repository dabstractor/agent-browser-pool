# Research notes — P4.M2.T1.S1 config selftests

## Verified facts from the code

### lib/pool.sh — pool_config_init step 6b (lines ~218–233, exact source read)
- `if [[ -n "${ABPOOL_OWNER:-}" ]]; then owner_mode="caller"; else owner_mode="ancestor"; fi`
  → RAW-STRING check, NOT `_pool_config_bool`. Any non-empty value (incl. `1`, `false`, `0`) ⇒ caller mode.
- `lane_pin="${ABPOOL_LANE:-}"`; malformed (not `^[1-9][0-9]*$`) ⇒
  `pool_die "agent-browser-pool: ABPOOL_LANE must be a positive integer, got: '$lane_pin'"`
  (pool_die = non-zero exit + stderr).
- Frozen into globals `POOL_OWNER_MODE` / `POOL_LANE_PIN` (unset ABPOOL_OWNER ⇒ `ancestor`, `""` pin).
- pool_config_init is RE-RUNNABLE (comment at :214 in validate.sh confirms: "MUTABLE globals → re-runnable"). Later code reads only globals.

### test/validate.sh framework facts
- Selftests auto-discovered: `compgen -A function | grep '^selftest_' | sort` in `_run_selftest_suite` (~:1170).
  Bodies run in the MAIN shell via `if "$fn"; then …` — a failed assert's `return 1` records FAIL and the suite CONTINUES. NO registration needed.
- `setup()` (:204–223): ONE call per suite (single-setup runner, AGENTS.md §4). Redirects HOME, AGENT_BROWSER_POOL_STATE, AGENT_CHROME_EPHEMERAL_ROOT, AGENT_CHROME_MASTER into `mktemp -d`, spawns one sim-owner. New selftests must NOT need their own setup/teardown and must spawn NO processes.
- Helpers: `_fail() { … }` (:45), `assert_eq <want> <got> <label>` (:57) — both end the test via the caller's `|| return 1` convention.
- `ABPOOL_TEST_ROOTS+=(…)` tracked for EXIT-trap cleanup; `ABPOOL_REPO` = repo root abs path.

### Canonical patterns to copy
1. **Config-in-subshell precedent** — `selftest_real_bin_name_or_path` (:871): spawn
   `HOME=… VAR=… bash -c 'source "$1/lib/pool.sh"; pool_config_init; printf "%s\n" "$POOL_X"' _ "$ABPOOL_REPO"`
   → captures a global's value without touching the harness's own globals. Note: it makes its own
   `mktemp -d` tmp_home and registers it in ABPOOL_TEST_ROOTS; but since setup() already redirected
   HOME to a temp root, new selftests can simply use the current `$HOME` (no extra mktemp) —
   precedent style either way is acceptable; prefer reusing `$HOME` (zero new temp dirs).
2. **Die-assert idiom** — `selftest_preflight_accepts_bare_name_on_path` (:896–911):
   `rc=0; ( …set -e… ) || rc=$?` then `assert_eq`/`[[ rc -ne 0 ]]` + `_fail`.
   To also grep stderr: capture via `err_file="$(mktemp …)"` or `err="$( … 2>&1 >/dev/null )"` —
   prefer `2>"$err_file"` inside the subshell invocation.
3. Inter-body backstop in the runner wipes `lanes/*.json` — our tests write no leases.

### Placement / size
- New selftest goes in test/validate.sh among the other config-area selftests, anywhere before the
  `_run_selftest_suite` definition (~:1170) — precedent block ends near :911 (preflight test); a good
  spot is right after `selftest_preflight_accepts_bare_name_on_path`.
- Item spec suggests a single function `selftest_config_owner_mode_and_lane_pin` covering:
  (a) default path identity, (b) any-value caller mode, (c) malformed ABPOOL_LANE matrix + valid pin.
- Malformed matrix from the item: `0 -1 abc 2.5 ""` (explicitly-empty exported). Valid: `ABPOOL_LANE=3` ⇒ "3".
  Note: `0` and `-1` fail the `^[1-9][0-9]*$` regex; `""` exported empty is fine ([[ -n "" ]] false ⇒ no die) —
  so for "" the expected result is `POOL_LANE_PIN == ""` (valid-empty), NOT a die. The item lists "" under
  "malformed matrix" but the implemented contract (T2.S1) treats empty as unset-equivalent — assert empty ⇒ no die, POOL_LANE_PIN "".
- Environment isolation: `env -u ABPOOL_OWNER -u ABPOOL_LANE` prefix (or `unset` inside the bash -c) —
  the harness shell may itself export ABPOOL_* in later items; always explicitly control both vars per case.
- 003 fail-fast test (`selftest_*fail_fast*`) is unaffected: config init doesn't do ancestor walks.

### Blessed validation
`timeout 120 bash test/validate.sh` — isolated sandbox ONLY (AGENTS.md §1). Static pre-checks first:
`bash -n test/validate.sh` and `shellcheck -s bash test/validate.sh`.