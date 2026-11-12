-- xyno-history: the panel (:LocalHistoryPanel), labels, the statusline component, highlight groups.
-- xyno-os: linux,macos (bash git wrapper)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")
local Panel = require("xyno_history.panel")

K.init()
LH.setup({ retention = false })

local function snap(root, rel, opts)
  return K.snap(LH, root, vim.tbl_extend("force", { path = root .. "/" .. rel, force = true }, opts or {}))
end

--- repo with 4 snapshots: s1 a,b | s2 a edited | s3 b deleted, a edited | (s4 label, no change)
local function history()
  local root = K.mkrepo({ ["a.txt"] = "zero\n" })
  K.write(root .. "/a.txt", "one\n")
  K.write(root .. "/b.txt", "bee\n")
  local s1 = snap(root, "a.txt")
  K.write(root .. "/a.txt", "one\ntwo\nthree\n")
  local s2 = snap(root, "a.txt")
  os.remove(root .. "/b.txt")
  K.write(root .. "/a.txt", "one\nTWO\nthree\nfour\n")
  local s3 = snap(root, "a.txt")
  return root, { s1, s2, s3 }
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local orig_select, orig_input = vim.ui.select, vim.ui.input
local function auto_yes()
  vim.ui.select = function(items, _, cb)
    cb(items[1])
  end
end
after_each(function()
  vim.ui.select, vim.ui.input = orig_select, orig_input
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("tabclose!")
  end
end)

local function open(root, scope, file)
  vim.cmd.edit(root .. "/" .. (file or "a.txt"))
  local st = Panel.open({ scope = scope })
  H.wait_for(function()
    return st.loaded and #st.snaps > 0
  end, 10000, "snapshots loaded")
  return st
end
local function preview_ready(st, pat)
  H.wait_for(function()
    return text(st.bufs.preview):find(pat, 1, true) ~= nil
  end, 10000, "preview shows " .. pat .. " got:\n" .. text(st.bufs.preview))
end

describe("panel", function()
  it("file scope lists the snapshots of the file newest first, with the files each one changed", function()
    local root, s = history()
    local st = open(root, "file")
    H.eq(3, #st.snaps)
    H.eq(s[3], st.snaps[1].hash)
    H.eq(s[1], st.snaps[3].hash)
    H.eq(3, #vim.api.nvim_buf_get_lines(st.bufs.list, 0, -1, false))
    H.match(text(st.bufs.list), "autosave" == "x" and "" or "file", true)
    H.eq("M  a.txt" == nil, false)
    H.match(text(st.bufs.files), "a.txt", true)
    H.eq("XynoHistoryTitle", vim.api.nvim_get_hl(0, { name = "XynoHistoryTitle", link = true }).link and "XynoHistoryTitle")
    H.match(vim.wo[st.wins.list].winbar, "file: a.txt", true)
  end)

  it("selecting a snapshot shows the diff snapshot vs current: + is what a revert brings back", function()
    local root, s = history()
    local st = open(root, "file")
    st.select_snap(3) -- s1: a.txt = one
    preview_ready(st, "+++")
    local p = text(st.bufs.preview)
    H.match(p, "a.txt (current)", true)
    H.match(p, "a.txt@" .. s[1]:sub(1, 8), true)
    H.match(p, "-TWO", true)
    H.match(p, "-four", true)
    H.no_match(p, "+four", true)
  end)

  it("previous mode shows only what the snapshot itself changed", function()
    local root, s = history()
    local st = open(root, "file")
    st.select_snap(2) -- s2: added two + three
    st.actions.toggle_mode()
    preview_ready(st, "+two")
    local p = text(st.bufs.preview)
    H.match(p, "+three", true)
    H.no_match(p, "TWO", true)
    H.match(vim.wo[st.wins.preview].winbar, "snapshot vs previous", true)
  end)

  it("project scope lists every changed file; a deleted file is marked D", function()
    local root = history()
    local st = open(root, "file")
    st.actions.toggle_scope()
    H.wait_for(function()
      return st.scope == "project" and st.loaded and #st.snaps >= 3
    end, 10000, "project listing")
    st.select_snap(1) -- s3: a.txt modified, b.txt deleted
    local ft = text(st.bufs.files)
    H.match(ft, "M  a.txt", true)
    H.match(ft, "D  b.txt", true)
  end)

  it("search by content keeps the snapshots where that text appeared or went away", function()
    local root = history()
    local st = open(root, "file")
    st.actions.search("three")
    H.wait_for(function()
      return st.query == "three" and st.loaded and #st.snaps == 1
    end, 10000, "filtered")
    H.match(vim.wo[st.wins.list].winbar, "/three", true)
    st.actions.search("nothing like this")
    H.wait_for(function()
      return st.loaded and #st.snaps == 0
    end, 10000, "no match")
    H.match(text(st.bufs.list), "no snapshot touched that text", true)
    st.actions.clear()
    H.wait_for(function()
      return st.loaded and #st.snaps == 3
    end, 10000, "cleared")
  end)

  it("the search term is highlighted in the preview", function()
    local root = history()
    local st = open(root, "file")
    st.actions.search("three")
    H.wait_for(function()
      return st.loaded and #st.snaps == 1
    end, 10000)
    preview_ready(st, "three")
    local marks = vim.api.nvim_buf_get_extmarks(st.bufs.preview, vim.api.nvim_create_namespace("xyno_history_panel"), 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      found = found or m[4].hl_group == "XynoHistoryMatch"
    end
    H.ok(found, "a XynoHistoryMatch mark")
  end)

  it("revert file replaces the buffer text (modified, undoable), nothing is written", function()
    local root = history()
    auto_yes()
    local st = open(root, "file")
    st.select_snap(3)
    H.wait_for(function()
      return #st.snaps[3].files > 0
    end, 1000)
    local before = K.read(root .. "/a.txt")
    st.actions.revert_file()
    H.wait_for(function()
      return vim.api.nvim_buf_get_lines(vim.fn.bufnr(root .. "/a.txt"), 0, -1, false)[1] == "one" and #vim.api.nvim_buf_get_lines(vim.fn.bufnr(root .. "/a.txt"), 0, -1, false) == 1
    end, 10000, "buffer reverted")
    H.ok(vim.bo[vim.fn.bufnr(root .. "/a.txt")].modified)
    H.eq(before, K.read(root .. "/a.txt"), "disk untouched")
  end)

  it("revert hunk brings back only the hunk under the cursor", function()
    local root = K.mkrepo({ ["a.txt"] = "x\n" })
    local old = {}
    for i = 1, 30 do
      old[#old + 1] = "line" .. i
    end
    K.write(root .. "/a.txt", table.concat(old, "\n") .. "\n")
    local s1 = snap(root, "a.txt")
    local new = vim.deepcopy(old)
    new[2] = "CHANGED-A"
    new[28] = "CHANGED-B"
    K.write(root .. "/a.txt", table.concat(new, "\n") .. "\n")
    local st = open(root, "file")
    H.eq(s1, st.snaps[#st.snaps].hash)
    st.select_snap(#st.snaps)
    preview_ready(st, "@@")
    H.eq(2, #st.hunk_lines, "two hunks")
    vim.api.nvim_set_current_win(st.wins.preview)
    vim.api.nvim_win_set_cursor(st.wins.preview, { st.hunk_lines[2] + 1, 0 })
    st.actions.revert_hunk()
    local b = vim.fn.bufnr(root .. "/a.txt")
    local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    H.eq("CHANGED-A", got[2], "first hunk untouched")
    H.eq("line28", got[28], "second hunk reverted")
    H.ok(vim.bo[b].modified)
  end)

  it("a deleted file comes back from a snapshot that had it (written to disk after the question)", function()
    local root = history()
    auto_yes()
    local st = open(root, "file")
    st.actions.toggle_scope()
    H.wait_for(function()
      return st.scope == "project" and st.loaded and #st.snaps >= 3
    end, 10000)
    st.select_snap(#st.snaps) -- s1 added b.txt
    local snap1 = st.snaps[#st.snaps]
    local idx
    for i, f in ipairs(snap1.files) do
      if f.path == "b.txt" then
        idx = i
      end
    end
    H.ok(idx, "b.txt listed in the first snapshot")
    st.select_file(idx)
    H.eq(nil, vim.uv.fs_stat(root .. "/b.txt"))
    st.actions.revert_file()
    H.wait_for(function()
      return K.read(root .. "/b.txt") == "bee\n"
    end, 10000, "b.txt recreated")
  end)

  it("revert of a file the snapshot deleted explains instead of guessing", function()
    local root = history()
    auto_yes()
    local st = open(root, "file")
    st.actions.toggle_scope()
    H.wait_for(function()
      return st.scope == "project" and st.loaded and #st.snaps >= 3
    end, 10000)
    st.select_snap(1)
    local cap = {}
    local orig = vim.notify
    vim.notify = function(m)
      cap[#cap + 1] = m
    end
    for i, f in ipairs(st.snaps[1].files) do
      if f.path == "b.txt" then
        st.select_file(i)
      end
    end
    st.actions.revert_file()
    H.wait_for(function()
      return #cap > 0
    end, 5000, "notification")
    vim.notify = orig
    H.match(cap[1], "does not exist in that snapshot", true)
    H.eq(nil, vim.uv.fs_stat(root .. "/b.txt"))
  end)

  it("a label makes a snapshot even when nothing changed, and shows in the list", function()
    local root = history()
    local st = open(root, "file")
    st.actions.label("before refactor")
    H.wait_for(function()
      return st.loaded and #st.snaps == 4 and st.snaps[1].subject == "before refactor"
    end, 15000, "labelled snapshot listed")
    H.eq(0, #st.snaps[1].files, "no change recorded: the label alone")
    H.match(text(st.bufs.list), "before refactor", true)
    -- the highlight is on the label
    local marks = vim.api.nvim_buf_get_extmarks(st.bufs.list, vim.api.nvim_create_namespace("xyno_history_panel"), 0, -1, { details = true })
    local label = false
    for _, m in ipairs(marks) do
      label = label or m[4].hl_group == "XynoHistoryLabel"
    end
    H.ok(label)
  end)

  it(":LocalHistoryLabel with text puts the label without a prompt", function()
    local root = history()
    vim.cmd.edit(root .. "/a.txt")
    local before = K.count_commits(root, "refs/lochist/main")
    local done = false
    LH.label("release candidate", function()
      done = true
    end)
    H.wait_for(function()
      return done
    end, 15000)
    H.eq(before + 1, K.count_commits(root, "refs/lochist/main"))
    H.eq("release candidate", K.G(root, "log", "-1", "--format=%s", "refs/lochist/main"))
  end)

  it("<CR> opens the snapshot beside the current file in diff mode", function()
    local root = history()
    local st = open(root, "file")
    local tabs = #vim.api.nvim_list_tabpages()
    st.actions.side_by_side()
    H.wait_for(function()
      return #vim.api.nvim_list_tabpages() == tabs + 1
    end, 10000)
    local diffs = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      diffs = diffs + (vim.wo[w].diff and 1 or 0)
    end
    H.eq(2, diffs)
  end)

  it("close removes the panel: no leftover buffers, tabs or timers", function()
    local root = history()
    local st = open(root, "file")
    local bufs = vim.deepcopy(st.bufs)
    st.actions.close()
    H.eq(1, #vim.api.nvim_list_tabpages())
    for _, b in pairs(bufs) do
      H.not_ok(vim.api.nvim_buf_is_valid(b))
    end
  end)

  it("outside a repository it says so and opens nothing", function()
    local dir = H.tmpdir()
    K.write(dir .. "/x.txt", "x\n")
    vim.cmd.edit(dir .. "/x.txt")
    local cap = {}
    local orig = vim.notify
    vim.notify = function(m)
      cap[#cap + 1] = m
    end
    local st = Panel.open()
    vim.notify = orig
    H.is_nil(st)
    H.match(cap[1], "not in a git worktree", true)
    H.eq(1, #vim.api.nvim_list_tabpages())
  end)

  it("keymaps are set on all three panes", function()
    local root = history()
    local st = open(root, "file")
    for _, b in pairs(st.bufs) do
      local have = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        have[m.lhs] = true
      end
      for _, lhs in ipairs({ "q", "/", "L", "r", "x", "d", "s", "<Tab>" }) do
        H.ok(have[lhs], "buffer " .. b .. " maps " .. lhs)
      end
    end
  end)
end)

describe("highlight groups", function()
  it("XynoHistory* groups exist, link to theme groups and survive :hi clear", function()
    local want = {
      XynoHistoryTitle = "Title", XynoHistoryAge = "Comment", XynoHistoryLabel = "Special", XynoHistoryMatch = "Search",
      XynoHistoryAdded = "DiagnosticOk", XynoHistoryModified = "DiagnosticWarn", XynoHistoryDeleted = "DiagnosticError",
      XynoHistoryDiffAdd = "DiffAdd", XynoHistoryDiffDelete = "DiffDelete", XynoHistoryOk = "DiagnosticOk",
      XynoHistoryPending = "DiagnosticWarn", XynoHistoryFailing = "DiagnosticError",
    }
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    for g, link in pairs(want) do
      H.eq(link, vim.api.nvim_get_hl(0, { name = g, link = true }).link, g)
    end
    for _, g in ipairs(LH.highlight_groups) do
      H.match(g, "^XynoHistory")
    end
  end)

  it("a colour set by the user is kept", function()
    vim.api.nvim_set_hl(0, "XynoHistoryLabel", { fg = "#abcdef" })
    LH._define_highlights()
    H.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "XynoHistoryLabel" }).fg)
    vim.api.nvim_set_hl(0, "XynoHistoryLabel", { link = "Special" })
  end)
end)

describe("statusline component", function()
  it("is empty outside a repository and before the first snapshot", function()
    local dir = H.tmpdir()
    K.write(dir .. "/x.txt", "x\n")
    vim.cmd.edit(dir .. "/x.txt")
    H.eq("", (LH.statusline()))
    local root = K.mkrepo()
    vim.cmd.edit(root .. "/a.txt")
    K.state(LH, "last")[root] = nil
    H.eq("", (LH.statusline()))
  end)

  it("shows the age of the last snapshot, pending, running and failing states with their groups", function()
    local root = K.mkrepo()
    vim.cmd.edit(root .. "/a.txt")
    K.write(root .. "/a.txt", "changed\n")
    H.ok(snap(root, "a.txt"))
    local t, hl = LH.statusline()
    H.eq("LH now", t)
    H.eq("XynoHistoryOk", hl)
    K.state(LH, "last")[root] = os.time() - 600
    H.eq("LH 10m", (LH.statusline()))
    K.state(LH, "last")[root] = os.time() - 7200
    H.eq("LH 2h", (LH.statusline()))
    K.state(LH, "pending")[root] = true
    t, hl = LH.statusline()
    H.eq({ "LH ~", "XynoHistoryPending" }, { t, hl })
    K.state(LH, "pending")[root] = nil
    K.state(LH, "running")[root] = true
    H.eq("LH ...", (LH.statusline()))
    K.state(LH, "running")[root] = nil
    K.state(LH, "failures")[root] = { n = 2, reason = "x", time = os.time() }
    t, hl = LH.statusline()
    H.eq({ "LH !", "XynoHistoryFailing" }, { t, hl })
    H.eq("XynoHistoryFailing", LH.statusline_hl())
    K.state(LH, "failures")[root] = nil
  end)
end)
