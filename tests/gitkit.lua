-- Shared plumbing of the newer specs: hermetic git (empty global config, no system config), a
-- logging `git` first in PATH, temp repos and small readers. The older history_spec.lua keeps its
-- own copy (it also fault-injects).  `local K = require("xyno_history_test.gitkit")`
local H = require("xyno_history_test.helpers")
local uv = vim.uv

local K = {}
K.REAL_GIT = vim.fn.exepath("git")

function K.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

function K.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- Make git hermetic and log every call to <base>/log as "<GIT_INDEX_FILE>\t<args>".
--- A file <base>/delay.<subcommand> holding a number makes that subcommand sleep that long;
--- a file <base>/fail.<subcommand> makes it fail with exit 128.
function K.init()
  local base = H.tmpdir()
  K.base, K.logfile = base, base .. "/log"
  K.write(
    base .. "/bin/git",
    ([[#!/bin/bash
printf '%%s\t%%s\n' "$GIT_INDEX_FILE" "$*" >> "%s"
if [ -f "%s/delay.$1" ]; then sleep "$(cat "%s/delay.$1")"; fi
if [ -f "%s/fail.$1" ]; then echo "fatal: injected failure ($1)" >&2; exit 128; fi
exec "%s" "$@"
]]):format(K.logfile, base, base, base, K.REAL_GIT)
  )
  vim.fn.setfperm(base .. "/bin/git", "rwxr-xr-x")
  K.write(base .. "/gitconfig", "")
  local saved = {}
  for _, k in ipairs({ "PATH", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "HOME", "XDG_STATE_HOME" }) do
    saved[k] = vim.env[k]
  end
  vim.env.PATH = base .. "/bin:" .. vim.env.PATH
  vim.env.GIT_CONFIG_GLOBAL = base .. "/gitconfig"
  vim.env.GIT_CONFIG_NOSYSTEM = "1"
  vim.env.XDG_STATE_HOME = base .. "/state"
  H._restore[#H._restore + 1] = function()
    for k, v in pairs(saved) do
      vim.env[k] = v
    end
  end
  return base
end

function K.delay(sub, seconds)
  K.write(K.base .. "/delay." .. sub, tostring(seconds))
end
function K.fail(sub, on)
  if on == false then
    os.remove(K.base .. "/fail." .. sub)
  else
    K.write(K.base .. "/fail." .. sub, "1")
  end
end

--- Find a module-level local of xyno_history by name (an upvalue of its functions).
function K.state(LH, name)
  local function find(fn, seen)
    if seen[fn] then
      return nil
    end
    seen[fn] = true
    for i = 1, 200 do
      local n, v = debug.getupvalue(fn, i)
      if not n then
        break
      end
      if n == name then
        return v
      end
    end
    for i = 1, 200 do
      local n, v = debug.getupvalue(fn, i)
      if not n then
        break
      end
      if type(v) == "function" then
        local r = find(v, seen)
        if r ~= nil then
          return r
        end
      end
    end
  end
  return find(LH.snapshot, {})
end

function K.log()
  local ok, lines = pcall(vim.fn.readfile, K.logfile)
  return ok and lines or {}
end
function K.clear_log()
  vim.fn.delete(K.logfile)
end
--- number of logged git calls whose "<args>" part matches the Lua pattern
function K.count(pat)
  local n = 0
  for _, l in ipairs(K.log()) do
    if (l:match("^[^\t]*\t(.*)$") or ""):find(pat) then
      n = n + 1
    end
  end
  return n
end

function K.run(dir, args, stdin, env, raw)
  local cmd = { K.REAL_GIT, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.quotepath=false" }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = dir, text = not raw, stdin = stdin, env = env }):wait(60000)
end
function K.G(dir, ...)
  local r = K.run(dir, { ... })
  if r.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat({ ... }, " "), r.code, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end
function K.tip(root, ref)
  local r = K.run(root, { "rev-parse", "-q", "--verify", ref })
  return r.code == 0 and vim.trim(r.stdout) or nil
end
function K.names(root, rev)
  local out = {}
  for _, n in ipairs(vim.split(K.G(root, "ls-tree", "-r", "--name-only", "-z", rev), "\0", { plain = true })) do
    if n ~= "" then
      out[#out + 1] = n
    end
  end
  return out
end
function K.blob(root, rev, rel)
  local r = K.run(root, { "cat-file", "blob", rev .. ":" .. rel }, nil, nil, true)
  return r.code == 0 and r.stdout or nil
end
function K.count_commits(root, ref)
  return tonumber(K.G(root, "rev-list", "--count", ref))
end

function K.mkrepo(files)
  local dir = H.tmpdir()
  local root = uv.fs_realpath(dir) .. "/repo"
  vim.fn.mkdir(root, "p")
  K.G(root, "init", "-q", "-b", "main")
  for rel, text in pairs(files or { ["a.txt"] = "a\n" }) do
    K.write(root .. "/" .. rel, text)
  end
  K.G(root, "add", "-A")
  K.G(root, "commit", "-q", "-m", "init")
  return root
end

--- Synchronous snapshot (forced unless opts.force == false); returns the commit.
function K.snap(LH, root, opts)
  opts = vim.tbl_extend("force", { path = root, force = true }, opts or {})
  local called, commit = false, nil
  opts.done = function(c)
    called, commit = true, c
  end
  LH.snapshot(opts)
  H.wait_for(function()
    return called
  end, 30000, "snapshot done callback")
  return commit
end

--- Capture vim.notify into the returned list until the returned restore() runs.
function K.capture_notify()
  local notes, orig = {}, vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  return notes, function()
    vim.notify = orig
  end
end

return K
