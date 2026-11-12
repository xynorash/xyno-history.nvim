-- How long does quitting nvim wait for the exit snapshot?
--   XYNO_IMPL=<plugin dir> nvim --headless -u NONE -i NONE -l scripts/bench_exit.lua <repo>
-- Starts a child nvim on <repo> that saves a file twice (the second save is still inside the throttle window,
-- so it is the one the exit snapshot has to record), then quits, and prints the time from `:qa!` to the end of
-- the process. Run it on a throw-away clone: it writes refs/lochist/* and .git/lochist-index*.
local impl = assert(vim.env.XYNO_IMPL, "XYNO_IMPL")
local repo = assert(arg[1], "repo")
local uv = vim.uv
vim.fn.system({ "git", "-C", repo, "update-ref", "-d", "refs/lochist/main" })
for _, f in ipairs(vim.fn.glob(repo .. "/.git/lochist-index*", true, true)) do
  os.remove(f)
end
local script = vim.fn.tempname() .. ".lua"
local stamp = vim.fn.tempname()
vim.fn.writefile({
  'package.path = "' .. impl .. '/lua/?.lua;' .. impl .. '/lua/?/init.lua;" .. package.path',
  'local LH = require("xyno_history")',
  'LH.setup({ retention = false })',
  'local f = "' .. repo .. '/pkg3/mod4/f5.js"',
  'vim.cmd.edit(f)',
  'vim.api.nvim_buf_set_lines(0, 0, -1, false, { "// one" })',
  'vim.cmd.write()',
  'vim.wait(60000, function() return vim.fn.system({ "git", "-C", "' .. repo .. '", "rev-parse", "-q", "--verify", "refs/lochist/main" }) ~= "" end, 20)',
  'vim.wait(1500)',
  'vim.api.nvim_buf_set_lines(0, 0, -1, false, { "// two" })',
  'vim.cmd.write()',
  'vim.fn.writefile({ tostring(vim.uv.hrtime()) }, "' .. stamp .. '")',
  'vim.cmd("qa!")',
}, script)
local r = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-c", "luafile " .. script }, { text = true }):wait(120000)
local t1 = uv.hrtime()
local t0 = tonumber(vim.fn.readfile(stamp)[1])
local blob = vim.fn.system({ "git", "-C", repo, "show", "refs/lochist/main:pkg3/mod4/f5.js" })
print(vim.json.encode({
  impl = vim.fs.basename(impl),
  exit_ms = math.floor((t1 - t0) / 1e6),
  recorded = blob:find("// two", 1, true) ~= nil,
  code = r.code,
}))
vim.cmd("qa!")
