# Changelog

## Unreleased

- Quitting no longer waits for git: `exit_mode = "background"` (default) hands the last save to a detached nvim worker (`lua/xyno_history/exit_worker.lua`), falling back to the bounded synchronous snapshot when it cannot start; `"sync"` and `"off"` remain. Measured on 30,000 files: `:qa!` to process end 53-58 ms (sync) vs 1 ms; the save is recorded 143-195 ms after `:qa!`.
- `:LocalHistoryPanel [file|project]`: snapshot list with labels, changed files per snapshot (A/M/D/R), diff preview (snapshot vs current, or vs previous), search by content (`/`), revert of a file or one hunk, deleted files restorable, side-by-side diff. Research basis: JetBrains Local History help, 2026-11-12.
- `:LocalHistoryLabel [text]` and `snapshot({ mark = true })`: a labelled snapshot is committed even if the tree did not change.
- Highlight groups `XynoHistory*` (default links to theme groups), `statusline()` / `statusline_hl()`, `keymaps` accept `panel` and `label`.
- `:checkhealth xyno_history` shows the exit mode, the result of the last exit worker and missing highlight groups.
- README/help document `throttle_s`, `fail_backoff_s`, `full_scan_s`, `list_limit`, `exit_mode` and the size caps.
- Tests: 158 (was 132).
