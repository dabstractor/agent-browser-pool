# Research: Returning & transforming argv arrays in bash under `set -euo pipefail`

Target: bash 5.3, shellcheck 0.11.0. All behavior below is drawn from the GNU Bash
manual (chapter/section URLs given) and the wooledge.org / mywiki.wooledge.org
canon (Greg's Wiki). Numeric wooledge FAQ IDs are stable but were not live-fetched
this run — see *Gaps*.

---

## Summary

Two robust ways to **return a normalized argv from a function** under `set -e`:
(1) a caller-visible **global array** set with `declare -ga NAME=( … )` (or, cleanest,
a **nameref** `local -n`), and (2) NUL-delimited stdout captured with
`mapfile -d '' -t`. For arbitrary argv that may contain spaces, **the global/nameref
idiom is the more robust, idiomatic choice** — it avoids the empty-array `printf`
edge case and needs no subshell. The classic `set -e` traps — `(( i++ ))` with
`i==0`, and bare `shift` running out of args — are all covered by the single
"errexit-exempt contexts" list in *The Set Builtin*; the safe counter form is the
**assignment** `i=$(( i + 1 ))`, and `shift 2 || shift` is safe because every
non-last member of a `||` list is exempt.

---

## Findings

### 1. Returning an arg array from a function under `set -e`

#### 1a. `declare -ga` ordering & caller visibility

1. **`declare -g` is what makes a name global inside a function.** Inside a
   function, plain `declare NAME=…`/`local NAME=…` creates a *local*; only
   `declare -g` (or `declare -ga` for an explicit array) reaches the caller's
   scope. [Bash manual — *Bash Builtins* (`declare`)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html),
   [Arrays](https://www.gnu.org/software/bash/manual/html_node/Arrays.html).

2. **Both orders keep the values — but the single-statement form is canonical.**
   `declare` without a value preserves any existing value (it only sets
   attributes), so:
   - `declare -ga NAME; NAME=( … )` → sets attrs, then assigns; keeps value. ✓
   - `NAME=( … ); declare -ga NAME` → assignment first (creates global), then
     `declare` re-asserts attrs without resetting; keeps value. ✓
   - **`declare -ga NAME=( … )`** — declares global array *and* assigns in one
     atomic step. **This is the preferred form** (clearest, shellcheck-cleanest).
     [Bash Builtins (`declare`)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html).

3. **The real footgun is not order — it is `local` shadowing in the caller.**
   If the caller did `local -a NAME` and the function writes with `declare -g NAME`,
   the `-g` forces a **new global**, which the caller's `local` *shadows* → the
   caller sees its own empty local. With `set -e` this surfaces as a silent
   empty-array bug, not an error. So **`declare -ga` is right for genuine global
   singletons; for "return to this caller" a nameref is safer.** See *Gaps/next
   steps* and [BashFAQ/024 (subshell/scope value loss)](https://mywiki.wooledge.org/BashFAQ/024).

4. **Cleanest "return-by-reference" = nameref (`declare -n`/`local -n`, bash ≥ 4.3).**
   `normalize() { local -n _out=$1; …; _out=( … ); }` with caller
   `local -a r; normalize r "$@"`. No global pollution, no shadow bug. This is the
   idiomatic modern answer to "return an array from a function."
   [Bash Builtins (`declare -n`/nameref)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html),
   [BashGuide/Arrays](https://mywiki.wooledge.org/BashGuide/Arrays).

5. **Shellcheck relevance.** With `declare -ga arr=(…)` and quoted
   `"${arr[@]}"` you avoid SC2128 ("expanding an array without an index gives only
   the first element") and SC2178 ("array used/assigned as a scalar"). The trap
   that *would* trip SC2128/SC2178 is assigning the array as a scalar
   (`NAME="$@"` or `NAME=$(…)`), then reading `"${NAME[@]}"`. Also note the
   ever-present SC2068 ("double-quote array expansions") — every argv expansion
   must be `"${arr[@]}"`, never `${arr[@]}`. [shellcheck wiki: SC2068](https://www.shellcheck.net/wiki/SC2068),
   [SC2128](https://www.shellcheck.net/wiki/SC2128), [SC2178](https://www.shellcheck.net/wiki/SC2178).

#### 1b. NUL-delimited stdout + `mapfile -d`

6. **`mapfile -d` / `readarray -d` requires bash ≥ 4.4** (the `-d delim` option
   was added in 4.4, 2016; `mapfile`/`readarray` itself exists since 4.0). `-d ''`
   means the delimiter is the NUL byte. `-t` strips that trailing delimiter from
   each element. **bash 5.3 fully supports it.**
   [Bash Builtins (`mapfile`/`readarray`)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html).

7. **Empty-input is fine; empty-*arg-list* `printf` is the trap.** `mapfile -d ''
   -t a < /dev/null` → `a=()` (0 elements) ✓. But `printf '%s\0' "${a[@]}"` with
   **zero arguments prints the format string exactly once** (a missing operand is
   treated as the empty string) → it emits a **single NUL** → `mapfile` yields
   `a=( '' )` (**one empty element, not zero**). This is POSIX `printf` semantics,
   not a bash quirk. Guard it. [Bash Builtins (`printf`)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html).

8. **`set -e` / subshell gotchas with the mapfile idiom.**
   - Never pipe into `mapfile` (`… | mapfile -d '' -t a`) — every pipeline
     component runs in a subshell (unless `lastpipe` + job control off), so `a` is
     set in a subshell and **lost**. [BashFAQ/024](https://mywiki.wooledge.org/BashFAQ/024),
     [Pipelines](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html).
   - Use process substitution instead: `mapfile -d '' -t a < <(printf …)`.
     Process-substitution exit status is **not** checked by errexit, so a failure
     inside `<(...)` won't abort the caller (and won't be noticed either — log it).
     [Process Substitution](https://www.gnu.org/software/bash/manual/html_node/Process-Substitution.html).
   - `mapfile` itself returns 0 on success → no errexit issue from the builtin.

9. **NUL is the only delimiter safe for arbitrary argv.** Newlines/colons break on
   embedded newlines/colons. NUL cannot appear in a Unix filename or argv string,
   so NUL-delimited is the lossless choice — but that is exactly why the global/
   nameref idiom (no serialization at all) is strictly more robust here.
   [BashFAQ/024](https://mywiki.wooledge.org/BashFAQ/024).

#### 1c. Recommendation

For functions that transform and **return argv**, prefer the **global array (or
nameref)** idiom: zero-serialization, immune to the empty-`printf` edge, no
subshell risk, faster. Reserve the `printf '%s\0' | mapfile -d` idiom for when you
must pass values **through a pipe / across a subshell boundary** (e.g. capturing a
function's stdout where a side-channel array is undesirable).

---

### 2. The `(( ))` and `shift` traps under `set -euo pipefail`

The whole section follows from one paragraph in the manual. Under `errexit` (-e)
the shell does **not** exit if the failing command is: *part of the list right
after `while`/`until`; part of the test after `if`/`elif`; part of a `&&`/`||` list
except the command after the **final** `&&`/`||`; any command in a pipeline but the
last; or inverted with `!`.*
[The Set Builtin (errexit)](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html),
[Lists](https://www.gnu.org/software/bash/manual/html_node/Lists.html).

2a. **`(( i++ ))` with `i==0` aborts.** The exit status of `(( expr ))` is **0 iff
`expr` is non-zero, else 1**. `i++` (post-increment) evaluates to the **old** value;
if `i` was 0 the expression is 0 → rc 1 → unterminated by any exempt context →
`set -e` aborts. [Bash Builtins (`(( ))`)](https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html),
[Shell Arithmetic](https://www.gnu.org/software/bash/manual/html_node/Shell-Arithmetic.html),
[BashFAQ/105 (errexit surprises)](https://mywiki.wooledge.org/BashFAQ/105).

2b. **`i=$(( i + 1 ))` is always rc 0.** A simple **assignment command** succeeds
unless its RHS is a failing command substitution; arithmetic expansion `$(( ))`
produces a value, not a checked status. So the assignment form is the bulletproof
counter. Alternatives that also dodge the trap: `(( ++i ))` (pre-increment returns
the new value, ≥1 for counters from 0 — but still rc 1 if it ever evaluates to 0),
or `(( i++ )) || true`. [The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html),
[BashFAQ/105](https://mywiki.wooledge.org/BashFAQ/105).

2c. **`while (( $# > 0 ))` is safe.** The command list immediately following the
`while` keyword is an errexit-exempt context, so even when `$#` hits 0 and
`(( ))` returns 1, the loop merely exits instead of aborting the script.
[The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html).

2d. **`shift 2 || shift` is safe (with one caveat).** In a `||` list every command
**but the last** is errexit-exempt, so the failing `shift 2` (rc 1 when fewer than
2 args remain) does not abort; control falls through to `shift`. Caveat: the
**last** `shift` is *not* exempt — if it runs when `$# == 0` it returns 1 and *will*
abort. Inside a `while (( $# ))` body `$# ≥ 1` is guaranteed, so the trailing
`shift` always has something to remove → rc 0. (If you ever call it where `$#`
could be 0, append `|| true`.) [The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html),
[Bourne Shell Builtins (`shift`)](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html),
[Lists](https://www.gnu.org/software/bash/manual/html_node/Lists.html).

2e. **C-style `for ((i=0;i<n;i++))` is safe.** The init/condition/update are
**arithmetic expressions evaluated by the `for` construct**, not standalone
`(( ))` commands, so they never produce a checked exit status and cannot trip
errexit. The loop's own exit status is just that of the last executed body command.
[Looping Constructs](https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html),
[Shell Arithmetic](https://www.gnu.org/software/bash/manual/html_node/Shell-Arithmetic.html).

2f. **`if (( k == idx )); then …; fi` is safe.** The test following `if`/`elif` is
an errexit-exempt context; a false `(( ))` (rc 1) merely takes the `else`/exits the
`if` rather than aborting. [The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html).

> Side note for this codebase: `pipefail` changes only the **last** pipeline's exit
> status to the rightmost failure; it does not add new errexit exemptions, and it
> does not affect any of 2a–2f above. [The Set Builtin (pipefail)](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html).

---

### 3. Best-practice patterns (wooledge canon)

10. **Snapshot `$@` into a local array** so transformations never mutate the live
    positional params until you intend to: `local -a orig=("$@")`.
    [BashGuide/Arrays](https://mywiki.wooledge.org/BashGuide/Arrays).

11. **Reload positional params from an array** with `set -- "${orig[@]}"`. `set --`
    replaces `$1..$N` atomically; quoting `"${orig[@]}"` keeps each element whole.
    [Bourne Shell Builtins (`set`)](https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html),
    [Arguments (`$@`)](https://mywiki.wooledge.org/Arguments).

12. **Rebuild while skipping one index** — iterate by index (`"${!arr[@]}"`), test
    the index, `continue` past the one you drop, `out+=( "${arr[i]}" )` the rest.
    Appending preserves original order and quoting. (See Snippet 3.)
    [BashGuide/Arrays](https://mywiki.wooledge.org/BashGuide/Arrays).

13. **Why quoted `"$@"` preserves spaces.** Unquoted `$@`/`$*` undergo word-splitting
    + globbing, re-splitting args that contain spaces or glob chars into multiple
    words; quoted `"${arr[@]}"` / `"$@"` expands to exactly one word per element
    with no further splitting. This is the #1 rule for argv handling.
    [Arguments](https://mywiki.wooledge.org/Arguments),
    [WordSplitting](https://mywiki.wooledge.org/WordSplitting),
    [Quotes](https://mywiki.wooledge.org/Quotes).

---

### 4. Common pitfalls for "filter argv" transforms

14. **Conditional strip only when `command == X`.** Resolve the **first non-flag
    token** (skip any leading `--flag`/`--flag=val`/`-x`) to identify the command,
    and apply the strip rule only then — never strip a token that merely *looks*
    like the command elsewhere in argv (it could be a URL/value). Keep the first
    non-flag index explicit. (PRD §2.4 step 0 dispatch depends on this.)

15. **A flag that consumes a value (`--session X`) must skip **two** tokens.**
    Handle both `--session X` (two argv slots) and `--session=X` (one slot) or you
    will mis-parse and either drop the value or pass a stray `X` as a positional.
    Use `shift 2 || shift` (Finding 2d) inside the `while (( $# ))` loop.

16. **Empty-array `printf` edge.** `printf '%s\0' "${a[@]}"` on an empty array
    emits one NUL → a spurious empty element after `mapfile`. Guard with an
    existence test or, better, use the global/nameref idiom which never serializes
    (Finding 7).

17. **Don't mutate `$@` while iterating `$@`.** Consume with `shift` in a `while`
    loop *or* snapshot to an array first; mixing index iteration over an array with
    `shift` of `$@` causes off-by-one/double-skip bugs.

18. **`set -u` and unset array elements.** `"${a[@]}"` of an existing (possibly
    empty) array is fine under `set -u`; referencing an **undeclared** name errors.
    Pre-declare every array (`local -a out=()`) before appending.

---

## Copy-pasteable safe snippets (bash 5.3, `set -euo pipefail`, shellcheck-clean)

### (1) Global-array return idiom (preferred for in-process argv return)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Strips any inherited --session <X> / --session=<X> from argv and returns the
# normalized argv in the GLOBAL array NORMALIZED_ARGV.
# Note: the CALLER must NOT `local`-shadow NORMALIZED_ARGV, or -g writes to a
# global the local hides. (For an isolated return, prefer the nameref form below.)
normalize_argv() {                       # stdin/positional: the argv to normalize
  local -a out=()                        # always pre-declare (set -u safe)
  while (( $# > 0 )); do                 # while-cond is errexit-exempt (Finding 2c)
    case "$1" in
      --session=*)                       # --session=X  -> drop this one slot
        shift                            # $# >= 1 here (we're inside the body) -> rc 0
        ;;
      --session)                         # --session X  -> drop flag + its value
        shift 2 || shift                 # 2d: non-last shift is exempt; last shift rc0
        ;;
      *)
        out+=( "$1" )                    # quoted: spaces/globs preserved (Finding 13)
        shift
        ;;
    esac
  done
  declare -ga NORMALIZED_ARGV=( "${out[@]}" )   # atomic global array + assign (Finding 2)
}

# Usage:
# normalize_argv "$@"
# set -- "${NORMALIZED_ARGV[@]}"          # reload positional params (Finding 11)
```

Nameref variant (no global pollution, immune to the local-shadow footgun — preferred):

```bash
normalize_argv_ref() {
  local -n _na_out=$1 ; shift            # bash >= 4.3 nameref
  local -a out=()
  while (( $# )); do
    case "$1" in
      --session=*) shift ;;
      --session)    shift 2 || shift ;;
      *)            out+=( "$1" ); shift ;;
    esac
  done
  _na_out=( "${out[@]}" )                # writes the caller's array directly
}
# Usage:  local -a norm=(); normalize_argv_ref norm "$@"
```

### (2) Null-stdout + `mapfile -d` idiom (only when you must cross a subshell/pipe)

```bash
# Returns NUL-delimited argv on stdout; caller rebuilds an array.
emit_argv_nul() {
  local -a a=( "$@" )
  # Guard the empty case: printf '%s\0' with ZERO args prints one NUL (Finding 7).
  if (( ${#a[@]} > 0 )); then            # if-cond is errexit-exempt (Finding 2f)
    printf '%s\0' "${a[@]}"              # quoted -> no re-splitting (SC2068 avoided)
  fi
}

# Capture (bash >= 4.4 for mapfile -d ; 5.3 OK). NEVER pipe into mapfile (Finding 8).
mapfile -d '' -t CAPTURED < <( emit_argv_nul "$@" )
# CAPTURED is now ("$@") verbatim, or () when there were no args.
```

### (3) Index-tracking rebuild-skip-one loop (drop exactly index K, keep order)

```bash
# Drops element at index $1 from GLOBAL array INPUT_ARGV, writes result to out.
# For "skip the Nth positional", set INPUT_ARGV=( "$@" ) first.
drop_index() {
  local drop=$1 i
  local -a out=()
  for i in "${!INPUT_ARGV[@]}"; do        # iterate by index, preserve order (Finding 12)
    (( i == drop )) && continue          # if-cond/arithmetic safe (Findings 2f/2a)
    out+=( "${INPUT_ARGV[i]}" )          # quoted element access (SC2068 avoided)
  done
  INPUT_ARGV=( "${out[@]}" )             # or: declare -ga OUT=( … )
}
# Counter safety reminder: prefer j=$(( j + 1 )) over (( j++ )) under set -e (2b).
```

---

## Sources

Kept (canonical, stable):
- GNU Bash Manual — *The Set Builtin* (errexit/pipefail exemption list):
  https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- GNU Bash Manual — *Bash Builtins* (`declare -g/-a/-n`, `mapfile`/`readarray -d`,
  `(( ))`, `printf`): https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- GNU Bash Manual — *Bourne Shell Builtins* (`set --`, `shift`):
  https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
- GNU Bash Manual — *Arrays*:
  https://www.gnu.org/software/bash/manual/html_node/Arrays.html
- GNU Bash Manual — *Looping Constructs* (C-for arithmetic):
  https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html
- GNU Bash Manual — *Shell Arithmetic* (`i++` value semantics):
  https://www.gnu.org/software/bash/manual/html_node/Shell-Arithmetic.html
- GNU Bash Manual — *Lists* (`&&`/`||` exemption) /
  *Pipelines* (subshell) / *Process Substitution*:
  https://www.gnu.org/software/bash/manual/html_node/Lists.html ,
  https://www.gnu.org/software/bash/manual/html_node/Pipelines.html ,
  https://www.gnu.org/software/bash/manual/html_node/Process-Substitution.html
- wooledge BashFAQ/105 (errexit surprises):
  https://mywiki.wooledge.org/BashFAQ/105
- wooledge BashFAQ/024 (variables lost in subshell/pipeline → don't pipe into mapfile):
  https://mywiki.wooledge.org/BashFAQ/024
- wooledge BashGuide/Arrays + *Arguments* + *Quotes* + *WordSplitting*:
  https://mywiki.wooledge.org/BashGuide/Arrays ,
  https://mywiki.wooledge.org/Arguments ,
  https://mywiki.wooledge.org/Quotes ,
  https://mywiki.wooledge.org/WordSplitting
- shellcheck wiki SC2068 / SC2128 / SC2178:
  https://www.shellcheck.net/wiki/SC2068 , /SC2128 , /SC2178

Dropped:
- Random blog/forum `set -e` "tips" listicles — superseded by the primary manual
  text and Greg's Wiki; excluded to avoid parroting the `(( i++ ))` myth
  ("always use `|| true`") instead of the precise assignment/nameref fixes.

---

## Gaps

- **No live fetch this run** (no web tool available to this subagent; facts are from
  authoritative memory of the GNU manual + Greg's Wiki). The wooledge **FAQ numeric
  IDs** (105 = errexit, 024 = subshell) are stable but were not live-verified; if a
  link 404s, the content lives under https://mywiki.wooledge.org/BashFAQ/ and the
  errexit canon at https://mywiki.wooledge.org/BashFAQ/105 .
- **Exact `mapfile -d` intro version**: documented as bash 4.4 (the `-d`/`-O`/`-C`
  options shipped together in 4.4). Not independently re-confirmed against the 4.4
  NEWS file this run — but 5.3 ≫ 4.4, so it is a non-issue for the target.
- Suggested next step: paste Snippets 1–3 into a scratch script under
  `set -euo pipefail`, run `shellcheck -S warning` (0.11.0), and exercise the
  empty-argv, `--session` last-with-no-value, and space-in-value cases to
  empirically confirm the empty-`printf` guard and the `shift 2 || shift` edge.

---

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Delivered exactly the requested research deliverable (bash argv-return + set -e traps brief) scoped to bash 5.3 / shellcheck 0.11.0, with the 3 required copy-pasteable snippets and inline GNU-manual + wooledge citations. No source code changed, no scope widened into implementation."
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/4aa1c4bc/plan/001_0f759fe2777c/P1M6T1S2/research/bash-external.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read README.md + PRD.md (context for tailoring snippets to the --session override / subcommand-dispatch argv transform)",
      "result": "passed",
      "summary": "Confirmed the two target functions strip/override --session and dispatch on the first non-flag token; snippets tailored accordingly (drop --session / --session=X, shift 2 || shift, nameref return)."
    }
  ],
  "validationOutput": [
    "Research artifact written to the authoritative run path. Citations are stable GNU Bash manual section URLs + wooledge/Greg's Wiki + shellcheck wiki. Snippets follow the documented errexit-exempt contexts (while/if cond, non-last || member) and the safe assignment-counter form i=$((i+1))."
  ],
  "residualRisks": [
    "No live web fetch was possible (no fetch tool available to this subagent); facts are from authoritative knowledge of the GNU manual + Greg's Wiki. wooledge FAQ numeric IDs (105/024) are stable but not live-verified.",
    "The empty-argv printf edge, shift 2 || shift edge, and mapfile -d (bash>=4.4) claims should be empirically confirmed in a scratch shellcheck run before committing the real functions."
  ],
  "noStagedFiles": true,
  "diffSummary": "Created one new markdown research brief at the assigned output path; no repo source/test files touched.",
  "reviewFindings": [
    "no blockers"
  ],
  "manualNotes": "Snippets are tailored to the agent-browser-pool argv transform (strip inherited --session, override to abpool-<N>, dispatch on first non-flag token). Preferred return idiom is the nameref form (local -n); the requested declare -ga global form is also given with its local-shadow footgun called out. Recommend the implementer run shellcheck 0.11.0 on the final functions and test the empty-argv + --session-as-last-token cases."
}
```
