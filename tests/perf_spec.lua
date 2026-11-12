-- Cost of a snapshot: after the first (full) scan of a session, saves take a fast path that does not walk the
-- worktree, and the exit snapshot uses it too.
-- xyno-os: linux,macos (bash git wrapper)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

local base = K.init()
LH.setup()
local uv = vim.uv
local time_offset = 0
do
  local real = os.time
  os.time = function(t)
    if t then
      return real(t)
    end
    return real() + time_offset
  end
  H._restore[#H._restore + 1] = function()
    os.time = real
  end
end

local function throttle_free(root)
  K.state(LH, "last")[root] = nil
  K.state(LH, "failed")[root] = nil
end

--- A snapshot the way a save triggers it (not forced); the throttle is lifted first.
local function save(root, rel)
  throttle_free(root)
  return K.snap(LH, root, { path = root .. "/" .. rel, force = false })
end

local function walks()
  return K.count("^ls%-files %-o") + K.count("^add %-A %-%-ignore%-errors %-%- %.")
end

before_each(function()
  LH.config.retention = false
  LH.config.full_scan_s = 300
  LH.config.exclude = nil
  time_offset = 0
  K.clear_log()
end)

describe("fast path", function()
  it("the first snapshot of a session walks the worktree; a following save does not (no ls-files -o, no add of '.')", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
    K.write(root .. "/a.txt", "a1\n")
    H.ok(save(root, "a.txt"))
    H.eq(1, K.count("^ls%-files %-o"), "first scan lists untracked files")
    H.eq(1, K.count("^add %-A %-%-ignore%-errors %-%- %."))
    K.clear_log()
    K.write(root .. "/a.txt", "a2\n")
    local c = save(root, "a.txt")
    H.ok(c)
    H.eq(0, walks(), "no directory walk on the fast path:\n" .. table.concat(K.log(), "\n"))
    H.eq(1, K.count("^diff%-files"))
    H.eq(1, K.count("^add %-A %-%-ignore%-errors %-%- :%(literal%)a%.txt"))
    H.eq("a2\n", K.blob(root, c, "a.txt"))
  end)

  it("a save that did not change anything makes no commit and walks nothing", function()
    local root = K.mkrepo()
    H.ok(save(root, "a.txt"))
    K.clear_log()
    H.is_nil(save(root, "a.txt"))
    H.eq(0, walks())
  end)

  it("picks up tracked files changed or deleted by something else (git diff-files) but not new files created behind its back", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n", ["c.txt"] = "c\n" })
    H.ok(save(root, "a.txt"))
    K.write(root .. "/b.txt", "b changed by an agent\n")
    os.remove(root .. "/c.txt")
    K.write(root .. "/new-by-agent.txt", "n\n")
    K.write(root .. "/a.txt", "a2\n")
    local c = save(root, "a.txt")
    H.ok(c)
    H.eq("b changed by an agent\n", K.blob(root, c, "b.txt"))
    H.is_nil(K.blob(root, c, "c.txt"), "deleted file is gone from the snapshot")
    H.is_nil(K.blob(root, c, "new-by-agent.txt"), "new files wait for the next full scan")
    -- a forced snapshot is a full scan and finds it
    local c2 = K.snap(LH, root)
    H.eq("n\n", K.blob(root, c2, "new-by-agent.txt"))
    H.ok(walks() >= 2)
  end)

  it("the saved file is snapshotted even when it is new and untracked", function()
    local root = K.mkrepo()
    H.ok(save(root, "a.txt"))
    K.write(root .. "/fresh.rs", "fn main() {}\n")
    local c = save(root, "fresh.rs")
    H.eq("fn main() {}\n", K.blob(root, c, "fresh.rs"))
  end)

  it("a saved file that .gitignore (or the secrets list) excludes stays out", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", [".gitignore"] = "*.log\n" })
    H.ok(save(root, "a.txt"))
    K.write(root .. "/x.log", "log\n")
    K.write(root .. "/.env", "S=1\n")
    K.write(root .. "/a.txt", "a2\n")
    throttle_free(root)
    K.snap(LH, root, { path = root .. "/x.log", force = false })
    throttle_free(root)
    local c = K.snap(LH, root, { path = root .. "/.env", force = false })
    local c2 = c or K.tip(root, "refs/lochist/main")
    local names = K.names(root, c2)
    H.not_ok(vim.tbl_contains(names, "x.log"))
    H.not_ok(vim.tbl_contains(names, ".env"))
  end)

  it("full_scan_s = 0 walks every time; an old full scan (> full_scan_s) is repeated", function()
    local root = K.mkrepo()
    LH.config.full_scan_s = 0
    H.ok(save(root, "a.txt"))
    K.write(root .. "/a.txt", "2\n")
    K.clear_log()
    H.ok(save(root, "a.txt"))
    H.eq(1, K.count("^ls%-files %-o"), "full_scan_s = 0 always scans")
    LH.config.full_scan_s = 300
    K.write(root .. "/a.txt", "3\n")
    H.ok(save(root, "a.txt")) -- the previous one was a full scan: this one is fast
    K.clear_log()
    K.write(root .. "/a.txt", "4\n")
    time_offset = 400
    H.ok(save(root, "a.txt"))
    H.eq(1, K.count("^ls%-files %-o"), "scan older than full_scan_s is repeated")
  end)

  it("a forced snapshot (the API, an agent hook) is always a full scan; the trailing snapshot is fast", function()
    local root = K.mkrepo()
    H.ok(save(root, "a.txt"))
    K.write(root .. "/a.txt", "2\n")
    K.clear_log()
    H.ok(K.snap(LH, root, { label = "before request" }))
    H.eq(1, K.count("^ls%-files %-o"))
    K.write(root .. "/a.txt", "3\n")
    K.clear_log()
    H.ok(K.snap(LH, root, { path = root .. "/a.txt", trailing = true }))
    H.eq(0, K.count("^ls%-files %-o"), "trailing = fast")
  end)

  it("more changed paths than the fast path handles (a checkout) fall back to a full scan", function()
    local files = {}
    for i = 1, 520 do
      files[("d/f%03d.txt"):format(i)] = "1\n"
    end
    local root = K.mkrepo(files)
    H.ok(save(root, "d/f001.txt"))
    for i = 1, 520 do
      K.write(root .. ("/d/f%03d.txt"):format(i), "2\n")
    end
    K.clear_log()
    local c = save(root, "d/f001.txt")
    H.ok(c)
    H.eq(1, K.count("^ls%-files %-o"), "fell back to the full scan")
    H.eq("2\n", K.blob(root, c, "d/f520.txt"))
  end)

  it("the fast and the full path give the same tree (a forced snapshot right after finds nothing new)", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", ["src/lib.rs"] = "1\n", [".gitignore"] = "*.tmp\n" })
    H.ok(save(root, "a.txt"))
    K.write(root .. "/src/lib.rs", "2\n")
    os.remove(root .. "/a.txt")
    K.write(root .. "/src/new.rs", "n\n")
    K.write(root .. "/ignored.tmp", "i\n")
    K.write(root .. "/src/new.rs", "n2\n")
    local fast = save(root, "src/new.rs")
    H.ok(fast)
    H.is_nil(K.snap(LH, root), "the full scan agrees with the fast one")
    H.eq(fast, K.tip(root, "refs/lochist/main"))
  end)

  it("the size cap applies on the fast path: a saved file that outgrew it is dropped from the snapshot", function()
    LH.config.max_bytes = 1024
    local root = K.mkrepo()
    K.write(root .. "/grow.txt", "small\n")
    H.ok(save(root, "grow.txt"))
    K.write(root .. "/grow.txt", string.rep("x", 4096))
    local c = save(root, "grow.txt")
    LH.config.max_bytes = nil
    H.ok(c)
    H.not_ok(vim.tbl_contains(K.names(root, c), "grow.txt"))
  end)

  it("never touches the real index and keeps using the private one", function()
    local root = K.mkrepo()
    K.G(root, "status", "--porcelain")
    local real = K.read(root .. "/.git/index")
    H.ok(save(root, "a.txt"))
    K.write(root .. "/a.txt", "2\n")
    H.ok(save(root, "a.txt"))
    H.eq(real, K.read(root .. "/.git/index"))
    local mine = root .. "/.git/lochist-index." .. uv.os_getpid()
    for _, l in ipairs(K.log()) do
      local idx, args = l:match("^(.-)\t(%S+)")
      if args == "add" or args == "write-tree" or args == "diff-files" then
        H.eq(mine, idx, args)
      end
    end
  end)
end)

local child_script = [[
package.path = vim.env.XYNO_REPO .. "/lua/?.lua;" .. vim.env.XYNO_REPO .. "/lua/?/init.lua;" .. package.path
local LH = require("xyno_history")
LH.setup({ retention = false, exit_mode = vim.env.XYNO_EXIT_MODE })
local root = vim.env.XYNO_ROOT
vim.cmd.edit(root .. "/f.txt")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "v1" })
vim.cmd.write()
vim.wait(20000, function() return vim.fn.system({ "git", "-C", root, "rev-parse", "-q", "--verify", "refs/lochist/main" }) ~= "" end, 20)
vim.wait(1500) -- let the snapshot finish and record its full scan
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "final" })
vim.cmd.write()
vim.cmd("qa!")
]]

describe("exit", function()
  it("exit_mode = sync: the exit snapshot after a recent full scan takes the fast path and records the final content", function()
    local root = K.mkrepo({ ["f.txt"] = "0\n", ["other.txt"] = "o\n" })
    K.write(base .. "/child.lua", child_script)
    K.clear_log()
    local t0 = uv.hrtime()
    local r = vim.system(
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-c", "luafile " .. base .. "/child.lua" },
      { env = { XYNO_REPO = H.repo, XYNO_ROOT = root, XYNO_EXIT_MODE = "sync" }, text = true }
    ):wait(60000)
    H.eq(0, r.code, r.stderr)
    H.eq("final\n", K.blob(root, "refs/lochist/main", "f.txt"))
    H.eq(2, K.count_commits(root, "refs/lochist/main"))
    H.eq(1, K.count("^ls%-files %-o"), "only the session's first scan walked the worktree")
    H.eq(1, K.count("^add %-A %-%-ignore%-errors %-%- %."))
    H.ok((uv.hrtime() - t0) / 1e6 < 15000)
  end)

  it("exit_budget_ms = 0 skips the exit snapshot", function()
    LH.config.exit_budget_ms = 0
    local root = K.mkrepo()
    local fired = false
    local snap = LH.snapshot
    LH.snapshot = function(...)
      fired = true
      return snap(...)
    end
    K.state(LH, "pending")[root] = true
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "xyno_history" })
    LH.snapshot = snap
    LH.config.exit_budget_ms = 5000
    H.not_ok(fired)
    K.state(LH, "pending")[root] = nil
  end)
end)

describe("exit, background worker", function()
  local function ncommits(root)
    local ok, n = pcall(K.count_commits, root, "refs/lochist/main")
    return ok and n or 0
  end
  local function workers(root) -- only this test's workers: their handoff file is in the test repo
    return vim.trim(vim.fn.system({ "pgrep", "-f", "exit_worker.lua " .. root }))
  end

  it("quitting hands the last save to a detached nvim: the final content is recorded after the editor is gone", function()
    local root = K.mkrepo({ ["f.txt"] = "0\n", ["other.txt"] = "o\n" })
    K.write(base .. "/child.lua", child_script)
    K.clear_log()
    local r = vim.system(
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-c", "luafile " .. base .. "/child.lua" },
      { env = { XYNO_REPO = H.repo, XYNO_ROOT = root, XYNO_EXIT_MODE = "background" }, text = true }
    ):wait(60000)
    H.eq(0, r.code, r.stderr)
    H.wait_for(function()
      return K.count_commits(root, "refs/lochist/main") == 2
    end, 20000, "the worker's snapshot")
    H.eq("final\n", K.blob(root, "refs/lochist/main", "f.txt"))
    H.eq(1, K.count("^ls%-files %-o"), "the worker took the fast path: no second walk of the worktree")
    H.wait_for(function()
      return workers(root) == ""
    end, 20000, "the worker exits by itself")
    local res = LH.last_exit(root)
    H.ok(res and res.ok, "result file: " .. vim.inspect(res))
    H.eq({}, vim.fn.glob(root .. "/.git/lochist-exit-*.json", true, true), "handoff file removed")
  end)

  it("the worker is started detached with a handoff file; nothing is snapshotted in the quitting nvim", function()
    local root = K.mkrepo({ ["f.txt"] = "0\n" })
    local spawned
    local real = vim.uv.spawn
    vim.uv.spawn = function(cmd, opts, cb)
      if cmd ~= vim.v.progpath then
        return real(cmd, opts, cb)
      end
      spawned = { cmd = cmd, opts = opts }
      return real("true", { args = {} }, cb)
    end
    K.clear_log()
    K.state(LH, "pending")[root] = true
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "xyno_history" })
    vim.uv.spawn = real
    H.ok(spawned, "spawn called")
    H.eq(true, spawned.opts.detached)
    H.eq(vim.v.progpath, spawned.cmd)
    H.match(spawned.opts.args[#spawned.opts.args - 1], "exit_worker.lua", true)
    local file = spawned.opts.args[#spawned.opts.args]
    local h = vim.json.decode(K.read(file))
    H.eq(root, h.root)
    H.eq(vim.uv.os_getpid(), h.parent)
    H.eq("off", h.config.exit_mode == "background" and "off" or "x")
    H.eq(0, K.count("^add"), "no git add here")
    os.remove(file)
    K.state(LH, "pending")[root] = nil
  end)

  it("falls back to the bounded synchronous snapshot when the worker cannot be started", function()
    local root = K.mkrepo({ ["f.txt"] = "0\n" })
    K.write(root .. "/f.txt", "changed\n")
    local real = vim.uv.spawn
    vim.uv.spawn = function(cmd, ...)
      if cmd == vim.v.progpath then
        return nil -- the worker cannot be started (git, started through vim.system, still can)
      end
      return real(cmd, ...)
    end
    K.state(LH, "pending")[root] = true
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "xyno_history" })
    vim.uv.spawn = real
    H.eq(1, ncommits(root), "recorded before VimLeavePre returned")
    H.eq("changed\n", K.blob(root, "refs/lochist/main", "f.txt"))
    H.eq({}, vim.fn.glob(root .. "/.git/lochist-exit-*.json", true, true), "stale handoff file removed")
  end)

  it('exit_mode = "off" takes no exit snapshot at all', function()
    LH.config.exit_mode = "off"
    local root = K.mkrepo()
    local fired = false
    local real = vim.uv.spawn
    vim.uv.spawn = function(cmd, ...)
      fired = fired or cmd == vim.v.progpath
      return real(cmd, ...)
    end
    K.state(LH, "pending")[root] = true
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "xyno_history" })
    vim.uv.spawn = real
    LH.config.exit_mode = "background"
    H.not_ok(fired)
    H.eq(0, ncommits(root))
    K.state(LH, "pending")[root] = nil
  end)

  it("exit_mode is validated", function()
    local cap = {}
    local orig = vim.notify
    vim.notify = function(m)
      cap[#cap + 1] = m
    end
    LH.setup({ exit_mode = "later" })
    vim.notify = orig
    H.match(cap[1], 'exit_mode must be "background", "sync" or "off"', true)
    H.eq("background", LH.config.exit_mode)
  end)
end)
