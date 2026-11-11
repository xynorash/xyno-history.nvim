-- A repository can carry hostile configuration (core.fsmonitor, core.hooksPath, include paths,
-- filter drivers, core.worktree ...). Opening such a repo and saving a file must not execute any of
-- it: every git call of the plugin runs with neutralised overrides.
-- xyno-os: linux,macos (shell scripts as canaries)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

K.init()
LH.setup()

local function canary(dir, name)
  local marker = dir .. "/MARKER_" .. name
  K.write(dir .. "/" .. name .. ".sh", "#!/bin/sh\ntouch '" .. marker .. "'\ncat\n")
  vim.fn.setfperm(dir .. "/" .. name .. ".sh", "rwxr-xr-x")
  return dir .. "/" .. name .. ".sh", marker
end

local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

local function hostile_repo()
  local root = K.mkrepo({ ["a.txt"] = "a\n" })
  local out = vim.fs.dirname(root)
  return root, out
end

describe("hostile repository configuration", function()
  local notes, restore
  before_each(function()
    notes, restore = K.capture_notify()
  end)
  after_each(function()
    restore()
  end)

  it("core.fsmonitor is not run", function()
    local root, out = hostile_repo()
    local script, marker = canary(out, "fsmon")
    K.G(root, "config", "core.fsmonitor", script)
    K.write(root .. "/new.txt", "n\n")
    K.write(root .. "/a.txt", "changed\n")
    local c = K.snap(LH, root)
    H.ok(c, "snapshot taken")
    H.not_ok(exists(marker), "core.fsmonitor hook ran")
    H.eq("n\n", K.blob(root, c, "new.txt"))
  end)

  it("core.hooksPath (reference-transaction, pre-auto-gc ...) is not run", function()
    local root, out = hostile_repo()
    vim.fn.mkdir(out .. "/hooks", "p")
    local script, marker = canary(out, "hook")
    vim.uv.fs_copyfile(script, out .. "/hooks/reference-transaction")
    vim.fn.setfperm(out .. "/hooks/reference-transaction", "rwxr-xr-x")
    K.G(root, "config", "core.hooksPath", out .. "/hooks")
    K.write(root .. "/a.txt", "changed\n")
    H.ok(K.snap(LH, root))
    H.not_ok(exists(marker), "reference-transaction hook ran")
    -- and the repo's own .git/hooks are not run either
    local script2, marker2 = canary(out, "hook2")
    vim.uv.fs_copyfile(script2, root .. "/.git/hooks/reference-transaction")
    vim.fn.setfperm(root .. "/.git/hooks/reference-transaction", "rwxr-xr-x")
    K.G(root, "config", "--unset", "core.hooksPath")
    K.write(root .. "/a.txt", "changed again\n")
    H.ok(K.snap(LH, root))
    H.not_ok(exists(marker2), ".git/hooks/reference-transaction ran")
  end)

  it("an include.path file cannot switch a dangerous setting back on", function()
    local root, out = hostile_repo()
    local script, marker = canary(out, "inc")
    K.write(out .. "/evil.cfg", "[core]\n\tfsmonitor = " .. script .. "\n")
    K.G(root, "config", "include.path", out .. "/evil.cfg")
    K.G(root, "config", "includeIf.gitdir:" .. root .. "/.git.path", out .. "/evil.cfg")
    K.write(root .. "/a.txt", "changed\n")
    H.ok(K.snap(LH, root))
    H.not_ok(exists(marker), "included core.fsmonitor ran")
  end)

  it("a clean/smudge filter named by .gitattributes is not run, the raw bytes are stored", function()
    local root, out = hostile_repo()
    local script, marker = canary(out, "filter")
    K.write(root .. "/.gitattributes", "*.txt filter=evil\n*.dat text eol=crlf\n")
    K.G(root, "config", "filter.evil.clean", script)
    K.G(root, "config", "filter.evil.smudge", script)
    K.G(root, "config", "filter.evil.process", script)
    K.write(root .. "/b.txt", "bee\n")
    K.write(root .. "/crlf.dat", "x\ny\n")
    local c = K.snap(LH, root)
    H.ok(c)
    H.not_ok(exists(marker), "filter driver ran")
    H.eq("bee\n", K.blob(root, c, "b.txt"))
    H.eq("x\ny\n", K.blob(root, c, "crlf.dat"), "no eol conversion from .gitattributes")
  end)

  it("core.autocrlf in the user's global config does not rewrite what is stored", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n" })
    K.G(root, "config", "core.autocrlf", "true")
    K.write(root .. "/w.txt", "one\r\ntwo\r\n")
    local c = K.snap(LH, root)
    H.ok(c)
    H.eq("one\r\ntwo\r\n", K.blob(root, c, "w.txt"))
  end)

  it("exports neutral values for the settings that execute commands", function()
    local root = K.mkrepo()
    for k, v in pairs({
      ["core.sshCommand"] = "touch /tmp/never-ssh",
      ["core.gitProxy"] = "touch /tmp/never-proxy",
      ["core.pager"] = "touch /tmp/never-pager",
      ["core.editor"] = "touch /tmp/never-editor",
      ["core.askPass"] = "touch /tmp/never-ask",
      ["core.fsmonitor"] = "touch /tmp/never-fsmon",
      ["core.alternateRefsCommand"] = "touch /tmp/never-alt",
      ["credential.helper"] = "!touch /tmp/never-cred",
      ["diff.external"] = "touch /tmp/never-diff",
      ["gpg.program"] = "touch /tmp/never-gpg",
    }) do
      K.G(root, "config", k, v)
    end
    K.G(root, "config", "core.hooksPath", root .. "/evil-hooks")
    K.G(root, "config", "core.worktree", "/")
    K.G(root, "config", "filter.x.clean", "touch /tmp/never-clean")
    K.G(root, "config", "diff.y.textconv", "touch /tmp/never-textconv")
    local env = LH.git_env(root)
    local function get(key)
      local r = vim.system({ K.REAL_GIT, "config", "--get", key }, { cwd = root, text = true, env = env }):wait()
      return vim.trim(r.stdout or "")
    end
    for _, key in ipairs({ "core.sshCommand", "core.gitProxy", "core.editor", "core.askPass", "core.fsmonitor", "core.alternateRefsCommand", "credential.helper", "diff.external", "gpg.program" }) do
      local v = get(key)
      H.no_match(v, "never", true, key .. " = " .. v)
    end
    H.eq("cat", get("core.pager"))
    H.eq("false", get("core.fsmonitor"))
    H.no_match(get("core.hooksPath"), "evil-hooks", true)
    -- the work tree is pinned to the directory that holds .git, never core.worktree
    local r = vim.system({ K.REAL_GIT, "rev-parse", "--show-toplevel" }, { cwd = root, text = true, env = env }):wait()
    H.eq(root, vim.trim(r.stdout))
  end)

  it("core.worktree pointing elsewhere does not make a snapshot of that other directory", function()
    local root, out = hostile_repo()
    K.write(out .. "/elsewhere/secret.txt", "do not snapshot\n")
    K.G(root, "config", "core.worktree", out .. "/elsewhere")
    K.write(root .. "/a.txt", "changed\n")
    local c = K.snap(LH, root)
    if c then
      H.not_ok(vim.tbl_contains(K.names(root, c), "secret.txt"), "snapshot contains the foreign directory")
    end
  end)
end)
