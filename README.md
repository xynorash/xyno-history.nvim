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
  commands = true,        -- :LocalHistory, :LocalHistoryRestore, :LocalHistoryPrune
  keymaps = false,        -- false | true | { browse = lhs, restore = lhs, prune = lhs }
  max_bytes = nil,        -- per-file cap in bytes (nil: 10 MB; <= 0: no cap)
  max_total_bytes = nil,  -- cap of one snapshot (nil: 200 MB; <= 0: none)
}
```

No global keymap is set by default. `keymaps = true` maps `<leader>gH` to `:LocalHistory`; a table maps each action to the key you choose.

## Commands

| Command | What it does |
| --- | --- |
| `:LocalHistory` | Pick a snapshot of the current file and diff against it in a vertical scratch buffer. |
| `:LocalHistoryRestore` | Pick a snapshot and replace the buffer text with it (buffer left modified, `u` undoes it; disk and index untouched). |
| `:LocalHistoryPrune[!] [N \| Nd]` | Keep the newest N snapshots per branch, or the last N days (default `30d`), then `git gc`. With `!`, collect every unreachable object (`--prune=now`). |

Lua: `require("xyno_history").snapshot({ path?, force?, label?, done? })`, `.browse()`, `.restore()`, `.prune(arg, now)`. See `:help xyno-history`.

## How it works

Each snapshot is a commit on `refs/lochist/<branch>` whose tree is the whole worktree: untracked files included, `.gitignore` respected, `target/` left out. It is built with a private index file per Neovim process (`.git/lochist-index.<pid>`) and a compare-and-swap `update-ref`, so concurrent instances never overwrite each other. Saves are throttled to one snapshot per minute and the last save of a window is never lost (a trailing snapshot, and one more on exit). Files over `max_bytes` stay out, and the largest files of a snapshot are dropped beyond `max_total_bytes`.

Without the plugin, the snapshots are plain git:

```sh
git log refs/lochist/main
git restore --source=refs/lochist/main --worktree -- path/to/file
```

They stay in the repository until pruned.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`, 65 tests, plus a lazy.nvim smoke test in CI). The specs use bash stubs and `kill -0`, so they run on Linux and macOS only.
- Windows: no evidence at all. In the original xynovim CI this code's spec was skipped on Windows, so nothing about it is demonstrated there.
- macOS: not tested here. In xynovim's CI the original spec was not skipped on macOS and ran in the one fully green macOS run; other macOS runs there were flaky or failed elsewhere, so I do not claim it works.

## Extracted from xynovim

This plugin is the Local History module of [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace, the `setup()` options and the git author name used for snapshot commits.

## Tests

```sh
nvim -l tests/run.lua                      # specs
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

## License

MIT, Copyright (c) 2026 Xynorash.
