-- Retention: old snapshots are pruned automatically (count and age, defaults 1000 / 30 days) in the
-- background, and :LocalHistoryPrune never blocks the editor.
-- xyno-os: linux,macos (bash git wrapper)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

K.init()
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

local notes, restore_notify
before_each(function()
  LH.config.exclude = nil
  LH.config.retention = { auto = true, max_count = 1000, max_age_days = 30, interval_h = 6 }
  time_offset = 120 -- past the first minute of the "session"
  K.clear_log()
  vim.fn.delete(K.base .. "/delay.log")
  vim.fn.delete(K.base .. "/delay.fast-import")
  notes, restore_notify = K.capture_notify()
end)
after_each(function()
  restore_notify()
end)

--- commits on `ref` (oldest first) via fast-import: items = { {days = age, content = ...} }
local function chain(root, ref, items)
  local now = os.time()
  local s = {}
  for i, it in ipairs(items) do
    local msg = it.msg or ("snap" .. i)
    s[#s + 1] = ("commit %s\nmark :%d\ncommitter xyno-history <lochist@xyno-history> %d +0000\ndata %d\n%s\n"):format(
      ref,
      i,
      now - (it.days or 0) * 86400,
      #msg,
      msg
    )
    if i > 1 then
      s[#s + 1] = ("from :%d\n"):format(i - 1)
    end
    s[#s + 1] = ("M 100644 inline f.txt\ndata %d\n%s\n\n"):format(#it.content, it.content)
  end
  local r = K.run(root, { "fast-import", "--quiet" }, table.concat(s))
  H.eq(0, r.code, r.stderr)
end

local function count(root)
  return K.count_commits(root, "refs/lochist/main")
end

local function aged(n_old, n_new)
  local items = {}
  for i = 1, n_old do
    items[#items + 1] = { days = 60 - i, content = "old " .. i .. "\n" }
  end
  for i = 1, n_new do
    items[#items + 1] = { days = 0, content = "new " .. i .. "\n" }
  end
  return items
end

describe("automatic retention", function()
  it("after a snapshot, snapshots older than max_age_days are dropped in the background", function()
    local root = K.mkrepo()
    chain(root, "refs/lochist/main", aged(5, 3))
    K.write(root .. "/a.txt", "changed\n")
    H.ok(K.snap(LH, root))
    H.wait_for(function()
      return count(root) == 4
    end, 20000, "3 young + the new snapshot")
    H.ok(uv.fs_stat(root .. "/.git/lochist-prune-stamp"), "stamp written")
    H.eq(0, #notes, "automatic pruning is quiet")
  end)

  it("max_count keeps the newest N per branch", function()
    local root = K.mkrepo()
    LH.config.retention = { auto = true, max_count = 4 }
    chain(root, "refs/lochist/main", aged(0, 12))
    K.write(root .. "/a.txt", "changed\n")
    H.ok(K.snap(LH, root))
    H.wait_for(function()
      return count(root) == 4
    end, 20000, "pruned to 4")
    H.match(K.blob(root, "refs/lochist/main", "a.txt"), "changed", true)
  end)

  it("runs once per interval: a second snapshot does not prune again, a stale stamp does", function()
    local root = K.mkrepo()
    chain(root, "refs/lochist/main", aged(5, 1))
    K.write(root .. "/a.txt", "1\n")
    H.ok(K.snap(LH, root))
    H.wait_for(function()
      return count(root) == 2
    end, 20000, "first prune")
    H.eq(1, K.count("^fast%-import"))
    chain(root, "refs/lochist/main", aged(0, 0)) -- (no-op helper call keeps the log readable)
    K.write(root .. "/a.txt", "2\n")
    H.ok(K.snap(LH, root))
    vim.wait(800)
    H.eq(1, K.count("^fast%-import"), "interval not over")
    local old = os.time() - 7 * 3600
    uv.fs_utime(root .. "/.git/lochist-prune-stamp", old, old)
    K.state(LH, "autopruned")[root] = nil
    K.write(root .. "/a.txt", "3\n")
    H.ok(K.snap(LH, root))
    vim.wait(1500)
    H.eq(1, K.count("^fast%-import"), "nothing old left to drop: no second rewrite")
    H.ok(uv.fs_stat(root .. "/.git/lochist-prune-stamp").mtime.sec >= os.time() - time_offset - 60, "stamp renewed")
  end)

  it("retention = false, auto = false and the first minute of a session do nothing", function()
    local root = K.mkrepo()
    chain(root, "refs/lochist/main", aged(5, 1))
    LH.config.retention = false
    K.write(root .. "/a.txt", "1\n")
    H.ok(K.snap(LH, root))
    LH.config.retention = { auto = false }
    K.write(root .. "/a.txt", "2\n")
    H.ok(K.snap(LH, root))
    time_offset = 0
    LH.config.retention = { auto = true }
    K.write(root .. "/a.txt", "3\n")
    H.ok(K.snap(LH, root))
    vim.wait(1000)
    H.eq(9, count(root))
    H.eq(0, K.count("^fast%-import"))
  end)

  it("never drops the newest snapshot, and max_age_days = false keeps by count only", function()
    local root = K.mkrepo()
    LH.config.retention = { auto = true, max_age_days = false, max_count = 3 }
    chain(root, "refs/lochist/main", aged(8, 0))
    K.write(root .. "/a.txt", "1\n")
    H.ok(K.snap(LH, root))
    H.wait_for(function()
      return count(root) == 3
    end, 20000, "by count only")
  end)
end)

describe(":LocalHistoryPrune does not block the editor", function()
  it("returns at once while git works, the result arrives as a notification, the event loop keeps running", function()
    local root = K.mkrepo()
    chain(root, "refs/lochist/main", aged(0, 6))
    K.delay("log", 1)
    K.delay("fast-import", 1)
    vim.cmd.cd(vim.fn.fnameescape(root))
    vim.cmd("enew")
    local t0 = uv.hrtime()
    vim.cmd("LocalHistoryPrune 2")
    local ms = (uv.hrtime() - t0) / 1e6
    H.ok(ms < 300, ("the command blocked for %d ms"):format(ms))
    local ticks = 0
    local timer = uv.new_timer()
    timer:start(0, 50, function()
      ticks = ticks + 1
    end)
    H.wait_for(function()
      for _, n in ipairs(notes) do
        if n.msg:find("git gc done", 1, true) then
          return true
        end
      end
    end, 60000, "prune finished")
    timer:stop()
    timer:close()
    H.ok(ticks >= 10, "the event loop ran while git worked: " .. ticks)
    H.eq(2, count(root))
  end)
end)
