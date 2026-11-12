-- :checkhealth xyno_history
local M = {}

local function git(root, args)
  local lh = require("xyno_history")
  local o = vim.system(vim.list_extend({ "git" }, args), { cwd = root, env = lh.git_env(root), text = true }):wait(10000)
  return o.code == 0 and vim.trim(o.stdout or "") or nil, o
end

local function ago(t)
  local d = os.time() - t
  if d < 90 then
    return d .. " s ago"
  elseif d < 5400 then
    return math.floor(d / 60 + 0.5) .. " min ago"
  elseif d < 129600 then
    return math.floor(d / 3600 + 0.5) .. " h ago"
  end
  return math.floor(d / 86400 + 0.5) .. " days ago"
end

local function version_of(text)
  local a, b, c = (text or ""):match("(%d+)%.(%d+)%.?(%d*)")
  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

local function check_repo(h, lh, root)
  h.start("xyno-history: " .. root)
  local st = lh.status()[root] or {}
  if st.failing then
    h.error(
      ("snapshots are failing since %s (%d attempts): %s"):format(ago(st.failing.time), st.failing.n, st.failing.reason),
      { "Run the failing git command by hand in the repository to see the cause.", "A snapshot is retried after fail_backoff_s and on the next save." }
    )
  else
    if st.last_failure then
      h.warn(("the last failed snapshot was %s (%s); snapshots work again"):format(ago(st.last_failure.time), st.last_failure.reason))
    end
    if st.last_ok then
      h.ok("last snapshot of this session: " .. ago(st.last_ok))
    elseif not st.last_failure then
      h.info("no snapshot taken yet in this session (the first save takes one)")
    end
  end

  local ex = lh.last_exit(root)
  if ex then
    if ex.ok then
      h.ok("the last exit snapshot (taken by the background worker) succeeded " .. ago(ex.time or 0))
    else
      h.warn(("the last exit snapshot failed %s: %s"):format(ago(ex.time or 0), ex.reason or "unknown"), { "The save it owed is picked up by the next full scan; run the failing git command by hand to see the cause." })
    end
  end
  local leftovers = vim.fn.glob(root .. "/.git/lochist-exit-*.json", true, true)
  if #leftovers > 0 then
    h.info(#leftovers .. " exit handoff file(s) in .git: a background worker is running or was killed (they are harmless)")
  end

  local refs = git(root, { "for-each-ref", "--format=%(refname) %(committerdate:unix) %(objectname)", "refs/lochist" })
  if refs and refs ~= "" then
    local n, newest = 0, 0
    for l in refs:gmatch("[^\n]+") do
      n = n + 1
      newest = math.max(newest, tonumber(l:match(" (%d+) ")) or 0)
    end
    h.ok(("%d branch ref(s) under refs/lochist, newest snapshot %s"):format(n, newest > 0 and ago(newest) or "?"))
  else
    h.info("no refs/lochist/* in this repository yet")
  end
  if st.last_full then
    h.info(("last full worktree scan: %s (full_scan_s = %d; saves in between take the fast path)"):format(ago(st.last_full), lh.config.full_scan_s))
  end

  -- repository config that the plugin neutralises
  local cfg = git(
    root,
    { "config", "--local", "--name-only", "--get-regexp", [[^(core\.(fsmonitor|hookspath|sshcommand|gitproxy|pager|editor|askpass|worktree|alternaterefscommand)|credential\..*|diff\.external|filter\..*|include\.path|includeif\..*)$]] }
  )
  if cfg and cfg ~= "" then
    h.warn(
      "the repository config sets options that make git run commands or move the work tree: " .. table.concat(vim.split(cfg, "\n", { plain = true }), ", "),
      { "xyno-history ignores them (every git call overrides them); review who put them there." }
    )
  else
    h.ok("the repository config sets nothing that xyno-history has to override")
  end

  -- push exposure
  local mirror = git(root, { "config", "--get-regexp", [[^remote\..*\.mirror$]] })
  local mirrors = {}
  for l in (mirror or ""):gmatch("[^\n]+") do
    local name, val = l:match("^remote%.(.-)%.mirror (%S+)$")
    if name and val == "true" then
      mirrors[#mirrors + 1] = name
    end
  end
  local common = git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  local hook = common and (common .. "/hooks/pre-push")
  local f = hook and io.open(hook, "rb")
  local hook_text = f and f:read("*a") or nil
  if f then
    f:close()
  end
  local guarded = hook_text and hook_text:find("xyno-history push guard", 1, true) ~= nil
  local hooks_path = git(root, { "config", "--get", "core.hooksPath" })
  if #mirrors > 0 then
    h.warn(
      ("remote(s) %s have mirror = true: a plain `git push` copies refs/lochist/* (snapshots, possibly with secrets) to them"):format(table.concat(mirrors, ", ")),
      { "git config --unset remote.<name>.mirror", "or install the guard: require('xyno_history').setup({ push_guard = true })" }
    )
  end
  if guarded then
    h.ok("push guard installed: a pre-push hook refuses refs/lochist/*")
    if hooks_path and hooks_path ~= "" then
      h.warn("core.hooksPath is set (" .. hooks_path .. "): git does not run .git/hooks/pre-push, the guard is inactive")
    end
  elseif hook_text then
    h.warn("a pre-push hook exists that is not xyno-history's: `git push --mirror` is only blocked if it refuses refs/lochist/* itself")
  else
    h.info(
      "refs/lochist/* is private but `git push --mirror`, `git push --all`-less mirrors and `git clone --mirror` copy it; no push guard installed",
      { "setup({ push_guard = true }) installs a pre-push hook that refuses refs/lochist/*", "see the README section 'Secrets and pushing'" }
    )
  end
end

function M.check()
  local h = vim.health
  local lh = require("xyno_history")
  h.start("xyno-history")

  local out = vim.system({ "git", "--version" }, { text = true }):wait(5000)
  if out.code ~= 0 then
    h.error("git not found in $PATH")
    return
  end
  local a, b = version_of(out.stdout)
  h.ok(vim.trim(out.stdout))
  if a < 2 or (a == 2 and b < 38) then
    h.warn("git older than 2.38: filter/diff driver commands from the repository config are not enumerated and neutralised", { "upgrade git" })
  end
  if a < 2 or (a == 2 and b < 41) then
    h.warn("git older than 2.41 has no GIT_ATTR_SOURCE: .gitattributes in the worktree can still convert line endings in snapshots", { "upgrade git" })
  else
    h.ok("attributes are read from the empty tree: .gitattributes cannot run filters or convert line endings")
  end

  if #vim.api.nvim_get_autocmds({ group = "xyno_history" }) > 0 then
    h.ok("setup() has run (autocmds registered)")
  else
    h.warn("setup() has not run: no snapshots are taken", { "call require('xyno_history').setup() (see the README for a lazy.nvim spec)" })
  end

  local c = lh.config
  h.info(
    ("throttle_s=%s fail_backoff_s=%s full_scan_s=%s exit_budget_ms=%s list_limit=%s"):format(c.throttle_s, c.fail_backoff_s, c.full_scan_s, c.exit_budget_ms, c.list_limit)
  )
  h.info(("exit_mode = %s (%s)"):format(c.exit_mode, c.exit_mode == "background" and "a detached nvim records the last save after quitting; falls back to waiting up to exit_budget_ms" or c.exit_mode == "sync" and "quitting waits for the snapshot, at most exit_budget_ms" or "no exit snapshot"))
  for _, grp in ipairs(lh.highlight_groups) do
    if next(vim.api.nvim_get_hl(0, { name = grp, link = true })) == nil then
      h.warn("highlight group " .. grp .. " is not defined", { "setup() defines them; a :hi clear without a ColorScheme event removed it" })
    end
  end
  local pats = lh.exclude_patterns()
  if #pats == 0 then
    h.warn("the secrets exclude list is empty: every untracked file that .gitignore does not cover goes into the snapshots", { "remove `exclude = false` / `exclude = {}` from your setup()" })
  elseif c.exclude == nil then
    h.ok(("%d default secret patterns are left out of snapshots (.env*, *.pem, *.key, id_rsa* ...)"):format(#pats))
  else
    h.ok(("%d custom secret patterns are left out of snapshots"):format(#pats))
  end
  local r = c.retention
  if r == false or (type(r) == "table" and r.auto == false) then
    h.warn("automatic retention is off: snapshots stay until :LocalHistoryPrune", { "retention = { max_count = 1000, max_age_days = 30 } is the default" })
  else
    r = type(r) == "table" and r or {}
    h.ok(("automatic retention: newest %s per branch, %s days, checked every %s h"):format(tostring(r.max_count), tostring(r.max_age_days), tostring(r.interval_h)))
  end
  if c.push_guard then
    h.ok("push_guard = true")
  end

  local seen = {}
  local name = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(name ~= "" and name or vim.uv.cwd(), ".git")
  if root then
    seen[root] = true
    check_repo(h, lh, root)
  else
    h.info("the current buffer is not in a git worktree")
  end
  for other in pairs(lh.status()) do
    if not seen[other] then
      seen[other] = true
      check_repo(h, lh, other)
    end
  end
end

return M
