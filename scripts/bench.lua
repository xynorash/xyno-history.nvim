-- Reproducible cost measurement of one snapshot per save on a big worktree.
--   XYNO_IMPL=<plugin dir> nvim --headless -u NONE -i NONE -l scripts/bench.lua <repo> [saves]
-- It uses and then removes refs/lochist/* and .git/lochist-index* of <repo>, so point it at a throw-away
-- clone or a generated tree. Prints one JSON line:
--   first_ms        first snapshot of the session (always a full scan)
--   save_ms         median wall time of a snapshot after a save (the throttle is lifted between saves)
--   save_max_stall  longest gap between two event-loop turns while snapshots ran (editor responsiveness)
--   git_calls       git processes started for the saves (not the first snapshot)
local impl = assert(vim.env.XYNO_IMPL, "XYNO_IMPL")
local repo = assert(arg[1], "repo")
local saves = tonumber(arg[2]) or 8
package.path = impl .. "/lua/?.lua;" .. impl .. "/lua/?/init.lua;" .. package.path
local LH = require("xyno_history")
LH.setup({ retention = false })

local uv = vim.uv
local function ms()
  return uv.hrtime() / 1e6
end

local function upvalue(fn, name)
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      return nil
    end
    if n == name then
      return v
    end
  end
end
local last = upvalue(LH.snapshot, "last")
local function reset_throttle()
  last[repo] = nil
end

local logfile = vim.env.XYNO_GITLOG
local function git_calls()
  if not logfile then
    return 0
  end
  local ok, lines = pcall(vim.fn.readfile, logfile)
  return ok and #lines or 0
end

local function snapshot(opts)
  local done = false
  local t0 = ms()
  opts.done = function()
    done = true
  end
  LH.snapshot(opts)
  vim.wait(120000, function()
    return done
  end, 1)
  return ms() - t0
end

-- event-loop stall meter
local stall, prev = 0, ms()
local timer = uv.new_timer()
timer:start(0, 5, function()
  local now = ms()
  stall = math.max(stall, now - prev - 5)
  prev = now
end)

local target = repo .. "/pkg3/mod4/f5.js"
local first = snapshot({ path = repo, force = true })
stall = 0
local before_calls = git_calls()
local times = {}
for i = 1, saves do
  local f = assert(io.open(target, "ab"))
  f:write("// save " .. i .. "\n")
  f:close()
  reset_throttle()
  times[#times + 1] = snapshot({ path = target })
end
table.sort(times)
timer:stop()
print(vim.json.encode({
  impl = vim.fs.basename(impl),
  first_ms = math.floor(first),
  save_ms = math.floor(times[math.ceil(#times / 2)]),
  save_max_stall = math.floor(stall),
  git_calls = git_calls() - before_calls,
  saves = saves,
}))
vim.cmd("qa!")
