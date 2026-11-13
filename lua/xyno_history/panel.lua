-- The Local History panel (:LocalHistoryPanel): snapshots on the left, the files each one changed below
-- them, a diff preview on the right. Modelled on what JetBrains' Local History offers (revision list with
-- labels, diff against the current state, revert of a file or of one hunk, deleted files, a search
-- over content) and not affiliated with it.
--
--   list pane   one line per snapshot: time, label (or "auto"), number of files it changed
--   files pane  the files that snapshot changed (A/M/D/R), or the one file in file scope
--   preview     diff between the current text and that snapshot ("current": + is what a revert brings back,
--               - what it removes) or between the snapshot and its predecessor ("previous")
local M = {}

local LH = require("xyno_history")
local api = vim.api
local NS = api.nvim_create_namespace("xyno_history_panel")

local MAX_BLOB = 2 * 1024 * 1024
local MAX_FILES = 2000

local HINTS =
  " q close  <Tab> pane  / search  c clear  L label  d mode  s scope  r revert file  x revert hunk  <CR> diff  gr refresh  y yank"

-- ------------------------------------------------------------------ helpers

local function rel_time(at)
  local d = os.time() - at
  if d < 60 then
    return "now"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m ago"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h ago"
  end
  return os.date("%d %b %H:%M", at)
end

local function stat_group(status)
  local c = status:sub(1, 1)
  return c == "A" and "XynoHistoryAdded"
    or c == "D" and "XynoHistoryDeleted"
    or (c == "R" or c == "C") and "XynoHistoryRenamed"
    or "XynoHistoryModified"
end

local function unquote(path)
  if path:sub(1, 1) ~= '"' then
    return path
  end
  return (
    path
      :sub(2, -2)
      :gsub("\\(%d%d%d)", function(o)
        return string.char(tonumber(o, 8))
      end)
      :gsub("\\(.)", { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\" })
  )
end

local function scratch(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "xynohistory"
  vim.bo[buf].modifiable = false
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

-- ------------------------------------------------------------------- parsing

--- `git log --name-status -z --format=%x01%H%x09%at%x09%s` output -> snapshots
local function parse(out)
  local snaps = {}
  for rec in (out or ""):gmatch("\1([^\1]+)") do
    local f = vim.split(rec, "\0", { plain = true })
    local hash, at, subject = unpack(vim.split(f[1], "\t", { plain = true }))
    if hash then
      local snap = { hash = hash, at = tonumber(at) or 0, subject = subject or "", files = {}, nfiles = 0 }
      local i = 2
      while i <= #f do
        local status = (f[i] or ""):gsub("^%s+", "")
        if status == "" then
          break
        end
        local first = status:sub(1, 1)
        local path, old = f[i + 1], nil
        i = i + 2
        if first == "R" or first == "C" then
          old, path = path, f[i]
          i = i + 1
        end
        if path and path ~= "" then
          snap.nfiles = snap.nfiles + 1
          if #snap.files < MAX_FILES then
            snap.files[#snap.files + 1] = { status = first, path = unquote(path), old = old and unquote(old) or nil }
          end
        end
      end
      snaps[#snaps + 1] = snap
    end
  end
  return snaps
end

-- --------------------------------------------------------------- the panel

--- Open the panel.
--- @param opts? { scope?: "file"|"project", path?: string }
--- @return table? state nil when the file is not in a git worktree (st.actions are the key actions, for scripts and tests)
function M.open(opts)
  opts = opts or {}
  local origin = api.nvim_get_current_buf()
  local name = opts.path or api.nvim_buf_get_name(origin)
  local root = vim.fs.root(name ~= "" and name or vim.uv.cwd(), ".git")
  if not root then
    vim.notify("local history: not in a git worktree", vim.log.levels.WARN)
    return
  end
  local file_rel = name ~= "" and vim.fs.relpath(root, name) or nil
  if file_rel == "." then
    file_rel = nil
  end
  local st = {
    root = root,
    scope = (opts.scope == "project" or not file_rel) and "project" or "file",
    file = file_rel,
    origin = origin,
    mode = "current",
    snaps = {},
    sel = 1,
    fsel = 1,
    query = nil,
    gen = 0,
    loaded = false,
  }

  api.nvim_command("tabnew")
  st.tab = api.nvim_get_current_tabpage()
  st.wins = { list = api.nvim_get_current_win() }
  st.bufs = { list = api.nvim_get_current_buf() }
  vim.bo[st.bufs.list].buftype, vim.bo[st.bufs.list].bufhidden, vim.bo[st.bufs.list].swapfile = "nofile", "wipe", false
  vim.bo[st.bufs.list].filetype = "xynohistory"
  vim.bo[st.bufs.list].modifiable = false
  st.bufs.files = scratch("")
  st.bufs.preview = scratch("")
  api.nvim_command("belowright vertical split")
  st.wins.preview = api.nvim_get_current_win()
  api.nvim_win_set_buf(st.wins.preview, st.bufs.preview)
  api.nvim_set_current_win(st.wins.list)
  api.nvim_command("belowright split")
  st.wins.files = api.nvim_get_current_win()
  api.nvim_win_set_buf(st.wins.files, st.bufs.files)
  api.nvim_win_set_width(st.wins.list, 46)
  api.nvim_win_set_height(st.wins.files, math.max(6, math.floor(vim.o.lines * 0.33)))
  for key, win in pairs(st.wins) do
    local wo = vim.wo[win]
    wo.wrap, wo.number, wo.relativenumber, wo.signcolumn, wo.foldenable = false, false, false, "no", false
    wo.cursorline = key ~= "preview"
    wo.winhighlight = "CursorLine:XynoHistorySelected"
    wo.statusline = " "
  end

  local actions = {}
  st.actions = actions

  -- ---- winbars
  local function bars()
    local scope = st.scope == "file" and ("file: " .. (st.file or "?")) or "project"
    local q = st.query and ("  /" .. st.query) or ""
    vim.wo[st.wins.list].winbar = ("%%#XynoHistoryTitle# Local history · %s%%#XynoHistoryMatch#%s%%*"):format(
      esc(scope),
      esc(q)
    )
    local snap = st.snaps[st.sel]
    vim.wo[st.wins.files].winbar = "%#XynoHistoryTitle# Changed files"
      .. (
        snap
          and ("%#XynoHistoryAge# " .. esc(snap.hash:sub(1, 8)) .. (snap.nfiles > #snap.files and (" (first " .. #snap.files .. " of " .. snap.nfiles .. ")") or ""))
        or ""
      )
    vim.wo[st.wins.preview].winbar = ("%%#XynoHistoryTitle# Diff · %s"):format(
      st.mode == "current" and "snapshot vs current" or "snapshot vs previous"
    )
    vim.wo[st.wins.preview].statusline = "%#XynoHistoryHint#" .. esc(HINTS)
  end

  -- ---- rendering
  local function render_list()
    local lines, marks = {}, {}
    if #st.snaps == 0 then
      lines[1] = st.loaded and (st.query and "  no snapshot touched that text" or "  no local history yet")
        or "  loading..."
    end
    for i, s in ipairs(st.snaps) do
      local auto = s.subject == "autosave" or s.subject == ""
      local t = rel_time(s.at)
      local label = auto and "·" or s.subject
      local line = ("  %-9s %s"):format(t, label)
      local count = ("  %d file%s"):format(s.nfiles, s.nfiles == 1 and "" or "s")
      lines[i] = line .. count
      marks[#marks + 1] = { i - 1, 2, 2 + #t, "XynoHistoryAge" }
      if not auto then
        marks[#marks + 1] = { i - 1, 12, 12 + #label, "XynoHistoryLabel" }
      end
      marks[#marks + 1] = { i - 1, #line, #lines[i], "XynoHistoryAge" }
    end
    set_lines(st.bufs.list, lines)
    api.nvim_buf_clear_namespace(st.bufs.list, NS, 0, -1)
    for _, m in ipairs(marks) do
      pcall(api.nvim_buf_set_extmark, st.bufs.list, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end

  local function render_files()
    local snap = st.snaps[st.sel]
    local lines, marks = {}, {}
    if not snap then
      lines[1] = ""
    else
      for i, f in ipairs(snap.files) do
        local shown = f.old and (f.old .. " -> " .. f.path) or f.path
        lines[i] = ("  %s  %s"):format(f.status, shown)
        marks[#marks + 1] = { i - 1, 2, 3, stat_group(f.status) }
      end
      if #lines == 0 then
        lines[1] = "  (no file changes recorded)"
      end
    end
    set_lines(st.bufs.files, lines)
    api.nvim_buf_clear_namespace(st.bufs.files, NS, 0, -1)
    for _, m in ipairs(marks) do
      pcall(api.nvim_buf_set_extmark, st.bufs.files, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end

  local function selected_file()
    local snap = st.snaps[st.sel]
    return snap and snap.files[st.fsel], snap
  end

  local function abs(rel)
    return st.root .. "/" .. rel
  end

  --- Lines of the current state of `rel` (the buffer when loaded, else the disk), nil when it is gone.
  local function current_lines(rel)
    local b = vim.fn.bufnr(abs(rel))
    if b > 0 and api.nvim_buf_is_loaded(b) then
      return api.nvim_buf_get_lines(b, 0, -1, false), b
    end
    local f = io.open(abs(rel), "rb")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    if text:find("\0", 1, true) then
      return nil, nil, "binary"
    end
    return (LH._decode(text, nil)), nil
  end

  local function blob(commit, path, cb)
    LH._git({ "cat-file", "blob", commit .. ":" .. path }, st.root, function(content)
      cb(content)
    end, true)
  end

  local function show_preview(lines, marks)
    set_lines(st.bufs.preview, lines)
    api.nvim_buf_clear_namespace(st.bufs.preview, NS, 0, -1)
    for _, m in ipairs(marks or {}) do
      pcall(api.nvim_buf_set_extmark, st.bufs.preview, NS, m[1], m[2] or 0, m[3])
    end
    pcall(api.nvim_win_set_cursor, st.wins.preview, { 1, 0 })
  end

  local function unified(a_lines, b_lines, title_a, title_b)
    local a = #a_lines > 0 and (table.concat(a_lines, "\n") .. "\n") or ""
    local b = #b_lines > 0 and (table.concat(b_lines, "\n") .. "\n") or ""
    local out = {}
    local marks = {}
    out[1] = "--- " .. title_a
    out[2] = "+++ " .. title_b
    marks[1] = { 0, 0, { line_hl_group = "XynoHistoryDiffDelete" } }
    marks[2] = { 1, 0, { line_hl_group = "XynoHistoryDiffAdd" } }
    local hunk_lines = {}
    local text = vim.diff(a, b, { result_type = "unified", ctxlen = 3, algorithm = "histogram" })
    if text == "" then
      out[#out + 1] = ""
      out[#out + 1] = "  identical"
      return out, marks, {}, {}
    end
    local indices = vim.diff(a, b, { result_type = "indices", algorithm = "histogram" })
    for _, l in ipairs(vim.split(text:gsub("\n$", ""), "\n", { plain = true })) do
      out[#out + 1] = l
      local c = l:sub(1, 1)
      if l:sub(1, 2) == "@@" then
        hunk_lines[#hunk_lines + 1] = #out
        marks[#marks + 1] = { #out - 1, 0, { line_hl_group = "XynoHistoryDiffHunk" } }
      elseif c == "+" then
        marks[#marks + 1] = { #out - 1, 0, { line_hl_group = "XynoHistoryDiffAdd" } }
      elseif c == "-" then
        marks[#marks + 1] = { #out - 1, 0, { line_hl_group = "XynoHistoryDiffDelete" } }
      end
    end
    return out, marks, hunk_lines, indices
  end

  local function highlight_query(lines, marks)
    if not st.query or st.query == "" then
      return
    end
    for i, l in ipairs(lines) do
      if i > 2 then
        local from = 1
        while true do
          local a, b = l:find(st.query, from, true)
          if not a then
            break
          end
          marks[#marks + 1] = { i - 1, a - 1, { end_col = b, hl_group = "XynoHistoryMatch", priority = 200 } }
          from = b + 1
        end
      end
    end
  end

  local preview_gen = 0
  local function render_preview()
    preview_gen = preview_gen + 1
    local my = preview_gen
    st.hunks, st.hunk_lines, st.preview_ctx = nil, nil, nil
    local f, snap = selected_file()
    if not f then
      return show_preview({ "", "  nothing to show" })
    end
    local short = snap.hash:sub(1, 8)
    local path_at = f.path
    if st.mode == "previous" then
      blob(snap.hash .. "^", f.old or f.path, function(prev)
        blob(snap.hash, path_at, function(now)
          if my ~= preview_gen then
            return
          end
          if (prev and prev:find("\0", 1, true)) or (now and now:find("\0", 1, true)) then
            return show_preview({ "", "  binary file" })
          end
          local a = prev and (LH._decode(prev, nil)) or {}
          local b = now and (LH._decode(now, nil)) or {}
          local out, marks = unified(a, b, (f.old or f.path) .. "@previous", path_at .. "@" .. short)
          highlight_query(out, marks)
          show_preview(out, marks)
        end)
      end)
      return
    end
    local cur_path = (st.scope == "file" and st.file) or f.path
    blob(snap.hash, path_at, function(content)
      if my ~= preview_gen then
        return
      end
      local b_lines = {}
      if content then
        if content:find("\0", 1, true) then
          return show_preview({ "", "  binary file" })
        end
        if #content > MAX_BLOB then
          return show_preview({ "", ("  %d bytes: too big to preview"):format(#content) })
        end
        local buf = vim.fn.bufnr(abs(cur_path))
        b_lines = LH._decode(content, buf > 0 and buf or nil) or {}
      end
      local a_lines, bufnr, why = current_lines(cur_path)
      if why == "binary" then
        return show_preview({ "", "  binary file" })
      end
      local title_b = ("%s@%s%s"):format(path_at, short, content and "" or " (not in this snapshot)")
      local out, marks, hunk_lines, indices =
        unified(a_lines or {}, b_lines, cur_path .. (a_lines and " (current)" or " (deleted)"), title_b)
      st.hunks, st.hunk_lines = indices, hunk_lines
      st.preview_ctx = {
        path = cur_path,
        snap = snap,
        b_lines = b_lines,
        have_current = a_lines ~= nil,
        bufnr = bufnr,
        in_snapshot = content ~= nil,
      }
      highlight_query(out, marks)
      show_preview(out, marks)
    end)
  end

  local function select_snap(i)
    if #st.snaps == 0 then
      st.sel = 1
      render_files()
      bars()
      return render_preview()
    end
    st.sel = math.max(1, math.min(i, #st.snaps))
    st.fsel = 1
    render_files()
    bars()
    render_preview()
  end

  local function select_file(i)
    local snap = st.snaps[st.sel]
    if not snap or #snap.files == 0 then
      return
    end
    st.fsel = math.max(1, math.min(i, #snap.files))
    render_preview()
  end

  -- ---- loading
  local function load(keep)
    st.gen = st.gen + 1
    local my = st.gen
    st.loaded = false
    LH._refs(st.root, function(refs)
      if my ~= st.gen then
        return
      end
      if #refs == 0 then
        st.snaps, st.loaded = {}, true
        render_list()
        return select_snap(1)
      end
      local args = vim.list_extend({ "log" }, refs)
      vim.list_extend(args, {
        "--root",
        "--name-status",
        "-z",
        "--format=%x01%H%x09%at%x09%s",
        "-n",
        tostring(LH.config.list_limit or 100),
      })
      if st.query and st.query ~= "" then
        vim.list_extend(args, { "-S" .. st.query })
      end
      if st.scope == "file" then
        vim.list_extend(args, { "--follow", "--diff-filter=d", "--", ":(literal)" .. st.file })
      else
        vim.list_extend(args, { "--no-renames" })
      end
      local function finish(out, labels)
        if my ~= st.gen or not api.nvim_buf_is_valid(st.bufs.list) then
          return
        end
        st.snaps = parse(out)
        if labels then
          -- labelled snapshots that did not touch this file (a label alone changes nothing) belong to
          -- its history too, as JetBrains' labels do
          local have = {}
          for _, sn in ipairs(st.snaps) do
            have[sn.hash] = true
          end
          local extra = {}
          for _, sn in ipairs(parse(labels)) do
            if not have[sn.hash] then
              sn.files, sn.nfiles = {}, 0
              extra[#extra + 1] = sn
            end
          end
          if #extra > 0 then
            local merged = {}
            local i, j = 1, 1
            while i <= #st.snaps or j <= #extra do
              if j > #extra or (i <= #st.snaps and st.snaps[i].at > extra[j].at) then
                merged[#merged + 1] = st.snaps[i]
                i = i + 1
              else
                merged[#merged + 1] = extra[j]
                j = j + 1
              end
            end
            st.snaps = merged
          end
        end
        st.loaded = true
        render_list()
        local want = 1
        if keep then
          for i, s in ipairs(st.snaps) do
            if s.hash == keep then
              want = i
            end
          end
        end
        select_snap(want)
        if api.nvim_win_is_valid(st.wins.list) then
          pcall(api.nvim_win_set_cursor, st.wins.list, { math.min(want, math.max(1, #st.snaps)), 0 })
        end
      end
      LH._git(args, st.root, function(out)
        if st.scope == "file" and not st.query then
          local largs = vim.list_extend({ "log" }, refs)
          vim.list_extend(largs, {
            "-z",
            "--format=%x01%H%x09%at%x09%s",
            "-n",
            tostring(LH.config.list_limit or 100),
            "--invert-grep",
            "--grep=^autosave$",
          })
          return LH._git(largs, st.root, function(labels)
            finish(out, labels or "")
          end, true)
        end
        finish(out)
      end, true)
    end)
  end

  -- ---- actions
  function actions.refresh()
    local snap = st.snaps[st.sel]
    load(snap and snap.hash)
  end

  function actions.search(text)
    local function go(q)
      if q == nil then
        return
      end
      st.query = vim.trim(q) ~= "" and q or nil
      load()
    end
    if text ~= nil then
      return go(text)
    end
    vim.ui.input({ prompt = "Search snapshots for text: ", default = st.query }, go)
  end

  function actions.clear()
    st.query = nil
    load()
  end

  function actions.toggle_mode()
    st.mode = st.mode == "current" and "previous" or "current"
    bars()
    render_preview()
  end

  function actions.toggle_scope()
    if st.scope == "file" then
      st.scope = "project"
    elseif st.file then
      st.scope = "file"
    else
      return vim.notify("local history: no file in this buffer", vim.log.levels.INFO)
    end
    load()
  end

  function actions.label(text)
    local function go(label)
      label = vim.trim((label or ""):gsub("%s+", " "))
      if label == "" then
        return
      end
      LH.snapshot({
        path = abs(st.file or ""):gsub("/$", ""),
        force = true,
        label = label,
        mark = true,
        done = function()
          vim.schedule(function()
            if api.nvim_buf_is_valid(st.bufs.list) then
              load()
            end
          end)
        end,
      })
    end
    if text ~= nil then
      return go(text)
    end
    vim.ui.input({ prompt = "Label: " }, go)
  end

  function actions.yank()
    local snap = st.snaps[st.sel]
    if snap then
      vim.fn.setreg(vim.v.register == "" and '"' or vim.v.register, snap.hash)
      vim.notify("yanked " .. snap.hash)
    end
  end

  --- Open the snapshot version of the selected file beside the current one, in Neovim's own diff mode.
  function actions.side_by_side()
    local f, snap = selected_file()
    if not f then
      return
    end
    blob(snap.hash, f.path, function(content)
      if not content then
        return vim.notify("local history: the file does not exist in that snapshot", vim.log.levels.WARN)
      end
      local cur = (st.scope == "file" and st.file) or f.path
      local lines = LH._decode(content, nil)
      if not lines then
        return
      end
      vim.cmd("tabnew")
      if vim.uv.fs_stat(abs(cur)) then
        vim.cmd("edit " .. vim.fn.fnameescape(abs(cur)))
      end
      vim.cmd("diffthis")
      vim.cmd("vertical leftabove new")
      vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = "nofile", "wipe", false
      api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.filetype = vim.filetype.match({ filename = cur }) or ""
      pcall(api.nvim_buf_set_name, 0, ("%s@%s"):format(f.path, snap.hash:sub(1, 8)))
      vim.cmd("diffthis")
    end)
  end

  local function confirm(prompt, yes)
    vim.ui.select({ "Revert", "Cancel" }, { prompt = prompt }, function(ans)
      if ans == "Revert" then
        yes()
      end
    end)
  end

  --- Put the selected file back the way the snapshot had it: into its buffer (left modified, `u` undoes it)
  --- or, when it is not loaded or was deleted, onto the disk.
  function actions.revert_file()
    local f, snap = selected_file()
    if not f then
      return
    end
    local cur = (st.scope == "file" and st.file) or f.path
    blob(snap.hash, f.path, function(content)
      if not content then
        return vim.notify(
          "local history: the file does not exist in that snapshot; pick an earlier one",
          vim.log.levels.WARN
        )
      end
      local bufnr = vim.fn.bufnr(abs(cur))
      local loaded = bufnr > 0 and api.nvim_buf_is_loaded(bufnr)
      local lines, meta = LH._decode(content, loaded and bufnr or nil)
      if not lines then
        return vim.notify("local history: " .. tostring(meta) .. "; nothing reverted", vim.log.levels.WARN)
      end
      local short = snap.hash:sub(1, 8)
      if loaded then
        confirm(("Replace the buffer of %s with snapshot %s? (undo with u)"):format(cur, short), function()
          api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          vim.bo[bufnr].fileformat = meta.ff
          vim.bo[bufnr].endofline = meta.eol
          vim.notify(("reverted %s to %s (buffer modified, not saved)"):format(cur, short))
          render_preview()
        end)
      else
        confirm(
          ("Write snapshot %s of %s to disk%s?"):format(
            short,
            cur,
            vim.uv.fs_stat(abs(cur)) and "" or " (the file is deleted: it is created)"
          ),
          function()
            vim.fn.mkdir(vim.fs.dirname(abs(cur)), "p")
            local w = io.open(abs(cur), "wb")
            if not w then
              return vim.notify("local history: cannot write " .. abs(cur), vim.log.levels.ERROR)
            end
            w:write(content)
            w:close()
            vim.cmd("silent! checktime")
            vim.notify(("restored %s from %s on disk"):format(cur, short))
            render_preview()
          end
        )
      end
    end)
  end

  --- Revert only the hunk under the cursor of the preview ("snapshot vs current" mode): the snapshot's
  --- lines replace the current ones in the file's buffer.
  function actions.revert_hunk()
    local ctx = st.preview_ctx
    if st.mode ~= "current" or not ctx or not st.hunks or #st.hunks == 0 then
      return vim.notify("local history: no hunk here (use the snapshot vs current mode)", vim.log.levels.INFO)
    end
    if not ctx.have_current then
      return vim.notify("local history: the file is deleted: use r to bring it back whole", vim.log.levels.INFO)
    end
    local row = api.nvim_win_get_cursor(st.wins.preview)[1]
    local idx
    for i, l in ipairs(st.hunk_lines) do
      if l <= row then
        idx = i
      end
    end
    if not idx then
      return vim.notify("local history: put the cursor on a hunk", vim.log.levels.INFO)
    end
    local h = st.hunks[idx]
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local bufnr = ctx.bufnr
    if not bufnr then
      bufnr = vim.fn.bufadd(abs(ctx.path))
      vim.fn.bufload(bufnr)
    end
    local repl = {}
    for i = sb, sb + cb - 1 do
      repl[#repl + 1] = ctx.b_lines[i]
    end
    local s = ca > 0 and sa - 1 or sa
    api.nvim_buf_set_lines(bufnr, s, s + ca, false, repl)
    vim.notify(("reverted hunk %d of %s (buffer %d modified, not saved)"):format(idx, ctx.path, bufnr))
    render_preview()
  end

  function actions.close()
    if api.nvim_tabpage_is_valid(st.tab) then
      local nr = api.nvim_tabpage_get_number(st.tab)
      if #api.nvim_list_tabpages() > 1 then
        vim.cmd(("tabclose %d"):format(nr))
      else
        for _, b in pairs(st.bufs) do
          pcall(api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end

  function actions.next_pane(back)
    local order = { "list", "files", "preview" }
    local cur = api.nvim_get_current_win()
    local at = 1
    for i, k in ipairs(order) do
      if st.wins[k] == cur then
        at = i
      end
    end
    at = (at - 1 + (back and -1 or 1)) % 3 + 1
    api.nvim_set_current_win(st.wins[order[at]])
  end

  -- ---- keymaps and follow-the-cursor
  local function map(buf, lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Local history: " .. desc })
  end
  for _, buf in pairs(st.bufs) do
    map(buf, "q", actions.close, "close")
    map(buf, "<Tab>", function()
      actions.next_pane()
    end, "next pane")
    map(buf, "<S-Tab>", function()
      actions.next_pane(true)
    end, "previous pane")
    map(buf, "/", function()
      actions.search()
    end, "search content")
    map(buf, "c", actions.clear, "clear search")
    map(buf, "L", function()
      actions.label()
    end, "label")
    map(buf, "d", actions.toggle_mode, "diff mode")
    map(buf, "s", actions.toggle_scope, "scope file/project")
    map(buf, "r", actions.revert_file, "revert file")
    map(buf, "x", actions.revert_hunk, "revert hunk")
    map(buf, "gr", actions.refresh, "refresh")
    map(buf, "y", actions.yank, "yank hash")
    map(buf, "<CR>", actions.side_by_side, "side by side")
  end

  local timer = vim.uv.new_timer()
  local function follow(which)
    return function()
      timer:stop()
      timer:start(
        40,
        0,
        vim.schedule_wrap(function()
          if not api.nvim_win_is_valid(st.wins[which]) then
            return
          end
          local row = api.nvim_win_get_cursor(st.wins[which])[1]
          if which == "list" and row ~= st.sel and #st.snaps > 0 then
            select_snap(row)
          elseif which == "files" and row ~= st.fsel then
            select_file(row)
          end
        end)
      )
    end
  end
  api.nvim_create_autocmd("CursorMoved", { buffer = st.bufs.list, callback = follow("list") })
  api.nvim_create_autocmd("CursorMoved", { buffer = st.bufs.files, callback = follow("files") })
  api.nvim_create_autocmd("BufWipeout", {
    buffer = st.bufs.list,
    once = true,
    callback = function()
      st.gen = st.gen + 1
      preview_gen = preview_gen + 1
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      -- not inside the wipe: deleting the other buffers closes their windows, mid-:tabclose
      vim.schedule(function()
        for _, b in pairs(st.bufs) do
          if api.nvim_buf_is_valid(b) then
            pcall(api.nvim_buf_delete, b, { force = true })
          end
        end
      end)
    end,
  })

  st.select_snap, st.select_file = select_snap, select_file
  bars()
  render_list()
  load()
  return st
end

return M
