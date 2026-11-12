-- Detached helper started by xyno_history on quit (exit_mode = "background"):
--   nvim --headless -u NONE -i NONE -n -l exit_worker.lua <handoff.json>
-- Takes the snapshot the quitting session still owed, then exits. Never runs in a user's session.
local handoff_path = arg[1]
local f = handoff_path and io.open(handoff_path, "rb")
if not f then
  vim.cmd("cquit 2")
end
local ok, h = pcall(vim.json.decode, f:read("*a"))
f:close()
os.remove(handoff_path)
if not ok or type(h) ~= "table" then
  vim.cmd("cquit 2")
end

local here = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))

local function report(res)
  res.time = os.time()
  local out = io.open(h.gitdir .. "/lochist-exit.json", "wb")
  if out then
    out:write(vim.json.encode(res))
    out:close()
  end
end

-- never outlive a hung git for long
vim.defer_fn(function()
  report({ ok = false, reason = "the exit worker gave up after 45 s" })
  vim.cmd("qa!")
end, 45000)

local LH = require("xyno_history")
local cfg = h.config
cfg.commands, cfg.keymaps, cfg.retention, cfg.push_guard = false, false, false, false
cfg.exit_mode = "off"
LH.setup(cfg)

-- the quitting nvim's private index seeds ours once it is gone (see prepare())
vim.wait(3000, function()
  return vim.uv.kill(h.parent, 0) ~= 0
end, 20)

local finished = false
LH._exit_import(h.root, { touched = h.touched, fullscan = h.fullscan })
if not vim.uv.fs_stat(h.gitdir) then
  vim.cmd("qa!")
end
LH.snapshot({
  path = h.root,
  force = true,
  fast = true,
  done = function(commit)
    local st = LH.status()[h.root] or {}
    local reason = st.failing and st.failing.reason or (st.last_failure and st.last_failure.time >= os.time() - 1 and st.last_failure.reason) or nil
    report({ ok = reason == nil, commit = commit, reason = reason })
    finished = true
  end,
})
-- `nvim -l` ends with the script: wait for the asynchronous snapshot
-- (git has its own 30 s watchdog inside the snapshot; a repository that vanished ends it at once)
vim.wait(44000, function()
  return finished or not vim.uv.fs_stat(h.gitdir)
end, 20)
vim.cmd("qa!")
