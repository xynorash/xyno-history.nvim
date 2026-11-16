-- xyno-history: a Local History for Neovim, inspired by the JetBrains feature of that name (not affiliated
-- with JetBrains). Every (throttled) save also writes the
-- whole worktree - untracked files included, .gitignore respected, target/
-- excluded - as a commit on refs/lochist/<key>, using a private index file
-- so the real index/stash/branches are never touched. Survives what
-- undofile can't: deleted files, `git reset --hard`, edits made by an agent.
--
-- <key> is the branch with "%" -> "%25" and "/" -> "%2F" (so refs/lochist/foo
-- and refs/lochist/foo%2Fbar can never collide as file vs directory), or
-- "%detached-<short HEAD sha>" for a detached HEAD ("%" never starts an encoded
-- branch, so the two cannot clash). Old-style refs (refs/lochist/<raw branch>,
-- refs/lochist/detached) are no longer written. Old-style refs containing a
-- "/" are renamed to the encoded form on first use (they could block new
-- branches); the old "detached" ref is left alone and still read by
-- :LocalHistory.
-- Saves inside the throttle window are not lost: one trailing snapshot is
-- scheduled for the end of the window (and one more on exit if still pending
-- or still in flight: the running git is killed and the snapshot redone, by default in a detached
-- nvim that outlives this one (exit_mode "background"), else synchronously within exit_budget_ms,
-- on the fast path when it can).
-- Every nvim process uses its own index file (.git/lochist-index.<pid>), so
-- concurrent instances never fight over one index.lock; leftovers of dead
-- processes are cleaned up (the newest seeds the next one, so the first
-- scan stays incremental).
--
-- Cost per snapshot. A "full" scan walks the worktree (git ls-files -o, git add -A); the first
-- snapshot of a session is always full. Later ones are "fast" while the last full scan is younger
-- than full_scan_s: they look only at the paths saved from nvim plus `git diff-files` (tracked files
-- that changed, found by stat without walking directories) and `git add -A` those paths only. A file
-- created by something else (an agent, a build) is picked up by the next full scan, at the latest
-- when full_scan_s has passed or at the end of a burst of saves (the trailing snapshot is fast too,
-- so call snapshot({ force = true }) for a guaranteed full one).
--
-- Safety. Snapshots are plain git objects in the repository, so anything in the worktree that is not
-- excluded ends up there; the `exclude` option (default: .env*, *.pem, *.key, id_rsa*, .npmrc,
-- .netrc, credentials.json ...) keeps likely secrets out even when .gitignore does not cover them.
-- Every git call runs with neutral overrides for the settings that make git execute commands
-- (core.fsmonitor, core.hooksPath, core.sshCommand, filter drivers, ...) and with the work tree
-- pinned to the directory that holds .git, so a hostile repository config cannot run code.
local M = {}

--- Gitignore-like patterns left out of every snapshot by default (see the README for the reasons).
--- Matching is case-insensitive. A pattern without "/" matches a file or directory of that name at
--- any depth; "name/" only a directory; "/a/b" or "a/b" is anchored at the repository root.
M.default_exclude = {
  -- environment files
  ".env",
  ".env.*",
  "*.env",
  ".envrc",
  -- private keys and certificates with keys
  "*.pem",
  "*.key",
  "*.p12",
  "*.pfx",
  "*.p8",
  "*.jks",
  "*.keystore",
  "*.ppk",
  "id_rsa*",
  "id_dsa*",
  "id_ecdsa*",
  "id_ed25519*",
  "secring.*",
  -- password stores
  "*.kdbx",
  "*.kdb",
  ".pgpass",
  ".vault-pass*",
  ".htpasswd",
  -- tool credentials
  ".npmrc",
  ".yarnrc.yml",
  ".pypirc",
  ".netrc",
  "_netrc",
  ".git-credentials",
  ".dockercfg",
  "credentials",
  "credentials.json",
  "credentials.yml",
  "credentials.yaml",
  "credentials.toml",
  "credentials.xml",
  "credentials.ini",
  ".credentials*",
  "*.credentials",
  "secrets.json",
  "secrets.yml",
  "secrets.yaml",
  "secrets.toml",
  "service-account*.json",
  "*.tfvars",
  "*.tfstate",
  "*.tfstate.backup",
  "kubeconfig",
  -- directories
  ".ssh/",
  ".gnupg/",
  ".aws/",
  ".kube/",
}

local DEFAULTS = {
  throttle_s = 60,
  fail_backoff_s = 10,
  exit_budget_ms = 5000,
  full_scan_s = 300,
  list_limit = 100,
}
-- name -> { min, max } of the validated numeric options
local RANGES = {
  throttle_s = { 0, 86400 },
  fail_backoff_s = { 1, 3600 },
  exit_budget_ms = { 0, 60000 },
  full_scan_s = { 0, 86400 },
  list_limit = { 1, 10000 },
}
local RETENTION_DEFAULTS = { auto = true, max_count = 1000, max_age_days = 30, interval_h = 6 }
local RETENTION_RANGES = { max_count = { 1, 1000000 }, max_age_days = { 1, 36500 }, interval_h = { 1, 8760 } }

--- Options of setup(). Invalid values are reported once and replaced by the default.
--- max_bytes: per-file cap in bytes (nil: 10 MB; <= 0: no cap).
--- max_total_bytes: budget of a whole snapshot (nil: 200 MB; <= 0: none).
--- throttle_s: seconds between two snapshots of a repo (0 .. 86400, default 60).
--- fail_backoff_s: seconds before a failed snapshot may be retried (1 .. 3600, default 10).
--- exit_budget_ms: how long nvim may wait for the exit snapshot when it takes it synchronously (0 .. 60000, default 5000).
--- exit_mode: "background" (default: a detached nvim records the last save after this one quit; falls back to "sync"
---   when it cannot be started), "sync" (quit waits, at most exit_budget_ms) or "off".
--- full_scan_s: at most this often the worktree is walked (0: always, default 300).
--- list_limit: snapshots listed by :LocalHistory (1 .. 10000, default 100).
--- exclude: nil = M.default_exclude; a list replaces it; false/{} = exclude nothing.
--- exclude_extra: list appended to the above.
--- push_guard: install a pre-push hook that refuses refs/lochist/* (only if there is no pre-push hook).
--- retention: { auto, max_count, max_age_days, interval_h }, false = no automatic pruning.
M.config = {
  commands = true,
  keymaps = false,
  max_bytes = nil,
  max_total_bytes = nil,
  throttle_s = DEFAULTS.throttle_s,
  fail_backoff_s = DEFAULTS.fail_backoff_s,
  exit_budget_ms = DEFAULTS.exit_budget_ms,
  exit_mode = "background",
  full_scan_s = DEFAULTS.full_scan_s,
  list_limit = DEFAULTS.list_limit,
  exclude = nil,
  exclude_extra = {},
  push_guard = false,
  retention = vim.deepcopy(RETENTION_DEFAULTS),
}

local MAX_BYTES = 10 * 1024 * 1024
local MAX_TOTAL_BYTES = 200 * 1024 * 1024
local FAST_MAX_PATHS = 500
local SESSION_START = os.time()
local last = {} ---@type table<string, number> time of the last SUCCESSFUL snapshot
local failed = {} ---@type table<string, number> time of the last failed one
local failures = {} ---@type table<string, { n: integer, reason: string, time: integer, notified: boolean? }>
local last_failure = {} ---@type table<string, { reason: string, time: integer }>
local running = {} ---@type table<string, boolean>
local runs = {} ---@type table<string, { dead: boolean, child: vim.SystemObj?, mine: table? }>
local indexes = {} ---@type table<string, string> root -> this process's index file
local gitdirs = {} ---@type table<string, string>
local prepared = {} ---@type table<string, boolean>
local warned = {} ---@type table<string, boolean> notify-once keys
local timers = {} ---@type table<string, uv.uv_timer_t>
local touched = {} ---@type table<string, table<string, boolean>> paths saved since the last snapshot
local fullscan = {} ---@type table<string, number> time of the last successful full scan
local sizes = {} ---@type table<string, table<string, number>> root -> rel -> size of the files counted in the budget
local purged = {} ---@type table<string, boolean> stale index entries removed (excluded names, big files)
local removed_big = {} ---@type table<string, table<string, boolean>>
local hardened = {} ---@type table<string, { pairs: string[][], empty_tree: string? }>
local autopruned = {} ---@type table<string, number> time of the last automatic prune
local deadline ---@type number? set (hrtime ms) only during the synchronous exit snapshot

-- ------------------------------------------------------------------ options

local function is_int_in(v, range)
  return type(v) == "number" and v == v and v >= range[1] and v <= range[2]
end

--- The effective value of a validated numeric option (a bad value set directly in M.config falls
--- back to the default instead of breaking the snapshot loop).
local function num(name)
  local v = M.config[name]
  if is_int_in(v, RANGES[name]) then
    return math.floor(v)
  end
  return DEFAULTS[name]
end

local function retention()
  local r = M.config.retention
  if r == false then
    return { auto = false }
  end
  r = type(r) == "table" and r or {}
  local out = { auto = r.auto ~= false }
  for k, range in pairs(RETENTION_RANGES) do
    local v = r[k]
    if v == false then
      out[k] = false
    elseif is_int_in(v, range) then
      out[k] = math.floor(v)
    else
      out[k] = RETENTION_DEFAULTS[k]
    end
  end
  return out
end

--- Check user options. Returns the cleaned table and a list of problems (strings).
local function validate(opts)
  local out, problems = {}, {}
  local function bad(msg)
    problems[#problems + 1] = msg
  end
  local known = {
    commands = "boolean",
    keymaps = "boolean|table",
    max_bytes = "number",
    max_total_bytes = "number",
    throttle_s = "number",
    fail_backoff_s = "number",
    exit_budget_ms = "number",
    full_scan_s = "number",
    list_limit = "number",
    exclude = "boolean|table",
    exclude_extra = "table",
    push_guard = "boolean",
    retention = "boolean|table",
    exit_mode = "string",
  }
  for k, v in pairs(opts) do
    local want = known[k]
    if not want then
      bad(("unknown option %q (ignored)"):format(k))
    elseif not vim.tbl_contains(vim.split(want, "|", { plain = true }), type(v)) then
      bad(("%s must be a %s, got %s (default kept)"):format(k, want:gsub("|", " or "), type(v)))
    elseif RANGES[k] and not is_int_in(v, RANGES[k]) then
      bad(
        ("%s must be a number between %d and %d, got %s (default %s kept)"):format(
          k,
          RANGES[k][1],
          RANGES[k][2],
          tostring(v),
          tostring(DEFAULTS[k])
        )
      )
    elseif k == "exit_mode" and not vim.tbl_contains({ "background", "sync", "off" }, v) then
      bad(('exit_mode must be "background", "sync" or "off", got %q (default kept)'):format(tostring(v)))
    elseif k == "exclude" and v == true then
      bad("exclude must be a list of patterns, false or nil, got true (default list kept)")
    elseif k == "exclude" or k == "exclude_extra" then
      local ok = true
      for i, p in ipairs(type(v) == "table" and v or {}) do
        if type(p) ~= "string" then
          ok = false
          bad(("%s[%d] must be a string pattern (list ignored)"):format(k, i))
          break
        end
      end
      if ok then
        out[k] = v
      end
    elseif k == "retention" and type(v) == "table" then
      local clean = {}
      for rk, rv in pairs(v) do
        if rk == "auto" and type(rv) == "boolean" then
          clean.auto = rv
        elseif RETENTION_RANGES[rk] and (rv == false or is_int_in(rv, RETENTION_RANGES[rk])) then
          clean[rk] = rv
        elseif RETENTION_RANGES[rk] or rk == "auto" then
          bad(
            ("retention.%s must be %s, got %s (default kept)"):format(
              rk,
              rk == "auto" and "a boolean"
                or ("false or a number between %d and %d"):format(RETENTION_RANGES[rk][1], RETENTION_RANGES[rk][2]),
              tostring(rv)
            )
          )
        else
          bad(("unknown option retention.%s (ignored)"):format(rk))
        end
      end
      out.retention = vim.tbl_extend("force", vim.deepcopy(RETENTION_DEFAULTS), clean)
    elseif k == "retention" and v == true then
      out.retention = vim.deepcopy(RETENTION_DEFAULTS)
    else
      out[k] = v
    end
  end
  return out, problems
end

-- ----------------------------------------------------- patterns and pathspecs

local function patterns()
  local ex = M.config.exclude
  local list = {}
  if ex == nil then
    list = vim.list_slice(M.default_exclude)
  elseif type(ex) == "table" then
    list = vim.list_slice(ex)
  end
  for _, p in ipairs(type(M.config.exclude_extra) == "table" and M.config.exclude_extra or {}) do
    list[#list + 1] = p
  end
  return list
end

--- One gitignore line per pattern, case-insensitive (every letter becomes [xX]); nil + reason for a pattern
--- that cannot be used. Patterns with "[" or "\\" are passed through as they are (case-sensitive).
local function pattern_line(p)
  p = vim.trim(type(p) == "string" and p or "")
  if p == "" or p:sub(1, 1) == "#" then
    return nil
  end
  if p:sub(1, 1) == "!" then
    return nil, "negation is not supported"
  end
  if p:gsub("/+$", ""):gsub("^/+", "") == "" then
    return nil, "empty pattern"
  end
  if p:find("[", 1, true) or p:find("\\", 1, true) then
    return p
  end
  return (p:gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end))
end

--- Write (once per content) the ignore file the snapshots use: the user's global ignore file followed by
--- the exclude patterns. Git's own ignore matching is fast (name and suffix patterns are hashed), unlike
--- 100 `:(exclude)` pathspecs, which cost over a second per scan of a 100k-file tree.
--- Returns the path, or nil + reason.
local function write_excludes_file(user_path)
  local lines = { "# xyno-history: generated, do not edit" }
  local f = user_path and io.open(user_path, "rb")
  if f then
    local text = f:read(1048576) or ""
    f:close()
    lines[#lines + 1] = "# --- " .. user_path
    lines[#lines + 1] = text
  end
  lines[#lines + 1] = "# --- exclude patterns of xyno-history"
  for _, p in ipairs(patterns()) do
    local l = pattern_line(p)
    if l then
      lines[#lines + 1] = l
    end
  end
  local content = table.concat(lines, "\n") .. "\n"
  local dir = vim.fn.stdpath("state") .. "/xyno-history"
  local path = dir .. "/excludes-" .. vim.fn.sha256(content):sub(1, 16)
  if vim.uv.fs_stat(path) then
    return path
  end
  vim.fn.mkdir(dir, "p")
  local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
  local w = io.open(tmp, "wb")
  if not w then
    return nil, "cannot write " .. dir
  end
  w:write(content)
  w:close()
  local ok, err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, "cannot write " .. path .. ": " .. tostring(err)
  end
  return path
end

-- ------------------------------------------------------------------ git calls

local NEUTRAL = {
  -- settings that make git run a command named by the repository's own config
  { "core.fsmonitor", "false" },
  { "core.hooksPath", vim.fn.has("win32") == 1 and "NUL" or "/dev/null" },
  { "core.sshCommand", "" },
  { "core.gitProxy", "" },
  { "core.pager", "cat" },
  { "core.editor", "true" },
  { "core.askPass", "" },
  { "core.alternateRefsCommand", "" },
  { "credential.helper", "" },
  { "diff.external", "" },
  { "gpg.program", "false" },
  { "commit.gpgsign", "false" },
  { "tag.gpgsign", "false" },
  { "maintenance.auto", "false" },
  { "protocol.allow", "never" },
  { "submodule.recurse", "false" },
  -- and the ones that would rewrite what is stored
  { "core.autocrlf", "false" },
  { "core.safecrlf", "false" },
  { "core.quotepath", "false" },
}

--- Environment for every git call on `root`: GIT_CONFIG_COUNT overrides (they rank as `git -c`, above every
--- config file including files pulled in by include.path), the work tree pinned to `root`, no prompts, no
--- optional locks, and attributes read from the empty tree, so .gitattributes can neither name a filter driver
--- nor convert line endings (the bytes stored are the bytes on disk). Extra variables win.
--- @param root string
--- @param extra? table<string, string>
--- @return table<string, string>
function M.git_env(root, extra)
  local env = {}
  local pairs_ = vim.list_extend(vim.list_slice(NEUTRAL), (hardened[root] or {}).pairs or {})
  env.GIT_CONFIG_COUNT = tostring(#pairs_)
  for i, kv in ipairs(pairs_) do
    env["GIT_CONFIG_KEY_" .. (i - 1)] = kv[1]
    env["GIT_CONFIG_VALUE_" .. (i - 1)] = kv[2]
  end
  env.GIT_TERMINAL_PROMPT = "0"
  env.GIT_OPTIONAL_LOCKS = "0"
  env.GIT_PAGER = "cat"
  if root then
    env.GIT_WORK_TREE = root
  end
  local empty = (hardened[root] or {}).empty_tree
  if empty then
    env.GIT_ATTR_SOURCE = empty
  end
  return vim.tbl_extend("force", env, extra or {})
end

--- `run` (optional) lets a caller abandon the chain: once run.dead is set the
--- callback never fires, and run.child is the git process to kill.
local function git(args, root, env, cb, raw, run, stdin)
  local cmd = vim.list_extend({ "git" }, args)
  -- text = true would turn CRLF into LF in stdout: raw reads (file contents, -z lists) must stay byte exact
  local sysopts = { cwd = root, env = M.git_env(root, env), text = not raw, stdin = stdin }
  local function done(o)
    cb(o.code == 0 and (raw and (o.stdout or "") or vim.trim(o.stdout or "")) or nil, o)
  end
  if deadline then
    local left = deadline - vim.uv.hrtime() / 1e6
    if left <= 0 then
      return cb(nil, { code = 124, stderr = "exit budget exhausted" })
    end
    return done(vim.system(cmd, sysopts):wait(math.floor(left)))
  end
  local child = vim.system(cmd, sysopts, function(o)
    vim.schedule(function()
      if not (run and run.dead) then
        done(o)
      end
    end)
  end)
  if run then
    run.child = child
  end
end

--- Abandon the snapshot chain of `root`: no further callbacks, git child killed.
local function abort(root, wait)
  local run = runs[root]
  if not run then
    return
  end
  run.dead = true
  runs[root] = nil
  for rel in pairs(run.mine or {}) do
    touched[root] = touched[root] or {}
    touched[root][rel] = true
  end
  if run.child then
    pcall(run.child.kill, run.child, 9)
    if wait then
      pcall(run.child.wait, run.child, 1000)
    end
  end
end

local function warn_once(key, msg, level)
  if not warned[key] then
    warned[key] = true
    vim.notify(msg, level or vim.log.levels.WARN)
  end
end

--- A short human reason from a failed git call.
local function why(what, o)
  local err = vim.trim((o and o.stderr) or "")
  local line
  for l in err:gmatch("[^\n]+") do
    if l:find("^fatal:") or l:find("^error:") then
      line = l
      break
    end
    line = line or l
  end
  return ("%s failed (exit %s)%s"):format(what, tostring(o and o.code), line and (": " .. line) or "")
end

--- Count a failed snapshot; tell the user once per failure episode (a lone failure that the retry
--- fixes stays quiet, `immediate` skips that wait). The reason is kept for :checkhealth.
local function record_failure(root, reason, immediate, message)
  local f = failures[root] or { n = 0 }
  f.n, f.reason, f.time = f.n + 1, reason, os.time()
  failures[root] = f
  last_failure[root] = { reason = reason, time = f.time }
  if (immediate or f.n >= 2) and not f.notified then
    f.notified = true
    vim.notify(
      message or ("local history: snapshots are failing, " .. reason .. " (details: :checkhealth xyno_history)"),
      vim.log.levels.WARN
    )
  end
end

local function encode(branch)
  return (branch:gsub("[%%/]", { ["%"] = "%25", ["/"] = "%2F" }))
end

--- cb(ref, legacy_ref?) : the ref to write and, for a detached HEAD, the
--- old-style shared "detached" ref (read-only).
local function ref_for(root, cb)
  git({ "symbolic-ref", "--short", "-q", "HEAD" }, root, nil, function(branch)
    if branch then
      return cb("refs/lochist/" .. encode(branch))
    end
    git({ "rev-parse", "--short=12", "-q", "--verify", "HEAD" }, root, nil, function(sha)
      cb("refs/lochist/%detached-" .. (sha or "none"), sha and "refs/lochist/detached" or nil)
    end)
  end)
end

--- cb(list of the given refs that exist)
local function existing(root, refs, cb)
  git({ "for-each-ref", "--format=%(refname)", "refs/lochist" }, root, nil, function(out)
    local have = {}
    for _, r in ipairs(vim.split(out or "", "\n", { plain = true })) do
      have[r] = true
    end
    cb(vim.tbl_filter(function(r)
      return r and have[r]
    end, refs))
  end)
end

local migrated = {} ---@type table<string, boolean>

--- Rename old-style refs/lochist/<a/b> to refs/lochist/<a%2Fb> (once per repo
--- per session), so stale directory-like refs cannot block a branch name.
local function migrate(root, cb)
  if migrated[root] then
    return cb()
  end
  migrated[root] = true
  git({ "for-each-ref", "--format=%(refname) %(objectname)", "refs/lochist" }, root, nil, function(out)
    local cmds = {}
    for _, l in ipairs(vim.split(out or "", "\n", { plain = true })) do
      local name, sha = l:match("^refs/lochist/(%S+) (%x+)$")
      if name and name:find("/", 1, true) then
        local new = "refs/lochist/" .. encode(name)
        -- encode() also escapes "%" in the name, matching what a branch of that name gets
        vim.list_extend(cmds, { ("create %s %s"):format(new, sha), ("delete refs/lochist/%s %s"):format(name, sha) })
      end
    end
    if #cmds == 0 then
      return cb()
    end
    local input = table.concat(cmds, "\n") .. "\n"
    -- one transaction; if the target already exists (create fails) nothing moves
    local function run()
      local cmd = { "git", "update-ref", "--stdin" }
      local sysopts = { cwd = root, env = M.git_env(root), stdin = input, text = true }
      if deadline then
        vim.system(cmd, sysopts):wait(2000)
        return cb()
      end
      vim.system(cmd, sysopts, function()
        vim.schedule(cb)
      end)
    end
    run()
  end)
end

local function stop_timer(root)
  local t = timers[root]
  if t then
    timers[root] = nil
    t:stop()
    if not t:is_closing() then
      t:close()
    end
  end
end

--- Earliest time a non-forced snapshot of `root` may start.
local function next_ok(root)
  return math.max((last[root] or 0) + num("throttle_s"), (failed[root] or 0) + num("fail_backoff_s"))
end

-- Arm (once) the trailing-edge timer for `root`. It is unref'd so it never
-- keeps nvim alive, and does nothing if the repo vanished meanwhile.
local function arm(root)
  if timers[root] then
    return
  end
  local wait_ms = math.max(1000, (next_ok(root) - os.time()) * 1000 + 500)
  local t = assert(vim.uv.new_timer())
  timers[root] = t
  t:unref()
  t:start(
    wait_ms,
    0,
    vim.schedule_wrap(function()
      if timers[root] ~= t then
        return
      end
      stop_timer(root)
      if vim.uv.fs_stat(root .. "/.git") then
        M.snapshot({ path = root, force = true, retried = true, trailing = true })
      else
        last[root] = nil
      end
    end)
  )
end

local pending = {} ---@type table<string, boolean>

local function pid_alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

--- A pre-push hook that refuses refs/lochist/*. Only written when the repository has no pre-push hook.
local GUARD_MARK = "xyno-history push guard"
local GUARD = [[#!/bin/sh
# ]] .. GUARD_MARK .. [[ (xyno-history.nvim, option push_guard): the Local History refs are
# private snapshots of the worktree and can contain secrets; `git push --mirror` would copy them.
while read local_ref local_sha remote_ref remote_sha; do
  case "$local_ref $remote_ref" in
    *refs/lochist/*)
      echo "xyno-history: refusing to push refs/lochist/* (Local History snapshots can contain secrets)" >&2
      exit 1
      ;;
  esac
done
exit 0
]]

--- Returns "installed" | "present" (ours already there) | "other" (somebody else's pre-push, left alone).
--- Never writes through core.hooksPath: the hooks directory is always <common git dir>/hooks.
local function install_push_guard(common)
  local hooks = common .. "/hooks"
  local path = hooks .. "/pre-push"
  local f = io.open(path, "rb")
  if f then
    local text = f:read("*a")
    f:close()
    return text:find(GUARD_MARK, 1, true) and "present" or "other"
  end
  vim.fn.mkdir(hooks, "p")
  local w = io.open(path, "wb")
  if not w then
    return "other"
  end
  w:write(GUARD)
  w:close()
  vim.uv.fs_chmod(path, tonumber("755", 8))
  return "installed"
end

--- Once per repo and session: keep /target/ (and the members') out via .git/info/exclude (additive
--- to .gitignore AND the user's global ignore, unlike core.excludesFile=),
--- drop the index files of dead nvim processes (the newest one seeds ours so
--- the first scan is incremental) and the old shared index.
local function prepare(root, gitdir, exclude)
  if prepared[root] then
    return
  end
  prepared[root] = true
  local mine = indexes[root]
  local lines = vim.uv.fs_stat(exclude) and vim.fn.readfile(exclude) or {}
  -- Anchored: a bare `target/` matched at any depth and hid `src/target/mod.rs` from git
  -- status, `git add -A` and the snapshots. The root and the workspace members (depth <= 2)
  -- get their own line; the unanchored line of an older version is migrated.
  local want = { "/target/" }
  for _, c in
    ipairs(
      vim.list_extend(
        vim.fn.glob(root .. "/*/Cargo.toml", true, true),
        vim.fn.glob(root .. "/*/*/Cargo.toml", true, true)
      )
    )
  do
    want[#want + 1] = "/" .. vim.fs.dirname(c):sub(#root + 2) .. "/target/"
  end
  local have, changed = {}, false
  for i, l in ipairs(lines) do
    if l == "target/" then
      lines[i], changed = "/target/", true
    end
    have[lines[i]] = true
    if lines[i]:match("^/target/?$") or lines[i] == "target" then
      have["/target/"] = true -- the user's own line already covers the root
    end
  end
  for _, w in ipairs(want) do
    if not have[w] then
      have[w] = true
      lines[#lines + 1] = w
      changed = true
    end
  end
  if changed then
    vim.fn.mkdir(vim.fs.dirname(exclude), "p")
    pcall(vim.fn.writefile, lines, exclude)
  end
  os.remove(gitdir .. "/lochist-exclude") -- replaced by info/exclude

  local seed, seed_t = nil, -1
  local stale = {}
  for _, p in ipairs(vim.fn.glob(gitdir .. "/lochist-index*", true, true)) do
    local base = p:gsub("%.lock$", "")
    local pid = base:match("lochist%-index%.(%d+)$")
    if base ~= mine and not (pid and pid_alive(tonumber(pid))) then
      stale[#stale + 1] = p
      local st = base == p and vim.uv.fs_stat(p) or nil
      if st and st.mtime.sec > seed_t then
        seed, seed_t = p, st.mtime.sec
      end
    end
  end
  if seed and not vim.uv.fs_stat(mine) then
    vim.uv.fs_copyfile(seed, mine)
  end
  for _, p in ipairs(stale) do
    os.remove(p)
  end
end

--- Where the user's own global ignore file is (core.excludesFile of the user's config, else git's default).
local function user_excludes_path(cb, root, run)
  git({ "config", "--global", "--type=path", "--get", "core.excludesFile" }, root, nil, function(p)
    if p and p ~= "" then
      return cb(p)
    end
    local home = vim.env.XDG_CONFIG_HOME
    if not home or home == "" then
      home = (vim.env.HOME or "") .. "/.config"
    end
    cb(home .. "/git/ignore")
  end, false, run)
end

--- Once per repo and session: learn the filter/diff driver names of the repository config (their
--- commands are replaced by `cat` / nothing, on top of the attribute source below) and the id of the
--- empty tree of this repository's hash algorithm (attributes are read from it).
local function harden(root, run, cb)
  local sig = vim.fn.sha256(table.concat(patterns(), "\0"))
  if hardened[root] and hardened[root].sig == sig then
    return cb()
  end
  purged[root] = nil -- a new exclude list: look for stale index entries again
  git(
    {
      "config",
      "--name-only",
      "--null",
      "--get-regexp",
      [[^(filter|diff|merge|mergetool|difftool)\..*\.(clean|smudge|process|textconv|command|driver|cmd)$]],
    },
    root,
    nil,
    function(out)
      local extra = {}
      for _, key in ipairs(vim.split(out or "", "\0", { plain = true })) do
        local name, what = key:match("^(.-)%.([^.]+)$")
        local kind = name and name:match("^(%a+)%.")
        if name and what then
          local lw = what:lower()
          local val = (lw == "clean" or lw == "smudge") and "cat" or ""
          extra[#extra + 1] = { key, val }
          if kind and kind:lower() == "filter" then
            extra[#extra + 1] = { name .. ".required", "false" }
          end
        end
      end
      git({ "hash-object", "-t", "tree", "/dev/null" }, root, nil, function(empty)
        user_excludes_path(function(user_path)
          local file, err = write_excludes_file(user_path)
          if file then
            extra[#extra + 1] = { "core.excludesFile", file }
          end
          hardened[root] = {
            sig = sig,
            pairs = extra,
            empty_tree = empty and empty:match("^%x+$") or nil,
            excludes = file,
            excludes_err = err,
          }
          cb()
        end, root, run)
      end, false, run)
    end,
    false,
    run
  )
end

--- A stale lock (killed git) older than a minute: remove it. `err` is git's stderr.
local function clear_stale_lock(err)
  local lock = (err or ""):match("Unable to create '([^']-%.lock)'")
  local st = lock and vim.uv.fs_stat(lock)
  if st and os.time() - st.mtime.sec > 60 then
    return os.remove(lock) ~= nil
  end
  return false
end

local function lock_error(err)
  return (err or ""):find(".lock'", 1, true) ~= nil or (err or ""):find("File exists", 1, true) ~= nil
end

local function size_cap()
  local v = M.config.max_bytes
  if v == nil then
    return MAX_BYTES
  end
  v = tonumber(v)
  if v == nil then
    return MAX_BYTES -- not a number: keep the default cap rather than silently lifting it
  end
  return v > 0 and v or nil
end

--- Per-snapshot budget for the files that pass the per-file cap (nil: no budget).
local function total_cap()
  local v = tonumber(M.config.max_total_bytes)
  if v == nil then
    return MAX_TOTAL_BYTES
  end
  return v > 0 and v or nil
end

local STAT_SLICE = 2000

local function note_big(root, rel, size, cap, budget)
  if budget then
    warn_once(
      "big:" .. root .. "/" .. rel,
      ("local history: skipping %s (%.0f MB; the snapshot is over %.0f MB, setup option max_total_bytes)"):format(
        rel,
        size / 1048576,
        budget / 1048576
      ),
      vim.log.levels.INFO
    )
  else
    warn_once(
      "big:" .. root .. "/" .. rel,
      ("local history: skipping %s (%.0f MB, over the %.0f MB cap; setup option max_bytes)"):format(
        rel,
        size / 1048576,
        cap / 1048576
      ),
      vim.log.levels.INFO
    )
  end
end

--- What to snapshot. mode "initial": the first scan of the session, files that are untracked or modified against
--- the user's real index; "full": the same against this process's private index (so only what changed since the
--- last snapshot); "fast": only the saved paths and what `git diff-files` reports.
--- cb(big, changed): `big` the files to leave out (over the per-file cap, or dropped for the total budget),
--- `changed` (fast mode) the paths to add; both nil when the scan itself failed.
local function scan(root, run, mode, env, mine, cb)
  local cap = size_cap()
  local budget = total_cap()
  sizes[root] = sizes[root] or {}
  local known = sizes[root]
  local big = {}
  local function judge(files, changed_out)
    local function step(from)
      local to = deadline and #files or math.min(from + STAT_SLICE - 1, #files)
      for i = from, to do
        local rel = files[i]
        local st = rel ~= "" and vim.uv.fs_stat(root .. "/" .. rel) or nil
        if st and st.type == "file" then
          if cap and st.size > cap and #big < 2000 then
            big[#big + 1] = rel
            known[rel] = nil
            note_big(root, rel, st.size, cap)
          else
            known[rel] = st.size
            if changed_out then
              changed_out[#changed_out + 1] = rel
            end
          end
        elseif rel ~= "" then
          known[rel] = nil -- gone, or not a plain file
          if changed_out then
            changed_out[#changed_out + 1] = rel
          end
        end
      end
      if to < #files then
        -- one fs_stat per listed file: 100k files froze the editor for ~0.5 to 1s in one go, so a
        -- slice per event-loop turn (not on exit, where `deadline` is set and nothing may wait)
        return vim.schedule(function()
          step(to + 1)
        end)
      end
      if mode ~= "fast" and budget then
        -- the snapshot as a whole: leave out the largest files until it fits the budget
        local total, kept = 0, {}
        for rel, size in pairs(known) do
          total = total + size
          kept[#kept + 1] = { rel, size }
        end
        if total > budget then
          table.sort(kept, function(a, b)
            if a[2] ~= b[2] then
              return a[2] > b[2]
            end
            return a[1] > b[1]
          end)
          for _, f in ipairs(kept) do
            if total <= budget or #big >= 2000 then
              break
            end
            total = total - f[2]
            big[#big + 1] = f[1]
            known[f[1]] = nil
            note_big(root, f[1], f[2], cap, budget)
          end
        end
      end
      cb(big, changed_out)
    end
    step(1)
  end
  if mode == "fast" then
    git({ "diff-files", "--name-only", "-z" }, root, env, function(out, o)
      if not out and o.code ~= 0 then
        return cb(nil)
      end
      local set, list = {}, {}
      for _, rel in ipairs(vim.split(out or "", "\0", { plain = true })) do
        if rel ~= "" and not set[rel] then
          set[rel] = true
          list[#list + 1] = rel
        end
      end
      for rel in pairs(mine or {}) do
        if not set[rel] then
          set[rel] = true
          list[#list + 1] = rel
        end
      end
      if #list > FAST_MAX_PATHS then
        return cb(nil, "too many")
      end
      table.sort(list)
      judge(list, {})
    end, true, run)
    return
  end
  -- full / initial: untracked or modified. The private index of a later scan makes this list short (files
  -- not yet snapshotted, files changed since); the first scan has nothing to compare with but the real index.
  git({ "ls-files", "-o", "-m", "--exclude-standard", "-z" }, root, mode == "full" and env or nil, function(out, o)
    if not out and o.code ~= 0 then
      return cb(nil)
    end
    judge(vim.split(out or "", "\0", { plain = true }))
  end, true, run)
end

--- Second half of a snapshot: commit the tree from `build(cb)` on top of the
--- branch's lochist ref. The ref moves with a compare-and-swap, so concurrent
--- nvims never overwrite each other's snapshot: on a mismatch or a lock the
--- parent is read again and the tree rebuilt (it is built after the parent is
--- read, so a stale tree cannot land on top of another instance's newer one).
local function commit_tree(root, build, env, opts, g, finish)
  migrate(root, function()
    ref_for(root, function(ref)
      local function attempt(n)
        g({ "rev-parse", "-q", "--verify", ref }, env, function(parent)
          local tree
          local function commit()
            local args = { "commit-tree", tree, "-m", opts.label or "autosave" }
            if parent then
              vim.list_extend(args, { "-p", parent })
            end
            g(args, env, function(c, co)
              if not c then
                return finish(nil, false, why("git commit-tree", co))
              end
              g({ "update-ref", ref, c, parent or "" }, env, function(_, uo)
                if uo.code == 0 then
                  return finish(c, true)
                end
                clear_stale_lock(uo.stderr)
                if n < 10 then
                  if deadline then
                    return attempt(n + 1)
                  end
                  return vim.defer_fn(function()
                    attempt(n + 1)
                  end, math.random(30, 150)) -- jitter: racers must not retry in lockstep
                end
                migrated[root] = nil -- retry the old-ref migration next time
                finish(
                  nil,
                  false,
                  why("git update-ref", uo),
                  "local history: update-ref failed: " .. vim.trim(uo.stderr or "")
                )
              end)
            end)
          end
          build(function(t)
            tree = t
            if not parent then
              return commit()
            end
            g({ "rev-parse", parent .. "^{tree}" }, env, function(prev_tree)
              if prev_tree == tree and not opts.mark then
                finish(nil, true) -- nothing changed since the last snapshot
              else
                commit()
              end
            end)
          end)
        end)
      end
      attempt(1)
    end)
  end)
end

local function stamp_path(root)
  return gitdirs[root] and (gitdirs[root] .. "/lochist-prune-stamp") or nil
end

local prune_async ---@type fun(root: string, policy: table, o: table)

--- After a successful snapshot: the automatic retention, at most once per interval_h per repository (the stamp
--- file lives in the git dir, so several nvims and several sessions share it), never in the first minute
--- of a session and never during the exit snapshot.
local function maybe_auto_prune(root)
  local r = retention()
  if not r.auto or deadline or os.time() - SESSION_START < 60 then
    return
  end
  if autopruned[root] and os.time() - autopruned[root] < r.interval_h * 3600 then
    return
  end
  local stamp = stamp_path(root)
  if not stamp then
    return
  end
  local st = vim.uv.fs_stat(stamp)
  if st and os.time() - st.mtime.sec < r.interval_h * 3600 then
    autopruned[root] = st.mtime.sec
    return
  end
  autopruned[root] = os.time()
  pcall(vim.fn.writefile, { tostring(os.time()) }, stamp)
  vim.schedule(function()
    prune_async(root, { keep = r.max_count or nil, days = r.max_age_days or nil }, { auto = true })
  end)
end

--- Snapshot the worktree containing `path` (a file or dir).
--- opts.force skips the throttle (and means a full scan unless opts.fast); opts.full forces a full scan.
--- @param opts? { path?: string, force?: boolean, label?: string, retried?: boolean, trailing?: boolean, fast?: boolean, full?: boolean, done?: fun(commit?: string) }
function M.snapshot(opts)
  opts = opts or {}
  local path = opts.path or vim.api.nvim_buf_get_name(0)
  local root = path ~= "" and vim.fs.root(path, ".git") or nil
  if not root then
    return
  end
  -- remember saved files for the fast path
  if path ~= root then
    local st = vim.uv.fs_stat(path)
    local rel = st and st.type == "file" and vim.fs.relpath(root, path) or nil
    if rel and rel ~= "." then
      touched[root] = touched[root] or {}
      touched[root][rel] = true
    end
  end
  if running[root] then
    -- A forced snapshot must not be dropped: retry once the running one ends
    -- (it gets 30 seconds at most, see the watchdog below).
    if opts.force then
      vim.defer_fn(function()
        M.snapshot(opts)
      end, 500)
    else
      -- only note it: finish() arms the timer once `last` is set. Armed here, the timer used the
      -- previous snapshot's age and forced one about 1 s later (a second commit within the throttle)
      pending[root] = true
    end
    return
  end
  if not opts.force and os.time() < next_ok(root) then
    pending[root] = true
    arm(root)
    return
  end
  pending[root] = nil
  stop_timer(root)
  running[root] = true
  local run = { dead = false }
  runs[root] = run
  local finished = false
  local mine = touched[root] or {}
  touched[root] = nil
  run.mine = mine
  local scanned_full = false
  --- @param ok? boolean the snapshot was taken or nothing had changed
  --- @param reason? string why it failed
  local function finish(commit, ok, reason, message)
    if finished then
      return
    end
    finished = true
    running[root] = nil
    if runs[root] == run then
      runs[root] = nil
    end
    if ok then
      last[root] = os.time()
      failed[root] = nil
      failures[root] = nil
      if scanned_full then
        fullscan[root] = os.time()
      end
      if pending[root] then
        arm(root)
      end
    else
      failed[root] = os.time()
      for rel in pairs(mine) do
        touched[root] = touched[root] or {}
        touched[root][rel] = true
      end
      record_failure(root, reason or "unknown error", message ~= nil, message)
      -- one retry of the unrecorded save once the backoff is over
      if not deadline and not opts.retried then
        pending[root] = true
        arm(root)
      end
    end
    if opts.done then
      opts.done(commit)
    end
    if ok and commit then
      maybe_auto_prune(root)
    end
  end
  local function g(args, env, cb, raw, stdin)
    git(args, root, env, cb, raw, run, stdin)
  end

  -- A hung git must not disable history for this repo until restart: kill it.
  if not deadline then
    vim.defer_fn(function()
      if not finished then
        abort(root)
        finish(nil, false, "git did not answer within 30 s and was killed")
      end
    end, 30000)
  end

  g({ "rev-parse", "--absolute-git-dir", "--path-format=absolute", "--git-path", "info/exclude" }, nil, function(out, o)
    local gitdir, exclude = unpack(vim.split(out or "", "\n", { plain = true }))
    if not gitdir or not exclude then
      return finish(nil, false, why("git rev-parse", o))
    end
    gitdirs[root] = gitdir
    local index = gitdir .. "/lochist-index." .. vim.uv.os_getpid()
    indexes[root] = index
    prepare(root, gitdir, exclude)
    if M.config.push_guard then
      local common = vim.fs.dirname(vim.fs.dirname(exclude))
      if install_push_guard(common) == "other" then
        warn_once(
          "guard:" .. root,
          "local history: push_guard is set but "
            .. common
            .. "/hooks/pre-push is not ours; left alone (see :checkhealth xyno_history)"
        )
      end
    end
    os.remove(index .. ".lock") -- ours alone: a leftover of a killed git
    local env = {
      GIT_INDEX_FILE = index,
      GIT_AUTHOR_NAME = "xyno-history",
      GIT_AUTHOR_EMAIL = "lochist@xyno-history",
      GIT_COMMITTER_NAME = "xyno-history",
      GIT_COMMITTER_EMAIL = "lochist@xyno-history",
    }
    harden(root, run, function()
      if not hardened[root].excludes then
        -- fail closed: without the ignore file the secrets would not be left out
        local err = hardened[root].excludes_err or "no exclude file"
        hardened[root] = nil
        return finish(nil, false, "cannot prepare the secrets exclude list: " .. err)
      end
      local have_index = vim.uv.fs_stat(index) ~= nil
      local mode = "initial"
      if fullscan[root] and have_index and not opts.full then
        local fresh = os.time() - fullscan[root] < num("full_scan_s")
        local wants_fast = not opts.force or opts.trailing or opts.fast
        if fresh and wants_fast and (num("full_scan_s") > 0) then
          mode = "fast"
        else
          mode = "full"
        end
      elseif fullscan[root] and have_index then
        mode = "full"
      end
      local function proceed(m)
        scan(root, run, m, env, mine, function(big, changed)
          if not big then
            if changed == "too many" then
              return proceed("full")
            end
            return finish(nil, false, "scanning the worktree failed")
          end
          scanned_full = m ~= "fast"
          local excl = {}
          for _, rel in ipairs(big) do
            excl[#excl + 1] = ":(exclude,literal)" .. rel
          end
          local add = { "add", "-A", "--ignore-errors", "--" }
          if m == "fast" then
            if #changed == 0 then
              add = nil
            else
              for _, rel in ipairs(changed) do
                add[#add + 1] = ":(literal)" .. rel
              end
              vim.list_extend(add, excl)
            end
          else
            add[#add + 1] = "."
            vim.list_extend(add, excl)
          end
          local function add_all(tries, cb)
            local function tree_of()
              g({ "write-tree" }, env, function(tree, wo)
                if not tree then
                  return finish(nil, false, why("git write-tree", wo))
                end
                cb(tree)
              end)
            end
            if not add then
              return tree_of()
            end
            g(add, env, function(_, ao)
              if ao.code ~= 0 and ao.code ~= 1 then
                if lock_error(ao.stderr) and tries < 2 then
                  os.remove(index .. ".lock")
                  clear_stale_lock(ao.stderr)
                  return add_all(tries + 1, cb)
                end
                if lock_error(ao.stderr) then
                  return finish(
                    nil,
                    false,
                    why("git add", ao),
                    "local history: git lock error, snapshots skipped: " .. vim.trim(ao.stderr or "")
                  )
                end
                return finish(nil, false, why("git add", ao))
              end
              tree_of()
            end)
          end
          local function build(cb)
            add_all(1, cb)
          end
          local function go()
            commit_tree(root, build, env, opts, g, finish)
          end
          -- entries that an older snapshot (or an older version of the exclude list) put into the
          -- index but that must stay out now: excluded names, and files that outgrew the cap
          local drop = {}
          for _, rel in ipairs(big) do
            removed_big[root] = removed_big[root] or {}
            if not removed_big[root][rel] then
              removed_big[root][rel] = true
              drop[#drop + 1] = ":(literal)" .. rel
            end
          end
          local function purge_big()
            if #drop > 0 and vim.uv.fs_stat(index) then
              local rm = { "rm", "--cached", "-r", "-q", "-f", "--ignore-unmatch", "--" }
              g(vim.list_extend(rm, drop), env, go)
            else
              go()
            end
          end
          if not purged[root] and have_index then
            purged[root] = true
            -- index entries that match the exclude patterns (an older version, an older list)
            g(
              {
                "ls-files",
                "-c",
                "-i",
                "-z",
                "--exclude-from=" .. (hardened[root].excludes or "/dev/null"),
              },
              env,
              function(list, lo)
                if not list and lo.code ~= 0 then
                  return finish(nil, false, why("git ls-files", lo))
                end
                if (list or "") == "" or not hardened[root].excludes then
                  return purge_big()
                end
                g(
                  {
                    "rm",
                    "--cached",
                    "-q",
                    "-f",
                    "--ignore-unmatch",
                    "--pathspec-from-file=-",
                    "--pathspec-file-nul",
                  },
                  vim.tbl_extend("force", env, { GIT_LITERAL_PATHSPECS = "1" }),
                  function(_, ro)
                    if ro.code ~= 0 then
                      return finish(nil, false, why("git rm --cached", ro))
                    end
                    purge_big()
                  end,
                  false,
                  list
                )
              end,
              true
            )
          else
            purged[root] = true
            purge_big()
          end
        end)
      end
      proceed(mode)
    end)
  end)
end

-- --------------------------------------------------------------- browse, restore

local function unquote(path)
  if path:sub(1, 1) ~= '"' then
    return path
  end
  local map = { n = "\n", t = "\t", ['"'] = '"', ["\\"] = "\\", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v" }
  local s = path
    :sub(2, -2)
    :gsub("\\(%d%d%d)", function(o)
      return string.char(tonumber(o, 8))
    end)
    :gsub("\\(.)", map)
  return s
end

--- Let the user pick a snapshot of the current file, following renames (git log --follow): older
--- snapshots that stored the file under another name are listed, and `rel_at` is the path in each.
--- @param cb fun(sel: { root: string, rel: string, rel_at: string, file: string, hash: string })
local function pick(cb)
  local file = vim.api.nvim_buf_get_name(0)
  local root = file ~= "" and vim.fs.root(file, ".git") or nil
  if not root then
    return vim.notify("not in a git worktree", vim.log.levels.WARN)
  end
  local rel = vim.fs.relpath(root, file)
  migrate(root, function()
    ref_for(root, function(ref, legacy)
      existing(root, { ref, legacy }, function(refs)
        if #refs == 0 then
          return vim.notify("no local history for " .. rel, vim.log.levels.INFO)
        end
        local args = vim.list_extend({ "log" }, refs)
        vim.list_extend(args, {
          "--follow",
          "--name-status",
          "-z",
          "--format=%x01%H%x09%ar%x09%s",
          "-n",
          tostring(num("list_limit")),
          "--diff-filter=d",
          "--",
          ":(literal)" .. rel,
        })
        git(args, root, nil, function(out)
          local items = {}
          for rec in (out or ""):gmatch("\1([^\1]+)") do
            local f = vim.split(rec, "\0", { plain = true })
            local hash, age, msg = unpack(vim.split(f[1], "\t", { plain = true }))
            local status = (f[2] or ""):gsub("^%s+", "")
            local at = (status:sub(1, 1) == "R" or status:sub(1, 1) == "C") and f[4] or f[3]
            if hash and at and at ~= "" then
              -- tab separated, as before; the 4th field (path in that snapshot) is new
              items[#items + 1] = table.concat({ hash, age or "", msg or "", (unquote(at):gsub("[\t\n]", " ")) }, "\t")
            end
          end
          if #items == 0 then
            return vim.notify("no local history for " .. rel, vim.log.levels.INFO)
          end
          vim.ui.select(items, {
            prompt = "Local history: " .. rel,
            format_item = function(l)
              local _, age, msg, at = unpack(vim.split(l, "\t", { plain = true }))
              return ("%s  %s%s"):format(age, msg, at and at ~= "" and at ~= rel and ("  [" .. at .. "]") or "")
            end,
          }, function(choice)
            if choice then
              local f = vim.split(choice, "\t", { plain = true })
              cb({
                root = root,
                rel = rel,
                rel_at = (f[4] and f[4] ~= "") and f[4] or rel,
                file = file,
                hash = f[1],
              })
            end
          end)
        end, true)
      end)
    end)
  end)
end

--- Turn the bytes of a snapshot into buffer lines the way the buffer would have read the file: converted from
--- the buffer's 'fileencoding', CRLF recognised (the buffer gets 'fileformat' dos so a write gives the same bytes
--- back), the missing last newline remembered. Returns lines, meta (ff, eol, bomb) or nil, error.
--- @param content string
--- @param buf? integer
function M._decode(content, buf)
  local fenc = (buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].fileencoding or ""):lower()
  local meta = { ff = "unix", eol = true, bomb = false }
  local text = content
  if text:sub(1, 3) == "\239\187\191" and (fenc == "" or fenc == "utf-8" or fenc == "utf8") then
    text, meta.bomb = text:sub(4), true
  elseif text:sub(1, 4) == "\255\254\0\0" and (fenc:find("^utf%-32") or fenc:find("^ucs%-4")) then
    text, meta.bomb = text:sub(5), true
  elseif
    (text:sub(1, 2) == "\255\254" or text:sub(1, 2) == "\254\255")
    and (fenc == "" or fenc:find("^utf%-16") or fenc:find("^ucs%-2"))
  then
    if fenc == "" then
      fenc = text:sub(1, 2) == "\255\254" and "utf-16le" or "utf-16"
    end
    text, meta.bomb = text:sub(3), true
  end
  if fenc ~= "" and fenc ~= "utf-8" and fenc ~= "utf8" then
    local conv = vim.iconv(text, fenc, "utf-8")
    if conv == nil then
      return nil, ("cannot convert the snapshot from %s"):format(fenc)
    end
    text = conv
  end
  local ends_nl = text:sub(-1) == "\n"
  meta.eol = text == "" or ends_nl
  local lines = text == "" and {} or vim.split(ends_nl and text:sub(1, -2) or text, "\n", { plain = true })
  local nl, crlf = 0, 0
  for i = 1, #lines do
    if i < #lines or ends_nl then
      nl = nl + 1
      if lines[i]:sub(-1) == "\r" then
        crlf = crlf + 1
      end
    end
  end
  if nl > 0 and crlf == nl then
    meta.ff = "dos"
    for i = 1, #lines do
      if i < #lines or ends_nl then
        lines[i] = lines[i]:sub(1, -2)
      end
    end
  end
  return lines, meta
end

--- Put a label on the current state of the repository of the current buffer: a snapshot that is taken
--- even when nothing changed since the last one, and shows up with the label in the panel.
--- @param text? string asked for when empty
--- @param cb? fun(commit: string?)
function M.label(text, cb)
  local path = vim.api.nvim_buf_get_name(0)
  local function go(label)
    label = vim.trim((label or ""):gsub("%s+", " "))
    if label == "" then
      return
    end
    M.snapshot({ path = path, force = true, label = label, mark = true, done = cb })
  end
  if text and vim.trim(text) ~= "" then
    go(text)
  else
    vim.ui.input({ prompt = "Local history label: " }, go)
  end
end

--- Pick an earlier snapshot of the current file and diff against it.
function M.browse()
  local buf = vim.api.nvim_get_current_buf()
  pick(function(s)
    git({ "cat-file", "blob", s.hash .. ":" .. s.rel_at }, s.root, nil, function(content)
      if not content then
        return vim.notify("file did not exist in that snapshot", vim.log.levels.WARN)
      end
      local lines, meta = M._decode(content, buf)
      if not lines then
        return vim.notify("local history: " .. tostring(meta), vim.log.levels.WARN)
      end
      vim.cmd("diffthis")
      vim.cmd("vertical new")
      vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile = "nofile", "wipe", false
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.filetype = vim.filetype.match({ filename = s.file }) or ""
      vim.api.nvim_buf_set_name(0, ("%s@%s"):format(s.rel_at, s.hash:sub(1, 8)))
      vim.cmd("diffthis")
    end, true)
  end)
end

--- Pick a snapshot and replace the current buffer's text with that version, including its line endings,
--- its encoding (the buffer's) and whether it ended in a newline, so writing the buffer gives the snapshot's
--- bytes back. Never touches the git index; the buffer is left modified (undo with `u`).
function M.restore()
  local buf = vim.api.nvim_get_current_buf()
  pick(function(s)
    git({ "cat-file", "blob", s.hash .. ":" .. s.rel_at }, s.root, nil, function(content)
      if not content then
        return vim.notify("file did not exist in that snapshot", vim.log.levels.WARN)
      end
      local lines, meta = M._decode(content, buf)
      if not lines then
        return vim.notify("local history: " .. tostring(meta) .. "; nothing restored", vim.log.levels.WARN)
      end
      vim.ui.select({ "Restore", "Cancel" }, {
        prompt = ("Replace %s with snapshot %s? (undo with u)"):format(s.rel, s.hash:sub(1, 8)),
      }, function(ans)
        if ans ~= "Restore" or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].fileformat = meta.ff
        vim.bo[buf].endofline = meta.eol
        if not meta.eol then
          vim.bo[buf].fixendofline = false
        end
        if meta.bomb then
          vim.bo[buf].bomb = true
        end
        vim.notify(("restored %s from %s (buffer modified, not saved)"):format(s.rel, s.hash:sub(1, 8)))
      end)
    end, true)
  end)
end

-- --------------------------------------------------------------------- prune

--- Run `fn` as a coroutine; inside, sysco() runs git without blocking the editor.
local function async(fn)
  local co = coroutine.create(fn)
  local function resume(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      vim.notify("local history: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  resume()
end

local function sysco(args, root, stdin)
  local co = assert(coroutine.running())
  vim.system(
    vim.list_extend({ "git" }, args),
    { cwd = root, env = M.git_env(root), text = true, stdin = stdin, timeout = 120000 },
    function(o)
      vim.schedule(function()
        local ok, err = coroutine.resume(co, o)
        if not ok then
          vim.notify("local history: " .. tostring(err), vim.log.levels.ERROR)
        end
      end)
    end
  )
  local o = coroutine.yield()
  return o.code == 0 and vim.trim(o.stdout or "") or nil, o
end

--- Drop old snapshots of every branch of `root` without blocking the editor. policy: { keep = N } keeps the
--- newest N per branch, { days = D } the last D days, both: the stricter of the two; at least the newest
--- snapshot always stays. The kept commits are re-created without the cut-off parent (one `git fast-import`),
--- then unreachable objects are collected with `git gc`, which is what frees the space
--- (o.now = `:LocalHistoryPrune!`: every unreachable object, also younger ones and other tools' dangling
--- commits, and a snapshot being written right now). o.auto: quiet, and `git gc --auto` instead of a gc.
prune_async = function(root, policy, o)
  async(function()
    local cutoff = policy.days and os.time() - policy.days * 86400
    local dropped, total = 0, 0
    local refs = sysco({ "for-each-ref", "--format=%(refname)", "refs/lochist" }, root) or ""
    for _, ref in ipairs(vim.split(refs, "\n", { plain = true })) do
      local log = ref ~= "" and sysco({ "log", ref, "--format=%H%x09%T%x09%ct%x09%s" }, root) or nil
      if log then
        local commits = {} -- newest first
        for _, l in ipairs(vim.split(log, "\n", { plain = true })) do
          local h, t, ct, msg = l:match("^(%x+)\t(%x+)\t(%d+)\t(.*)$")
          if h then
            commits[#commits + 1] = { h = h, t = t, ct = tonumber(ct), msg = msg }
          end
        end
        local n = #commits
        if policy.keep then
          n = math.min(n, policy.keep)
        end
        if cutoff then
          local young = 0
          for _, c in ipairs(commits) do
            young = young + (c.ct >= cutoff and 1 or 0)
          end
          n = math.min(n, young)
        end
        n = math.max(n, 1)
        total = total + #commits
        if n < #commits then
          local stream = {}
          for i = n, 1, -1 do
            local c = commits[i]
            local from = i < n and "from :" .. (n - i) .. "\n" or ""
            vim.list_extend(stream, {
              ('commit refs/xyno-history-prune\nmark :%d\ncommitter xyno-history <lochist@xyno-history> %d +0000\ndata %d\n%s\n%sM 040000 %s ""\n'):format(
                n - i + 1,
                c.ct,
                #c.msg,
                c.msg,
                from,
                c.t
              ),
            })
          end
          local tip = sysco({ "fast-import", "--quiet" }, root, table.concat(stream))
            and sysco({ "rev-parse", "refs/xyno-history-prune" }, root)
          if tip and sysco({ "update-ref", ref, tip, commits[1].h }, root) then
            dropped = dropped + #commits - n
          elseif not o.auto then
            vim.notify("local history: could not prune " .. ref, vim.log.levels.WARN)
          end
          sysco({ "update-ref", "-d", "refs/xyno-history-prune" }, root)
        end
      end
    end
    if o.auto then
      if dropped > 0 then
        sysco({ "gc", "--auto", "--quiet" }, root)
      end
      return
    end
    if dropped == 0 and not o.now then
      return vim.notify(("local history: nothing to prune (%d snapshots)"):format(total))
    end
    -- also with nothing left to drop when forced: the follow-up bang of an
    -- earlier prune still has the dangling commits to collect
    vim.notify(
      dropped == 0 and ("local history: nothing to drop (%d snapshots), collecting garbage..."):format(total)
        or ("local history: dropped %d of %d snapshots, collecting garbage..."):format(dropped, total)
    )
    local _, go = sysco({ "gc", "--quiet", o.now and "--prune=now" or "--prune=1.hour.ago" }, root)
    vim.notify(
      go.code == 0
          and ("local history: pruned, git gc done" .. (o.now and "" or " (objects younger than an hour: next gc, or :LocalHistoryPrune!)"))
        or "local history: git gc failed: " .. vim.trim(go.stderr or ""),
      go.code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end)
end

--- Drop old snapshots of every branch of the current repo, in the background. `arg`: "N" keeps the
--- newest N per branch, "Nd" keeps the last N days (default "30d"); see prune_async.
--- @param arg? string
--- @param now? boolean
function M.prune(arg, now)
  arg = vim.trim(arg or "")
  if arg == "" then
    arg = "30d"
  end
  local days, keep = arg:match("^(%d+)d$"), arg:match("^(%d+)$")
  if not ((days or keep) and tonumber(days or keep) > 0) then
    return vim.notify(
      "usage: :LocalHistoryPrune [N | Nd]  (keep the newest N snapshots per branch, or N days)",
      vim.log.levels.WARN
    )
  end
  local name = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(name ~= "" and name or vim.uv.cwd(), ".git")
  if not root then
    return vim.notify("not in a git worktree", vim.log.levels.WARN)
  end
  prune_async(root, { keep = keep and tonumber(keep), days = days and tonumber(days) }, { now = now })
end

-- ------------------------------------------------------------- status, setup

--- State for :checkhealth and scripts: per repository root of this session, when the last snapshot
--- succeeded, when the last full scan ran, the current failure (if any) and the last one ever.
--- @return table<string, { last_ok?: integer, last_full?: integer, failing?: { reason: string, n: integer, time: integer }, last_failure?: { reason: string, time: integer } }>
function M.status()
  local out = {}
  local function row(root)
    out[root] = out[root] or {}
    return out[root]
  end
  for root, t in pairs(last) do
    row(root).last_ok = t
  end
  for root, t in pairs(fullscan) do
    row(root).last_full = t
  end
  for root, f in pairs(failures) do
    row(root).failing = { reason = f.reason, n = f.n, time = f.time }
  end
  for root, f in pairs(last_failure) do
    row(root).last_failure = f
  end
  for root in pairs(indexes) do
    row(root)
  end
  for root in pairs(running) do
    row(root).running = true
  end
  for root in pairs(pending) do
    row(root).pending = true
  end
  return out
end

--- Snapshot refs of `root` (the current branch's, and the legacy ones that still exist), via cb(refs).
--- @param root string
--- @param cb fun(refs: string[])
function M._refs(root, cb)
  migrate(root, function()
    ref_for(root, function(ref, legacy)
      existing(root, { ref, legacy }, cb)
    end)
  end)
end

M._git = function(args, root, cb, raw)
  git(args, root, nil, cb, raw)
end

--- Statusline text for the current buffer's repository: "LH 2m" (age of the last snapshot), "LH ..." (one is
--- being taken), "LH ~" (a save waits for its snapshot), "LH !" (snapshots are failing) or "" (not in a
--- repository, nothing recorded yet this session). Cheap: no disk access beyond the first call per buffer.
--- @param buf? integer
--- @return string, string? text and highlight group
function M.statusline(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local root = vim.b[buf].xyno_history_root
  if root == nil then
    local name = vim.api.nvim_buf_get_name(buf)
    root = name ~= "" and vim.bo[buf].buftype == "" and vim.fs.root(name, ".git") or false
    vim.b[buf].xyno_history_root = root
  end
  if not root then
    return "", nil
  end
  if failures[root] then
    return "LH !", "XynoHistoryFailing"
  elseif running[root] then
    return "LH ...", "XynoHistoryPending"
  elseif pending[root] then
    return "LH ~", "XynoHistoryPending"
  elseif last[root] then
    local d = os.time() - last[root]
    local age = d < 90 and "now"
      or d < 5400 and (math.floor(d / 60 + 0.5) .. "m")
      or d < 129600 and (math.floor(d / 3600 + 0.5) .. "h")
      or (math.floor(d / 86400 + 0.5) .. "d")
    return "LH " .. age, "XynoHistoryOk"
  end
  return "", nil
end

function M.statusline_hl(buf)
  local _, hl = M.statusline(buf)
  return hl
end

local HL_LINKS = {
  XynoHistoryTitle = "Title",
  XynoHistoryAge = "Comment",
  XynoHistoryLabel = "Special",
  XynoHistoryMatch = "Search",
  XynoHistoryAdded = "DiagnosticOk",
  XynoHistoryModified = "DiagnosticWarn",
  XynoHistoryDeleted = "DiagnosticError",
  XynoHistoryRenamed = "DiagnosticInfo",
  XynoHistorySelected = "CursorLine",
  XynoHistoryHint = "NonText",
  XynoHistoryDiffAdd = "DiffAdd",
  XynoHistoryDiffDelete = "DiffDelete",
  XynoHistoryDiffHunk = "DiffChange",
  XynoHistoryOk = "DiagnosticOk",
  XynoHistoryPending = "DiagnosticWarn",
  XynoHistoryFailing = "DiagnosticError",
}
M.highlight_groups = vim.tbl_keys(HL_LINKS)

--- (Re)define the XynoHistory* groups as default links to theme groups; a colour you set yourself wins.
function M._define_highlights()
  for group, target in pairs(HL_LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

--- The patterns that apply (defaults, or yours, plus exclude_extra).
function M.exclude_patterns()
  return patterns()
end

M._guard_script = GUARD
M._install_push_guard = install_push_guard

-- ------------------------------------------------------------ exit snapshot

local WORKER = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/exit_worker.lua"

--- Hand the exit snapshot of `targets` (roots) to a detached nvim that outlives this one, so quitting
--- does not wait for git. Returns true when every worker was started; false means "do it here".
local function spawn_exit_workers(targets)
  if vim.fn.executable(vim.v.progpath) ~= 1 or not vim.uv.fs_stat(WORKER) then
    return false
  end
  local cfg = {}
  for k, v in pairs(M.config) do
    if type(v) ~= "function" and type(v) ~= "userdata" then
      cfg[k] = v
    end
  end
  -- read through the table (a caller may serve them from a metatable, as xynovim's vim.g caps do)
  cfg.max_bytes, cfg.max_total_bytes = M.config.max_bytes, M.config.max_total_bytes
  for _, root in ipairs(targets) do
    local gitdir = gitdirs[root] or (vim.uv.fs_stat(root .. "/.git") and root .. "/.git")
    local st = gitdir and vim.uv.fs_stat(gitdir)
    if not (st and st.type == "directory") then
      return false -- a worktree with a .git file: let the synchronous path sort it out
    end
    local paths = {}
    for rel in pairs(touched[root] or {}) do
      paths[#paths + 1] = rel
    end
    local file = ("%s/lochist-exit-%d.json"):format(gitdir, vim.uv.os_getpid())
    local ok_enc, json = pcall(vim.json.encode, {
      parent = vim.uv.os_getpid(),
      root = root,
      gitdir = gitdir,
      config = cfg,
      touched = paths,
      fullscan = fullscan[root],
    })
    local f = ok_enc and io.open(file, "wb")
    if not f then
      return false
    end
    f:write(json)
    f:close()
    local handle = vim.uv.spawn(vim.v.progpath, {
      args = { "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", WORKER, file },
      cwd = root,
      detached = true,
      stdio = { nil, nil, nil },
    }, function() end)
    if not handle then
      os.remove(file)
      return false
    end
    vim.uv.unref(handle)
  end
  return true
end

--- Used by exit_worker.lua: take over what the quitting session knew (saved paths, last full scan).
--- @param root string
--- @param rec { touched: string[], fullscan: number? }
function M._exit_import(root, rec)
  local t = {}
  for _, rel in ipairs(rec.touched or {}) do
    t[rel] = true
  end
  touched[root] = t
  fullscan[root] = rec.fullscan
end

--- Result of the last exit snapshot of `root` (written by the worker): { time, ok, reason? } or nil.
--- @param root string
function M.last_exit(root)
  local gitdir = gitdirs[root] or (root .. "/.git")
  local f = io.open(gitdir .. "/lochist-exit.json", "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, text)
  return ok and type(t) == "table" and t or nil
end

--- @param opts? { commands?: boolean, keymaps?: boolean|table<string,string>, max_bytes?: number, max_total_bytes?: number, throttle_s?: number, fail_backoff_s?: number, exit_budget_ms?: number, exit_mode?: string, full_scan_s?: number, list_limit?: number, exclude?: string[]|false, exclude_extra?: string[], push_guard?: boolean, retention?: table|boolean }
function M.setup(opts)
  local clean, problems = validate(opts or {})
  for _, list in ipairs({ clean.exclude or {}, clean.exclude_extra or {} }) do
    for _, pat in ipairs(type(list) == "table" and list or {}) do
      local _, bad = pattern_line(pat)
      if bad then
        problems[#problems + 1] = ("exclude pattern %q ignored: %s"):format(pat, bad)
      end
    end
  end
  if #problems > 0 then
    vim.notify("xyno-history: " .. table.concat(problems, "; "), vim.log.levels.WARN)
  end
  M.config = vim.tbl_extend("force", M.config, clean)
  purged = {} -- the exclude list may have changed: clean the index again
  for k in pairs(hardened) do
    hardened[k] = nil -- ... and the ignore file is written again
  end
  local group = vim.api.nvim_create_augroup("xyno_history", { clear = true })
  M._define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M._define_highlights })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "AutoSaveWritePost",
    callback = function(ev)
      local buf = ev.data and ev.data.saved_buffer
      -- still modified: the write was refused (a save guard refused it)
      if buf and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
        M.snapshot({ path = vim.api.nvim_buf_get_name(buf) })
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      M.snapshot({ path = ev.file })
    end,
  })
  -- Exit: drop timers; take one bounded synchronous snapshot per repo that
  -- still has an unrecorded save OR a snapshot in flight (that one's git is
  -- killed first: the async chain would die with nvim). It takes the fast
  -- path when the last full scan is recent (see full_scan_s).
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, root in ipairs(vim.tbl_keys(timers)) do
        stop_timer(root)
      end
      local mode = M.config.exit_mode
      local budget = num("exit_budget_ms")
      local roots = vim.deepcopy(pending)
      for root in pairs(runs) do
        roots[root] = true
      end
      local targets = {}
      for root in pairs(roots) do
        abort(root, true)
        running[root] = nil
        if mode ~= "off" and vim.uv.fs_stat(root .. "/.git") then
          targets[#targets + 1] = root
        end
      end
      if #targets > 0 and mode == "background" and spawn_exit_workers(targets) then
        pending = {}
        return
      end
      -- "sync", or the worker could not be started: record it here, bounded by exit_budget_ms
      deadline = vim.uv.hrtime() / 1e6 + budget
      for _, root in ipairs(targets) do
        if budget > 0 then
          pcall(M.snapshot, { path = root, force = true, fast = true })
        end
      end
      pending = {}
      deadline = nil
    end,
  })
  if M.config.commands then
    vim.api.nvim_create_user_command("LocalHistory", M.browse, { desc = "Browse local history of this file" })
    vim.api.nvim_create_user_command("LocalHistoryPanel", function(c)
      require("xyno_history.panel").open({ scope = c.args == "project" and "project" or "file" })
    end, {
      nargs = "?",
      complete = function()
        return { "file", "project" }
      end,
      desc = "Local history panel: snapshots, changed files, diff preview, revert, labels, content search",
    })
    vim.api.nvim_create_user_command("LocalHistoryLabel", function(c)
      M.label(c.args)
    end, {
      nargs = "?",
      desc = "Put a label on the current state of the repository (a snapshot even if nothing changed)",
    })
    vim.api.nvim_create_user_command("LocalHistoryPrune", function(c)
      M.prune(c.args, c.bang)
    end, {
      nargs = "?",
      bang = true,
      desc = "Drop old local-history snapshots: [N] newest per branch or [N]d days (default 30d)",
    })
    vim.api.nvim_create_user_command(
      "LocalHistoryRestore",
      M.restore,
      { desc = "Replace this buffer with a local-history snapshot (index untouched)" }
    )
  end
  local km = M.config.keymaps
  if km then
    -- true: <leader>gH browses; a table maps action ("browse", "panel", "label", "restore", "prune") to a lhs
    local maps = km == true and { browse = "<leader>gH" } or km
    local rhs = {
      panel = "<cmd>LocalHistoryPanel<cr>",
      label = "<cmd>LocalHistoryLabel<cr>",
      browse = "<cmd>LocalHistory<cr>",
      restore = "<cmd>LocalHistoryRestore<cr>",
      prune = "<cmd>LocalHistoryPrune<cr>",
    }
    for action, lhs in pairs(maps) do
      if rhs[action] and lhs then
        vim.keymap.set("n", lhs, rhs[action], { desc = "Local history: " .. action })
      end
    end
  end
end

return M
