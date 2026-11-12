# xyno-history.nvim

Local History for Neovim: every throttled save is snapshotted into private git refs, so deletions, resets and bad edits can be recovered.

I use this in my own Rust setup, [xynovim](https://github.com/xynorash/xynovim), and pulled it out as a standalone plugin.

The idea is inspired by the Local History of JetBrains IDEs. I still use JetBrains tools; this plugin is my own independent project and is not affiliated with JetBrains.

## Why

`undofile` does not survive a deleted file, a `git reset --hard`, or an edit made by a tool that rewrote half the tree. A snapshot of the whole worktree on every save does, and it can live inside git without touching the index, the stash or any branch.

## Requirements

- Neovim 0.12+
- `git` in `$PATH`; the file must be inside a git worktree
- optional: an auto-save plugin that fires `User AutoSaveWritePost` with `data.saved_buffer` (a plain `:write` is always covered)

No dependencies on other plugins.

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-history.nvim",
  event = "VeryLazy", -- setup() registers the autocmds and commands, so load it early
  opts = {},
  keys = {
    { "<leader>gH", "<cmd>LocalHistory<cr>", desc = "Local history (file)" },
    { "<leader>gR", "<cmd>LocalHistoryRestore<cr>", desc = "Local history restore" },
  },
}
```

Do not load it only through `keys`: snapshots start when `setup()` runs, and the commands exist only after that.

## Options

`require("xyno_history").setup(opts)`; the defaults:

```lua
{
  commands = true,        -- :LocalHistory, :LocalHistoryPanel, :LocalHistoryLabel, :LocalHistoryRestore, :LocalHistoryPrune
  keymaps = false,        -- false | true | { browse = lhs, panel = lhs, label = lhs, restore = lhs, prune = lhs }
  max_bytes = nil,        -- per-file cap in bytes (nil: 10 MB; <= 0: no cap)
  max_total_bytes = nil,  -- cap of one snapshot (nil: 200 MB; <= 0: none)
  throttle_s = 60,        -- seconds between two snapshots of a repository (0 .. 86400)
  fail_backoff_s = 10,    -- seconds before a failed snapshot is retried (1 .. 3600)
  full_scan_s = 300,      -- at most this often the worktree is walked; 0 = on every snapshot
  exit_mode = "background", -- "background": a detached nvim records the last save after you quit; "sync": quit waits; "off"
  exit_budget_ms = 5000,  -- how long quitting waits in "sync" mode (and when the background worker cannot start); 0 = take none
  list_limit = 100,       -- snapshots listed by :LocalHistory (1 .. 10000)
  exclude = nil,          -- nil = the default secrets list, a list replaces it, false = exclude nothing
  exclude_extra = {},     -- patterns added to the list above
  push_guard = false,     -- install a pre-push hook that refuses refs/lochist/*
  retention = { auto = true, max_count = 1000, max_age_days = 30, interval_h = 6 }, -- false = never prune by itself
}
```

`throttle_s` (default 60) is the minimum gap between two snapshots of one repository, the last save of a window is never lost; `fail_backoff_s` (10) is the wait before a failed snapshot is retried (a second failure produces the one warning); `full_scan_s` (300) bounds how often the whole worktree is walked; `list_limit` (100) caps the panel and `:LocalHistory`; `max_bytes` and `max_total_bytes` cap one file and one snapshot. Numbers are validated: a wrong type, an out-of-range value or an unknown key is reported in **one** warning when `setup()` runs and the default is used instead. `max_count` and `max_age_days` accept `false` to switch that criterion off.

No global keymap is set by default. `keymaps = true` maps `<leader>gH` to `:LocalHistory`; a table maps each action to the key you choose.

## Commands

| Command | What it does |
| --- | --- |
| `:LocalHistoryPanel [file\|project]` | The panel (below): snapshots, the files each changed, a diff preview, revert of a file or a hunk, labels, search by content. |
| `:LocalHistoryLabel [text]` | Label the current state; a snapshot is taken even when nothing changed. |
| `:LocalHistory` | Pick a snapshot of the current file (also the versions it had under an earlier name: renames are followed) and diff against it in a vertical scratch buffer. |
| `:LocalHistoryRestore` | Pick a snapshot and replace the buffer text with it, including its line endings and whether it ended in a newline (buffer left modified, `u` undoes it; disk and index untouched). |
| `:LocalHistoryPrune[!] [N \| Nd]` | Keep the newest N snapshots per branch, or the last N days (default `30d`), then `git gc`. Runs in the background; the result arrives as a notification. With `!`, collect every unreachable object (`--prune=now`). |

Lua: `require("xyno_history").snapshot({ path?, force?, label?, mark?, done? })` (`mark = true` commits even if the tree is unchanged), `.label(text?, cb?)`, `.browse()`, `.restore()`, `.prune(arg, now)`, `.statusline()`, `.statusline_hl()`, `.last_exit(root)`, `require("xyno_history.panel").open({ scope? })`. See `:help xyno-history`.

## The panel

`:LocalHistoryPanel` (file scope) or `:LocalHistoryPanel project` opens a tab with three panes: the snapshots (time, label or `·` for automatic ones, number of files), the files the selected snapshot changed (`A`/`M`/`D`/`R`, coloured) and a diff. Moving the cursor in a pane updates the next ones.

| Key | Action |
| --- | --- |
| `/`, `c` | search the snapshots for a text (git's pickaxe: snapshots in which that text appeared or disappeared; matches highlighted in the diff), clear |
| `L` | put a label on the current state (works with no change; in file scope labelled snapshots that did not touch the file are listed too) |
| `d` | diff "snapshot vs current" (`+` is what a revert would bring back) or "snapshot vs previous" (what that save changed) |
| `s` | file scope / project scope (project shows every file, deleted ones as `D`) |
| `r` | revert the selected file: into its buffer (modified, `u` undoes), or onto the disk for a file that is not open or was deleted, after a question |
| `x` | revert only the hunk under the cursor in the diff (current mode) |
| `<CR>` | open the snapshot beside the current file in Neovim's diff mode |
| `gr`, `y`, `<Tab>`, `q` | refresh, yank the hash, next pane, close |

Compared with the Local History dialog of JetBrains IDEs ([help page](https://www.jetbrains.com/help/idea/local-history.html), read 2026-11-12): the same pieces exist (revision list with labels, diff against the current state, revert of a file or a fragment, deleted files, a content search, "put label"); not copied: "Revert selected and later changes" for a whole directory and "Create patch" (use `git diff refs/lochist/... -- path` by hand), and no tree grouping of the files. The pane layout is a plain scratch-buffer UI, not a floating window.

Highlight groups (links to theme groups by default; your own colour is kept, they are redefined after `:colorscheme`): `XynoHistoryTitle`, `XynoHistoryAge`, `XynoHistoryLabel`, `XynoHistoryMatch`, `XynoHistoryAdded`, `XynoHistoryModified`, `XynoHistoryDeleted`, `XynoHistoryRenamed`, `XynoHistorySelected`, `XynoHistoryHint`, `XynoHistoryDiffAdd`, `XynoHistoryDiffDelete`, `XynoHistoryDiffHunk`, and for the statusline `XynoHistoryOk`, `XynoHistoryPending`, `XynoHistoryFailing`.

Statusline: `require("xyno_history").statusline()` returns `LH 2m` (age of the last snapshot), `LH ...` (one is running), `LH ~` (a save is waiting), `LH !` (snapshots are failing) or an empty string; `statusline_hl()` gives the group. For lualine: `{ function() return (require("xyno_history").statusline()) end, cond = function() return package.loaded["xyno_history"] and require("xyno_history").statusline() ~= "" end, color = function() return require("xyno_history").statusline_hl() end }`.

## How it works

Each snapshot is a commit on `refs/lochist/<branch>` whose tree is the whole worktree: untracked files included, `.gitignore` respected, `target/` left out, likely secrets left out (next section). It is built with a private index file per Neovim process (`.git/lochist-index.<pid>`) and a compare-and-swap `update-ref`, so concurrent instances never overwrite each other. Saves are throttled to `throttle_s` (one minute); the last save of a window is never lost (a trailing snapshot, and one more on exit). Files over `max_bytes` stay out, and the largest files of a snapshot are dropped beyond `max_total_bytes`.

**Cost of a save.** The first snapshot of a session is a *full scan*: `git ls-files -o -m` to size the candidates, then `git add -A` into the private index (seeded from the index of an earlier session). Later snapshots take a *fast path* while the last full scan is younger than `full_scan_s`: they look at the paths saved from Neovim plus `git diff-files` (tracked files that changed, found by `lstat` without walking directories) and run `git add -A` on those paths only. What the fast path does not see is a **new file created behind Neovim's back** (an agent, a build step) and a rename done outside Neovim: they are picked up by the next full scan, at most `full_scan_s` later, and by `snapshot({ force = true })` (a forced call is always a full scan, and the agent hook of xynovim uses that). Edits to existing tracked files by something else are seen on the fast path. If more than 500 paths changed (a checkout) the snapshot falls back to a full scan.

Measured on one machine (Linux, NVMe, git 2.56, warm page cache; a generated tree of 100,000 small files in 2,000 directories; `scripts/bench.lua`, `scripts/bench_exit.lua`; three runs each; ranges where they differed):

| | 100k files, all committed | 100k files, none committed (untracked) |
| --- | --- | --- |
| snapshot after a save, previous version | 0.88 s | 0.76 to 0.84 s |
| snapshot after a save, now | 0.12 s | 0.11 to 0.12 s |
| longest editor stall while snapshotting, previous | 1 ms | 565 to 750 ms (it `stat`ed all 100k files every time) |
| longest editor stall, now | 1 ms | 0 to 1 ms |
| quitting with an unrecorded save, previous | 0.87 s | not measured |
| quitting with an unrecorded save, now | 0.11 s | not measured |
| first snapshot of a session | 1.7 to 1.8 s (both versions) | 1.8 to 2.1 s (both versions) |

The numbers are from a fast local disk; a cold cache, a network file system or an antivirus scanner changes them, and the first snapshot still walks everything. **Quitting** no longer waits for git: with `exit_mode = "background"` (default) the quitting Neovim writes a small handoff file into `.git` (the paths it saved, the time of its last full scan) and starts a detached `nvim --headless -l exit_worker.lua`, which waits for the parent to be gone, adopts its private index, takes the snapshot on the fast path and exits (it gives up after 45 s; the result is `.git/lochist-exit.json`, reported by `:checkhealth`). If the worker cannot be started the snapshot is taken before quitting within `exit_budget_ms`, as `exit_mode = "sync"` always does. Measured on a generated tree of 30,000 files (`scripts/bench_exit.lua`, three runs each): the time from `:qa!` to the end of the process was 53 to 58 ms with `sync` and 1 ms with `background`; the final save was recorded 143 to 195 ms after `:qa!` in the background case (55 to 60 ms in `sync`). The worker is a second Neovim process that lives for about a second after you quit and is not attached to your terminal; a snapshot you needed within that second is not yet visible to a Neovim started at once (it then sees the older tip and takes its own).

**Retention.** After a snapshot, at most every `retention.interval_h` hours per repository (and not in the first minute of a session) old snapshots are dropped in the background: older than `retention.max_age_days` (30), beyond the newest `retention.max_count` per branch (1000); the newest one always stays. This removes the commits from the refs; the disk space is freed by git's own `gc --auto` (unreachable objects older than git's `gc.pruneExpire`, two weeks by default), or at once by `:LocalHistoryPrune!`. `retention = false` turns it off.

**Failures.** A snapshot that fails (git missing, a lock, a full disk, a read-only `.git`, a repository owned by someone else) is retried once after `fail_backoff_s`. If that also fails, **one** warning names the reason (`local history: snapshots are failing, git add failed (exit 128): ...`), nothing more is shown while it keeps failing, and `:checkhealth xyno_history` lists it. `require("xyno_history").status()` returns the same for scripts. A lone failure that the retry fixes stays quiet.

Without the plugin, the snapshots are plain git:

```sh
git log refs/lochist/main
git restore --source=refs/lochist/main --worktree -- path/to/file
```

They stay in the repository until pruned.

## Secrets and pushing

**Snapshots are git objects in the repository's own `.git`.** That is what makes them cheap and gives them git's tools, but it means two things you should know:

1. Whatever a snapshot contains is stored there, readable by anyone who can read the `.git` directory, in packfiles that survive `git gc` for as long as the ref exists.
2. `git push --mirror`, a remote with `mirror = true`, `git push origin 'refs/*:refs/*'`, `git clone --mirror`, `git bundle create --all`, and any backup that copies `.git` carry `refs/lochist/*` with them. A plain `git push` and `git push --all` do not (they push `refs/heads/*`; see `git config push.default`, the default `simple` pushes the current branch only). The spec `tests/secrets_spec.lua` pushes to a bare repository to show both the risk and the guard.

So likely secrets are **left out of the tree** even when `.gitignore` does not cover them. The default list (`require("xyno_history").default_exclude`, case-insensitive, gitignore syntax without `!`):

- environment files: `.env`, `.env.*`, `*.env`, `.envrc`
- keys: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.p8`, `*.jks`, `*.keystore`, `*.ppk`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`, `secring.*`
- password stores: `*.kdbx`, `*.kdb`, `.pgpass`, `.vault-pass*`, `.htpasswd`
- tool credentials: `.npmrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `_netrc`, `.git-credentials`, `.dockercfg`, `credentials`, `credentials.{json,yml,yaml,toml,xml,ini}`, `.credentials*`, `*.credentials`, `secrets.{json,yml,yaml,toml}`, `service-account*.json`, `*.tfvars`, `*.tfstate`, `*.tfstate.backup`, `kubeconfig`
- directories: `.ssh/`, `.gnupg/`, `.aws/`, `.kube/`

The list is deliberately specific: `credentials*` or `id_*` would also hide `credentials.rs` or `id_generator.rs`, source files you want in your history. The file is not hashed at all (the spec searches the whole object store for a canary and does not find it), and it applies to files the repository tracks too (the history of the repository has those already; a snapshot would add one more copy of every edit). Change it with `exclude = { ... }` (replaces), `exclude_extra = { "*.secret", "private/" }` (adds) or `exclude = false` (nothing). Patterns with `!` are not supported and are reported by `setup()`. This is a list of names, not a scanner: a secret in a file called `config.toml` is still snapshotted.

To make `refs/lochist/*` unpushable, `push_guard = true` writes `.git/hooks/pre-push`, which refuses any push that carries a `refs/lochist/` ref (a mirror push, an explicit refspec) and lets everything else through. It only writes the hook if the repository has no `pre-push` hook (it never overwrites yours and says so once), it writes into `.git/hooks` and never through `core.hooksPath`, and it does nothing for `git clone --mirror`, bundles or file copies of `.git`. It is off by default because it changes the repository's hooks. `:checkhealth xyno_history` reports mirror remotes, whether the guard is installed and whether `core.hooksPath` makes it inactive.

## Hostile repository configuration

A repository you cloned can set `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, filter drivers or an `include.path` in its `.git/config`, and `.gitattributes` can name those filters. Every git call of the plugin therefore runs with neutral overrides (`GIT_CONFIG_COUNT`, which ranks like `git -c` and beats every config file including included ones) for `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`, `core.gitProxy`, `core.pager`, `core.editor`, `core.askPass`, `core.alternateRefsCommand`, `credential.helper`, `diff.external`, `gpg.program`, the `clean`/`smudge`/`process`/`textconv` commands of the drivers the repository defines, and `protocol.allow=never`; with `GIT_WORK_TREE` pinned to the directory that holds `.git` (so `core.worktree` cannot make a snapshot of some other directory); with attributes read from the empty tree (`GIT_ATTR_SOURCE`, git 2.41+), so `.gitattributes` can neither run a filter nor convert line endings: the bytes stored are the bytes on disk, which also makes `core.autocrlf` irrelevant; and with `GIT_OPTIONAL_LOCKS=0` and no terminal prompts. The specs (`tests/hostile_spec.lua`) put a script that creates a marker file behind `core.fsmonitor` (also via `include.path`), `core.hooksPath` (and `.git/hooks`) and a filter driver and assert it does not run; for the other settings they assert the effective value git sees under the plugin's environment. What is **not** covered: the user's own global git config is read (it is the user's), the system config is read, `safe.directory` is left to git (a repository owned by someone else makes git refuse, which shows up as a failure), and keys I did not think of. On git older than 2.41 the attribute source is not available and `:checkhealth` says so; the driver commands are still neutralised there.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`, 158 checks in 8 files, plus a lazy.nvim smoke test in CI). The specs use bash stubs and `kill -0`, so they run on Linux and macOS only.
- Windows: no evidence at all. In the original xynovim CI this code's spec was skipped on Windows, so nothing about it is demonstrated there. The hardening uses `NUL` for `core.hooksPath` there, untested.
- macOS: not tested here. In xynovim's CI the original spec was not skipped on macOS and ran in the one fully green macOS run; other macOS runs there were flaky or failed elsewhere, so I do not claim it works.

## Limits

- The panel is a scratch-buffer layout driven by the specs (headless) and looked at once in a terminal through tmux; it has not been tried with every colorscheme or on small terminals (the three panes need roughly 100 columns).
- The background worker is not started on a `.git` file (linked worktrees, submodules): those fall back to the synchronous snapshot.
- The fast path misses files created outside Neovim until the next full scan (above).
- The size budget (`max_total_bytes`) is counted over the files this session has seen as untracked or modified; a file that an earlier session added is counted from the first full scan on.
- Exclusion is by name; it does not read file contents.
- Restore interprets the bytes with the *buffer's* `fileencoding`; a snapshot from before an encoding change comes back in the old bytes read as the new encoding. A conversion that git or Vim cannot do is refused with a warning.
- Rename tracking is git's similarity detection on the snapshot commits (`git log --follow`): a rename combined with a rewrite of most of the file is not followed, and it follows one file, not a directory move of many files at once beyond what git detects per file.
- Only one `.git` per root: submodules are recorded as gitlinks like git does, nested repositories without commits are skipped.
- No sparse-checkout or `skip-worktree` handling beyond what `git add -A` does.

## Extracted from xynovim

This plugin is the Local History module of [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace, the `setup()` options and the git author name used for snapshot commits.

## Health

`:checkhealth xyno_history` reports the git version, the exit mode and the result of the last exit worker, the highlight groups (and whether it is new enough for the attribute source), whether `setup()` ran, the options, the secrets list in force, the retention, and for the current repository and every repository snapshotted in this session: the last snapshot, a current failure with its reason, the last failure, how many `refs/lochist` branches exist and how old the newest is, repository config that is being overridden, mirror remotes and the state of the push guard.

## Tests

```sh
nvim -l tests/run.lua                      # specs
nvim --headless -u NONE -i NONE -l scripts/bench.lua <repo>   # cost of a save; see How it works
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

## License

MIT, Copyright (c) 2026 Xynorash.
