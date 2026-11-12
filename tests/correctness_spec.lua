-- Correctness: rename tracking in :LocalHistory, restore fidelity (line endings, encoding, last newline),
-- visible snapshot failures, validated options.
-- xyno-os: linux,macos (bash git wrapper)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

K.init()
LH.setup()
local uv = vim.uv

local notes, restore_notify
local orig_select, sel_calls = vim.ui.select, {}
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

before_each(function()
  vim.cmd("silent! %bwipeout!")
  vim.cmd("enew")
  LH.config.retention = false
  LH.config.exclude = nil
  LH.config.list_limit = 100
  LH.config.throttle_s = 60
  LH.config.fail_backoff_s = 10
  time_offset = 0
  K.fail("add", false)
  K.fail("commit-tree", false)
  notes, restore_notify = K.capture_notify()
end)
after_each(function()
  restore_notify()
  vim.ui.select = orig_select
end)

local function mock_select(pick_fn)
  sel_calls = {}
  vim.ui.select = function(items, opts, cb)
    sel_calls[#sel_calls + 1] = { items = items, opts = opts }
    local idx = pick_fn(items, opts, #sel_calls)
    if idx then
      cb(items[idx], idx)
    else
      cb(nil)
    end
  end
end

local function open_file(root, rel)
  vim.cmd.cd(vim.fn.fnameescape(root))
  return H.open(root .. "/" .. rel)
end

local function wait_note(pat)
  H.wait_for(function()
    for _, n in ipairs(notes) do
      if n.msg:find(pat, 1, true) then
        return true
      end
    end
  end, 15000, "notification " .. pat)
end

-- ------------------------------------------------------------ rename tracking

describe("rename tracking", function()
  it(":LocalHistory follows a file across a rename and shows the old name; the old version can be opened", function()
    local root = K.mkrepo({ ["keep.txt"] = "k\n" })
    local body = {}
    for i = 1, 40 do
      body[i] = "line " .. i
    end
    local text = table.concat(body, "\n") .. "\n"
    K.write(root .. "/old_name.txt", text)
    local c1 = K.snap(LH, root)
    K.write(root .. "/old_name.txt", text .. "second\n")
    local c2 = K.snap(LH, root)
    os.remove(root .. "/old_name.txt")
    K.write(root .. "/new_name.txt", text .. "second\nthird\n")
    local c3 = K.snap(LH, root)
    H.ok(c1 and c2 and c3)
    open_file(root, "new_name.txt")
    mock_select(function()
      return 3 -- the oldest
    end)
    vim.cmd("LocalHistory")
    H.wait_for(function()
      return vim.api.nvim_buf_get_name(0):find("old_name.txt@", 1, true)
    end, 15000, "scratch buffer of the old name")
    local items = sel_calls[1].items
    H.eq(3, #items, "all three versions are listed, across the rename")
    H.match(sel_calls[1].opts.format_item(items[1]), "autosave", true)
    H.no_match(sel_calls[1].opts.format_item(items[1]), "[", true, "the newest has the current name")
    H.match(sel_calls[1].opts.format_item(items[3]), "[old_name.txt]", true)
    H.eq(text:gsub("\n$", ""), table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
  end)

  it(":LocalHistoryRestore restores the content a renamed file had under its old name", function()
    local root = K.mkrepo()
    local text = ("x\n"):rep(30) .. "unique\n"
    K.write(root .. "/before.txt", text)
    H.ok(K.snap(LH, root))
    os.remove(root .. "/before.txt")
    K.write(root .. "/after.txt", text .. "more\n")
    H.ok(K.snap(LH, root))
    local buf = open_file(root, "after.txt")
    local n = 0
    mock_select(function(_, opts)
      n = n + 1
      return n == 1 and 2 or 1 -- the older snapshot, then "Restore"
    end)
    vim.cmd("LocalHistoryRestore")
    H.wait_for(function()
      return vim.bo[buf].modified
    end, 15000, "restore")
    H.eq(text, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n")
  end)

  it("list_limit bounds the list", function()
    local root = K.mkrepo()
    for i = 1, 6 do
      K.write(root .. "/a.txt", "v" .. i .. "\n")
      H.ok(K.snap(LH, root))
    end
    open_file(root, "a.txt")
    LH.config.list_limit = 4
    mock_select(function()
      return nil
    end)
    vim.cmd("LocalHistory")
    H.wait_for(function()
      return #sel_calls > 0
    end, 15000, "picker")
    H.eq(4, #sel_calls[1].items)
  end)
end)

-- ---------------------------------------------------------- restore fidelity

local function restore_roundtrip(root, rel, setup_buf)
  -- snapshot of the file as it is on disk, then wreck the buffer, restore, write: the bytes must come back
  local path = root .. "/" .. rel
  local original = K.read(path)
  local c = K.snap(LH, root)
  H.ok(c)
  local buf = open_file(root, rel)
  if setup_buf then
    setup_buf(buf)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "wrecked" })
  vim.bo[buf].modified = true
  for i = #notes, 1, -1 do
    notes[i] = nil
  end
  local n = 0
  mock_select(function()
    n = n + 1
    return 1
  end)
  vim.cmd("LocalHistoryRestore")
  H.wait_for(function()
    for _, x in ipairs(notes) do
      if x.msg:find("restored ", 1, true) then
        return true
      end
    end
  end, 15000, "restore finished")
  vim.cmd("silent write")
  return original, K.read(path), buf
end

describe("restore fidelity", function()
  it("CRLF files come back with CRLF (and the buffer is fileformat=dos)", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/crlf.txt", "one\r\ntwo\r\nthree\r\n")
    -- the buffer was switched to unix endings meanwhile: the restore must bring dos back
    local original, after, buf = restore_roundtrip(root, "crlf.txt", function(b)
      vim.bo[b].fileformat = "unix"
    end)
    H.eq(original, after)
    H.eq("dos", vim.bo[buf].fileformat)
    H.eq({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("a file without a final newline comes back without one", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/nonl.txt", "no newline at the end")
    local original, after = restore_roundtrip(root, "nonl.txt")
    H.eq(original, after)
  end)

  it("a file with a final newline keeps it; an empty file stays empty", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/nl.txt", "a\nb\n")
    local o1, a1 = restore_roundtrip(root, "nl.txt")
    H.eq(o1, a1)
    K.write(root .. "/empty.txt", "")
    local o2, a2 = restore_roundtrip(root, "empty.txt")
    H.eq(o2, a2)
  end)

  it("mixed line endings are kept byte for byte", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/mixed.txt", "unix\ndos\r\nunix again\n")
    local o, a = restore_roundtrip(root, "mixed.txt")
    H.eq(o, a)
  end)

  it("a latin1 file is converted for the buffer and written back as latin1", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/l1.txt", "caf\233 cr\232me\n")
    local o, a, buf = restore_roundtrip(root, "l1.txt")
    H.eq("latin1", vim.bo[buf].fileencoding)
    H.eq(o, a)
    H.eq({ "café crème" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("UTF-8 with a BOM and UTF-16LE with a BOM round-trip", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/bom.txt", "\239\187\191hello\n")
    local o, a, buf = restore_roundtrip(root, "bom.txt")
    H.eq(o, a)
    H.ok(vim.bo[buf].bomb)
    local u16 = "\255\254" .. vim.iconv("h\195\169llo\n", "utf-8", "utf-16le")
    K.write(root .. "/u16.txt", u16)
    vim.opt_local.fileencodings = "ucs-bom,utf-8,latin1"
    local o2, a2, buf2 = restore_roundtrip(root, "u16.txt")
    H.eq("utf-16le", vim.bo[buf2].fileencoding)
    H.eq(o2, a2)
  end)

  it("a .gitattributes with eol/text rules does not change the stored bytes", function()
    local root = K.mkrepo({ ["x.txt"] = "x\n" })
    K.write(root .. "/.gitattributes", "*.txt text eol=lf\n*.bat text eol=crlf\n")
    K.write(root .. "/run.bat", "echo a\r\necho b\r\n")
    K.write(root .. "/mixed.txt", "a\r\nb\r\n")
    local c = K.snap(LH, root)
    H.eq("echo a\r\necho b\r\n", K.blob(root, c, "run.bat"))
    H.eq("a\r\nb\r\n", K.blob(root, c, "mixed.txt"))
  end)

  it(
    "a snapshot that cannot be converted is not restored (an unknown fileencoding is an error, not garbage)",
    function()
      local b = vim.api.nvim_create_buf(false, true)
      vim.bo[b].fileencoding = "no-such-encoding"
      local lines, err = LH._decode("abc\n", b)
      H.is_nil(lines)
      H.match(err, "cannot convert", true)
    end
  )
end)

-- --------------------------------------------------------- visible failures

describe("snapshot failures are visible", function()
  it("a persistent failure notifies once with the reason, then stays quiet; the status keeps it", function()
    local root = K.mkrepo()
    K.fail("add")
    H.is_nil(K.snap(LH, root))
    H.eq(0, #notes, "one failure may be a blip that the retry fixes")
    H.is_nil(K.snap(LH, root))
    H.eq(1, #notes)
    H.eq(vim.log.levels.WARN, notes[1].level)
    H.match(notes[1].msg, "local history", true)
    H.match(notes[1].msg, "git add failed", true)
    H.match(notes[1].msg, "injected failure", true)
    H.match(notes[1].msg, ":checkhealth xyno_history", true)
    H.is_nil(K.snap(LH, root))
    H.eq(1, #notes, "no repeat while it keeps failing")
    local st = LH.status()[root]
    H.eq(3, st.failing.n)
    H.match(st.failing.reason, "injected failure", true)
  end)

  it(
    "recovery clears the failing state, keeps the last failure for the health report, and a new episode notifies again",
    function()
      local root = K.mkrepo()
      K.fail("commit-tree")
      K.snap(LH, root)
      K.snap(LH, root)
      H.eq(1, #notes)
      H.match(notes[1].msg, "git commit-tree failed", true)
      K.fail("commit-tree", false)
      H.ok(K.snap(LH, root))
      local st = LH.status()[root]
      H.is_nil(st.failing)
      H.match(st.last_failure.reason, "commit-tree", true)
      K.fail("commit-tree")
      K.write(root .. "/a.txt", "2\n")
      K.snap(LH, root)
      K.snap(LH, root)
      H.eq(2, #notes, "second episode")
      K.fail("commit-tree", false)
    end
  )

  it("a git that cannot even find the repository is reported with git's own message", function()
    local root = K.mkrepo()
    K.fail("rev-parse")
    K.snap(LH, root)
    K.snap(LH, root)
    K.fail("rev-parse", false)
    H.eq(1, #notes)
    H.match(notes[1].msg, "git rev-parse failed", true)
  end)

  it("a failed snapshot keeps the saved paths for the retry", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
    H.ok(K.snap(LH, root))
    K.write(root .. "/new.txt", "n\n")
    K.fail("add")
    K.state(LH, "last")[root] = nil
    K.snap(LH, root, { path = root .. "/new.txt", force = false })
    K.fail("add", false)
    local pend = K.state(LH, "touched")[root]
    H.ok(pend and pend["new.txt"], "new.txt is still pending")
    K.state(LH, "failed")[root] = nil
    local c = K.snap(LH, root, { path = root, force = false, trailing = true })
    H.eq("n\n", K.blob(root, c, "new.txt"))
  end)
end)

-- ------------------------------------------------------------------- options

describe("validated options", function()
  local defaults = { throttle_s = 60, fail_backoff_s = 10, exit_budget_ms = 5000, full_scan_s = 300, list_limit = 100 }

  it("defaults are exposed in M.config", function()
    local fresh = dofile(H.repo .. "/lua/xyno_history/init.lua")
    for k, v in pairs(defaults) do
      H.eq(v, fresh.config[k], k)
    end
    H.eq({ auto = true, max_count = 1000, max_age_days = 30, interval_h = 6 }, fresh.config.retention)
  end)

  it("bad values are reported in ONE message and the default is used", function()
    LH.setup({
      throttle_s = -5,
      fail_backoff_s = "ten",
      list_limit = 0,
      exit_budget_ms = 1e9,
      full_scan_s = 0 / 0,
      bogus = true,
    })
    H.eq(1, #notes)
    local m = notes[1].msg
    for _, frag in ipairs({
      "throttle_s",
      "fail_backoff_s",
      "list_limit",
      "exit_budget_ms",
      "full_scan_s",
      'unknown option "bogus"',
    }) do
      H.match(m, frag, true)
    end
    H.eq(vim.log.levels.WARN, notes[1].level)
    for k, v in pairs(defaults) do
      H.eq(v, LH.config[k], k)
    end
    LH.setup()
  end)

  it("good values are taken", function()
    LH.setup({ throttle_s = 5, fail_backoff_s = 2, list_limit = 7, full_scan_s = 0, exit_budget_ms = 100 })
    H.eq(0, #notes)
    H.eq({ 5, 2, 7, 0, 100 }, {
      LH.config.throttle_s,
      LH.config.fail_backoff_s,
      LH.config.list_limit,
      LH.config.full_scan_s,
      LH.config.exit_budget_ms,
    })
    LH.setup({ throttle_s = 60, fail_backoff_s = 10, list_limit = 100, full_scan_s = 300, exit_budget_ms = 5000 })
  end)

  it("a bad value written straight into M.config falls back to the default instead of breaking the loop", function()
    local root = K.mkrepo()
    LH.config.throttle_s = "soon"
    LH.config.fail_backoff_s = -1
    H.ok(K.snap(LH, root, { force = false }))
    K.write(root .. "/a.txt", "2\n")
    LH.snapshot({ path = root })
    H.eq(true, K.state(LH, "pending")[root], "throttled with the default 60 s")
    LH.config.throttle_s = 60
    LH.config.fail_backoff_s = 10
  end)

  it("throttle_s is honoured (0 snapshots on every save)", function()
    local root = K.mkrepo()
    LH.config.throttle_s = 0
    H.ok(K.snap(LH, root, { force = false }))
    K.write(root .. "/a.txt", "2\n")
    local c = K.snap(LH, root, { force = false, path = root .. "/a.txt" })
    H.ok(c, "no wait")
    LH.config.throttle_s = 60
    K.write(root .. "/a.txt", "3\n")
    K.state(LH, "last")[root] = os.time()
    LH.snapshot({ path = root .. "/a.txt" })
    H.eq(true, K.state(LH, "pending")[root])
    for _, t in pairs(K.state(LH, "timers")) do
      pcall(function()
        t:stop()
      end)
    end
  end)

  it("fail_backoff_s delays the retry after a failure", function()
    local root = K.mkrepo()
    LH.config.fail_backoff_s = 30
    K.state(LH, "failed")[root] = os.time()
    K.state(LH, "last")[root] = nil
    local nxt = K.state(LH, "next_ok")(root)
    H.ok(nxt >= os.time() + 29, "next try in 30 s")
    LH.config.fail_backoff_s = 10
    K.state(LH, "failed")[root] = nil
  end)

  it("retention options are validated", function()
    LH.setup({ retention = { max_count = 0, max_age_days = "x", interval_h = 2, extra = 1 } })
    H.eq(1, #notes)
    H.match(notes[1].msg, "retention.max_count", true)
    H.match(notes[1].msg, "retention.max_age_days", true)
    H.match(notes[1].msg, "retention.extra", true)
    H.eq({ auto = true, max_count = 1000, max_age_days = 30, interval_h = 2 }, LH.config.retention)
    LH.setup({ retention = { max_age_days = false } })
    H.eq(false, LH.config.retention.max_age_days)
    LH.setup({ retention = {} })
    H.eq(30, LH.config.retention.max_age_days)
  end)
end)
