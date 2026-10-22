-- End-to-end smoke test (see tests/e2e/init.lua): the plugin is loaded by lazy.nvim,
-- setup() ran, every documented command exists, :help xyno-history resolves, and a
-- :write in a git repository produces a snapshot on refs/lochist/.
local failures = {}
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and (": " .. tostring(detail)) or ""))
  if not ok then
    failures[#failures + 1] = name
  end
end

check("lazy.nvim loaded xyno_history", package.loaded["xyno_history"] ~= nil)
for _, c in ipairs({ "LocalHistory", "LocalHistoryRestore", "LocalHistoryPrune" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
check("autocmd group xyno_history", #vim.api.nvim_get_autocmds({ group = "xyno_history" }) >= 3)

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
local ok, err = pcall(vim.cmd, "help xyno-history")
check(":help xyno-history", ok, err)
check(":help xyno-history-api", (pcall(vim.cmd, "help xyno-history-api")))
vim.cmd("only")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function git(...)
  local r = vim.system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ... }, { cwd = dir, text = true }):wait(30000)
  return r.code == 0 and vim.trim(r.stdout) or nil
end
git("init", "-q", "-b", "main")
vim.fn.writefile({ "one" }, dir .. "/a.txt")
git("add", "-A")
git("commit", "-q", "-m", "init")
vim.cmd.edit(vim.fn.fnameescape(dir .. "/a.txt"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two" })
vim.cmd.write()
local landed = vim.wait(15000, function()
  return git("rev-parse", "-q", "--verify", "refs/lochist/main") ~= nil
end, 50)
check("a :write snapshots to refs/lochist/main", landed)
check("the snapshot holds the saved text", git("show", "refs/lochist/main:a.txt") == "two")
vim.fn.delete(dir, "rf")

if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
