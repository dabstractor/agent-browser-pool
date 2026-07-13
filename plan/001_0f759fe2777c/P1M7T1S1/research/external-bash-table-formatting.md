# Research: Bash table formatting for `agent-browser-pool status` (external)

## Summary
Manual `printf` with field-width specifiers (`%Ns`/`%-Ns`) + **precision
truncation** (`%-N.Ns`) is the correct, dependency-free choice. Predictable
alignment, caps long paths, one-liner empty case. `column -t` is NOT needed.

## 1. printf field specifiers
- `%Ns` right-justify min-width N; `%-Ns` left-justify. Width is a **minimum**
  (pad short, but longer strings are NOT truncated). Reused across header+rows.
- Width counts characters (not bytes) in UTF-8 locale under the bash builtin.
- Sources: Bash Builtins https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html ;
  POSIX printf https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html ;
  printf(3) https://man7.org/linux/man-pages/man3/printf.3.html

## 2. Overflow & truncation
- `printf '%-20s' "$long"` does NOT truncate → next column shifts. Gotcha.
- Truncate two ways: `${var:0:N}` (parameter expansion) or `printf '%-N.Ns'`
  (precision = max chars). `%-N.Ns` ⇒ exactly N columns always.
  https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
- Recommendation: `%-24.24s` for OWNER_CWD, `%-16.16s` for SESSION.

## 3. `column -t` vs manual printf
`column` auto-sizes but: external dep, no built-in truncation, breaks on
in-field spaces, odd empty-output. Manual printf wins for a fixed-schema,
polished status command. `column(1)`: https://man7.org/linux/man-pages/man1/column.1.html

## 4. Tab vs space
Use fixed-width **spaces** (printf `%-Ns`). Tab alignment depends on terminal
tab-stop width → misaligns. printf emits literal spaces to a known column.

## 5. Gotchas
- Empty field: `printf '%-6s' ''` → 6 spaces (safe; missing CHROME_PID fine).
- CJK/wide chars: printf counts chars not display-columns → CJK in cwd drifts.
  N/A for ASCII paths. wcwidth(3): https://man7.org/linux/man-pages/man3/wcwidth.3.html
- Numbers as strings with `%s`: right-justify so digits align.

## 6. Recommended layout (widths ≥ both header label AND data)
```
LANE(4r) PORT(6r) SESSION(16,l.16) OWNER_PID(10r) OWNER_CWD(24,l.24)
CHROME_PID(10r) AGE(5r) STATE(12,l)
```
Format (header + rows identical):
```bash
local fmt='%4s %6s %-16.16s %10s %-24.24s %10s %5s %-12s\n'
printf -- "$fmt" LANE PORT SESSION OWNER_PID OWNER_CWD CHROME_PID AGE STATE
printf -- "$fmt" "$lane" "$port" "$session" "$owner_pid" "$owner_cwd" "$chrome_pid" "$age" "$state"
```
Rendered:
```
 L A N E ... (header)
   1   53427 abpool-1                836725 /home/dustin/projects/age    104816   12m live
```
Total content = 87 + 7 separators = 94 cols (fits 100-col terminal).

Empty case:
```bash
if (( ${#rows[@]} == 0 )); then printf 'No active lanes.\n'; return 0; fi
```
