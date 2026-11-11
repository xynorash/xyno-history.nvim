-- Secrets: likely credential files stay out of the snapshot tree even when .gitignore does not cover them,
-- the list is configurable, and refs/lochist/* can be kept from `git push --mirror`.
-- xyno-os: linux,macos (hooks are shell scripts)
local H = require("xyno_history_test.helpers")
local K = require("xyno_history_test.gitkit")
local LH = require("xyno_history")

K.init()
LH.setup()
local uv = vim.uv

local function reset()
  LH.config.exclude = nil
  LH.config.exclude_extra = {}
  LH.config.push_guard = false
  LH.config.retention = false
  K.state(LH, "purged") -- (table is replaced by setup(); see below)
end

local SECRETS = {
  ".env", ".env.local", "sub/.env.production", "app.env", ".envrc",
  "cert.pem", "deploy.key", "keys/server.p12", "id_rsa", "id_ed25519", ".ssh/config", ".ssh/known_hosts",
  ".npmrc", ".netrc", "credentials.json", "sub/credentials.yml", "vault.kdbx", "terraform.tfstate", "prod.tfvars",
  ".aws/credentials", ".gnupg/pubring.kbx", "service-account-prod.json", "ID_RSA", ".ENV",
}
local FINE = {
  "src/main.rs", "src/id_gen.rs", "src/credentials.rs", "environment.rs", "README.md", "monkey.rs", "docs/env.md",
  "key_value.rs", "keys.rs", "src/target/mod.rs", "pem.rs", ".envelope.txt", "notes.credentials.md.txt",
}

describe("secrets: default exclude list", function()
  before_each(reset)

  it("leaves likely secrets out of the tree, untracked and not ignored by .gitignore, and keeps ordinary files", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n" })
    for _, rel in ipairs(SECRETS) do
      K.write(root .. "/" .. rel, "SECRET-CANARY-" .. rel .. "\n")
    end
    for _, rel in ipairs(FINE) do
      K.write(root .. "/" .. rel, "fine " .. rel .. "\n")
    end
    local c = K.snap(LH, root)
    H.ok(c)
    local names = K.names(root, c)
    for _, rel in ipairs(SECRETS) do
      H.not_ok(vim.tbl_contains(names, rel), rel .. " is in the snapshot")
    end
    for _, rel in ipairs(FINE) do
      H.ok(vim.tbl_contains(names, rel), rel .. " is missing from the snapshot")
    end
  end)

  it("never writes the secret's content into the object store, not even as an unreachable blob", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n" })
    K.write(root .. "/.env", "API_KEY=NEVER-IN-OBJECTS-12345\n")
    K.write(root .. "/sub/server.key", "-----BEGIN PRIVATE KEY-----NEVER-IN-OBJECTS-12345\n")
    K.write(root .. "/ok.txt", "hello\n")
    H.ok(K.snap(LH, root))
    local r = K.run(root, { "cat-file", "--batch-all-objects", "--batch" }, nil, nil, true)
    H.eq(0, r.code)
    H.no_match(r.stdout, "NEVER-IN-OBJECTS-12345", true)
    H.match(r.stdout, "hello", true)
  end)

  it("also leaves out a secret that is tracked in the repository (history has it already, a snapshot adds copies)", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n", [".env"] = "A=1\n" })
    K.write(root .. "/.env", "A=2-CHANGED-TRACKED\n")
    K.write(root .. "/a.txt", "b\n")
    local c = K.snap(LH, root)
    H.ok(c)
    H.not_ok(vim.tbl_contains(K.names(root, c), ".env"))
    local r = K.run(root, { "cat-file", "--batch-all-objects", "--batch" }, nil, nil, true)
    H.no_match(r.stdout, "CHANGED-TRACKED", true)
  end)

  it("removes secrets that an earlier version or an earlier exclude list had put into the private index", function()
    local root = K.mkrepo({ ["a.txt"] = "a\n" })
    LH.config.exclude = false -- the old behaviour: everything
    K.write(root .. "/.env", "OLD-ENTRY-1\n")
    K.write(root .. "/x.txt", "x\n")
    local c1 = K.snap(LH, root)
    H.ok(vim.tbl_contains(K.names(root, c1), ".env"), "setup: .env was snapshotted without a list")
    -- a new session: the defaults apply, the index of the last session seeds this one
    LH.config.exclude = nil
    K.state(LH, "fullscan")[root] = nil
    for k in pairs(K.state(LH, "purged")) do
      K.state(LH, "purged")[k] = nil
    end
    K.write(root .. "/x.txt", "x2\n")
    local c2 = K.snap(LH, root)
    H.ok(c2)
    H.not_ok(vim.tbl_contains(K.names(root, c2), ".env"), ".env must be removed from the new snapshot")
    H.ok(vim.tbl_contains(K.names(root, c2), "x.txt"))
  end)
end)

describe("secrets: configuration", function()
  local notes, restore
  before_each(function()
    reset()
    notes, restore = K.capture_notify()
  end)
  after_each(function()
    restore()
    reset()
  end)

  it("exclude_extra adds patterns (a name at any depth, a directory, a rooted path)", function()
    LH.config.exclude_extra = { "*.secret", "private/", "/only-at-root.txt" }
    local root = K.mkrepo()
    for _, rel in ipairs({ "x.secret", "d/y.secret", "private/z.txt", "d/private/w.txt", "only-at-root.txt", "d/only-at-root.txt", ".env" }) do
      K.write(root .. "/" .. rel, "1\n")
    end
    local names = K.names(root, K.snap(LH, root))
    H.eq({ "a.txt", "d/only-at-root.txt" }, names)
  end)

  it("exclude replaces the list; false and {} switch it off", function()
    LH.config.exclude = { "only.txt" }
    local root = K.mkrepo()
    K.write(root .. "/only.txt", "1\n")
    K.write(root .. "/.env", "2\n")
    H.eq({ ".env", "a.txt" }, K.names(root, K.snap(LH, root)))
    LH.config.exclude = false
    K.write(root .. "/only.txt", "1b\n")
    H.eq({ ".env", "a.txt", "only.txt" }, K.names(root, K.snap(LH, root)))
  end)

  it("matches case-insensitively", function()
    local root = K.mkrepo()
    K.write(root .. "/.Env.Local", "1\n")
    K.write(root .. "/Server.PEM", "2\n")
    H.eq({ "a.txt" }, K.names(root, K.snap(LH, root)))
  end)

  it("M.exclude_patterns() lists what applies; M.default_exclude holds the defaults", function()
    H.has(LH.default_exclude, ".env")
    H.has(LH.default_exclude, "*.pem")
    H.has(LH.default_exclude, ".npmrc")
    H.eq(LH.default_exclude, LH.exclude_patterns())
    LH.config.exclude_extra = { "*.mine" }
    H.has(LH.exclude_patterns(), "*.mine")
    H.has(LH.exclude_patterns(), ".env")
  end)

  it("setup() reports negation and non-string patterns once instead of silently ignoring them", function()
    LH.setup({ exclude_extra = { "!keep.env", "fine" } })
    H.eq(1, #notes)
    H.match(notes[1].msg, "negation is not supported", true)
    H.match(notes[1].msg, "!keep.env", true)
    for i = #notes, 1, -1 do
      notes[i] = nil
    end
    LH.setup({ exclude = { "a", 5 } })
    H.eq(1, #notes)
    H.match(notes[1].msg, "must be a string", true)
    LH.config.exclude_extra = {}
    LH.config.exclude = nil
  end)
end)

describe("secrets: refs/lochist/* and git push --mirror", function()
  local function remote_for(root)
    local bare = vim.fs.dirname(root) .. "/remote.git"
    K.G(vim.fs.dirname(root), "init", "-q", "--bare", bare)
    K.G(root, "remote", "add", "origin", bare)
    return bare
  end
  local function heads(bare)
    return K.G(bare, "for-each-ref", "--format=%(refname)")
  end
  before_each(reset)

  it("without the guard a mirror push copies the snapshots to the remote (the risk the README describes)", function()
    local root = K.mkrepo()
    K.write(root .. "/note.txt", "snapshot content\n")
    H.ok(K.snap(LH, root))
    local bare = remote_for(root)
    K.G(root, "push", "-q", "--mirror", "origin")
    H.match(heads(bare), "refs/lochist/main", true)
    -- a plain push does not
    local bare2 = vim.fs.dirname(root) .. "/remote2.git"
    K.G(vim.fs.dirname(root), "init", "-q", "--bare", bare2)
    K.G(root, "push", "-q", bare2, "main")
    H.no_match(heads(bare2), "lochist", true)
  end)

  it("push_guard = true installs a pre-push hook that refuses a mirror push but not a normal one", function()
    LH.config.push_guard = true
    local root = K.mkrepo()
    K.write(root .. "/note.txt", "snapshot content\n")
    H.ok(K.snap(LH, root))
    local hook = root .. "/.git/hooks/pre-push"
    H.ok(uv.fs_stat(hook), "hook installed")
    H.ok(bit.band(uv.fs_stat(hook).mode, tonumber("100", 8)) ~= 0, "executable")
    local bare = remote_for(root)
    local r = K.run(root, { "push", "--mirror", "origin" })
    H.ok(r.code ~= 0, "mirror push must fail")
    H.match(r.stderr, "refusing to push refs/lochist", true)
    H.eq("", heads(bare), "nothing reached the remote")
    local ok = K.run(root, { "push", "origin", "main" })
    H.eq(0, ok.code, ok.stderr)
    H.match(heads(bare), "refs/heads/main", true)
    H.no_match(heads(bare), "lochist", true)
    local explicit = K.run(root, { "push", "origin", "refs/lochist/main:refs/lochist/main" })
    H.ok(explicit.code ~= 0, "an explicit refspec is refused too")
  end)

  it("does not touch a pre-push hook that is not ours, and says so once", function()
    LH.config.push_guard = true
    local root = K.mkrepo()
    K.write(root .. "/.git/hooks/pre-push", "#!/bin/sh\necho mine\n")
    local notes, restore = K.capture_notify()
    H.ok(K.snap(LH, root))
    K.write(root .. "/a.txt", "2\n")
    H.ok(K.snap(LH, root))
    restore()
    H.eq("#!/bin/sh\necho mine\n", K.read(root .. "/.git/hooks/pre-push"))
    H.eq(1, #vim.tbl_filter(function(n) return n.msg:find("pre-push", 1, true) end, notes))
  end)

  it("writes the hook into the repository's hooks directory, never through a core.hooksPath that the repo config sets", function()
    LH.config.push_guard = true
    local root = K.mkrepo()
    local elsewhere = vim.fs.dirname(root) .. "/elsewhere"
    vim.fn.mkdir(elsewhere, "p")
    K.G(root, "config", "core.hooksPath", elsewhere)
    H.ok(K.snap(LH, root))
    H.is_nil(uv.fs_stat(elsewhere .. "/pre-push"), "nothing written outside the repository")
    H.ok(uv.fs_stat(root .. "/.git/hooks/pre-push"))
  end)

  it("is off by default: no hook appears", function()
    local root = K.mkrepo()
    H.ok(K.snap(LH, root))
    H.is_nil(uv.fs_stat(root .. "/.git/hooks/pre-push"))
  end)
end)
