-- :checkhealth xyno_history
-- xyno-os: linux,macos (bash git wrapper)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

K.init()
LH.setup()

local lines
local function capture()
  lines = {}
  local orig = {}
  for _, k in ipairs({ "start", "ok", "warn", "error", "info" }) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg, advice)
      lines[#lines + 1] = { k, msg, advice }
    end
  end
  return function()
    for k, v in pairs(orig) do
      vim.health[k] = v
    end
  end
end

local function report()
  local restore = capture()
  local ok, err = pcall(require("xyno_history.health").check)
  restore()
  H.ok(ok, tostring(err))
  return lines
end
local function has(kind, pat)
  for _, l in ipairs(lines) do
    if (kind == nil or l[1] == kind) and l[2]:find(pat, 1, true) then
      return l
    end
  end
end

local restore_notify
before_each(function()
  _, restore_notify = K.capture_notify()
  vim.cmd("silent! %bwipeout!")
  vim.cmd("enew")
  LH.config.retention = false
  LH.config.exclude = nil
  LH.config.push_guard = false
  K.fail("add", false)
end)

after_each(function()
  restore_notify()
end)

describe("checkhealth xyno_history", function()
  it("reports git, setup, options, the secrets list and retention outside a repository", function()
    vim.cmd.cd(vim.fn.fnameescape(K.base))
    report()
    H.ok(has("ok", "git version"))
    H.ok(has("ok", "setup() has run"))
    H.ok(has("info", "throttle_s=60"))
    H.ok(has("ok", "default secret patterns"))
    H.ok(has("warn", "automatic retention is off"))
    H.ok(has("info", "not in a git worktree"))
  end)

  it("shows a failing repository as an ERROR with the reason, and the recovery as a WARN", function()
    local root = K.mkrepo()
    vim.cmd.cd(vim.fn.fnameescape(root))
    K.fail("add")
    K.snap(LH, root)
    K.snap(LH, root)
    report()
    local e = has("error", "snapshots are failing")
    H.ok(e, vim.inspect(lines))
    H.match(e[2], "injected failure", true)
    H.match(e[2], "2 attempts", true)
    K.fail("add", false)
    H.ok(K.snap(LH, root))
    report()
    H.ok(has("warn", "snapshots work again"))
    H.ok(has("ok", "last snapshot of this session"))
    H.ok(has("ok", "1 branch ref(s) under refs/lochist"))
  end)

  it("names hostile repository config that is being overridden", function()
    local root = K.mkrepo()
    vim.cmd.cd(vim.fn.fnameescape(root))
    K.G(root, "config", "core.fsmonitor", "/tmp/x")
    K.G(root, "config", "filter.evil.clean", "/tmp/y")
    report()
    local w = has("warn", "sets options that make git run commands")
    H.ok(w, vim.inspect(lines))
    H.match(w[2], "core.fsmonitor", true)
    H.match(w[2], "filter.evil.clean", true)
  end)

  it("warns about mirror remotes, and reports the push guard", function()
    local root = K.mkrepo()
    vim.cmd.cd(vim.fn.fnameescape(root))
    K.G(root, "remote", "add", "backup", "/nonexistent.git")
    K.G(root, "config", "remote.backup.mirror", "true")
    report()
    H.ok(has("warn", "backup have mirror = true"), vim.inspect(lines))
    H.ok(has("info", "no push guard installed"))
    LH.config.push_guard = true
    H.ok(K.snap(LH, root))
    report()
    H.ok(has("ok", "push guard installed"))
    K.G(root, "config", "core.hooksPath", "/nonexistent-hooks")
    report()
    H.ok(has("warn", "guard is inactive"))
  end)

  it("warns when the secrets list is disabled", function()
    LH.config.exclude = false
    vim.cmd.cd(vim.fn.fnameescape(K.base))
    report()
    H.ok(has("warn", "secrets exclude list is empty"))
    LH.config.exclude = nil
  end)
end)
