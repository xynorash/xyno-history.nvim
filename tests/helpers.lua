-- Utilities for the specs. `local H = require("xyno_history_test.helpers")`.
--
-- Assertions   H.eq H.ok H.not_ok H.is_nil H.match H.no_match H.has H.throws
-- Waiting      H.wait_for(pred, timeout_ms, msg)
-- Editor       H.feed(keys) H.open(path)
-- Processes    H.spawn(cmd)
-- Skipping     H.skip_file(reason) H.need_os({ "linux", "macos" }, reason)
-- Cleanup      H.cleanup() (the runner calls it at the end)
local harness = require("xyno_history_test.harness")

local H = {}
local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
H.repo = repo

-- ---------------------------------------------------------------- assertions

local function fail(msg, level)
  error(msg, (level or 1) + 1)
end

-- Windows spells one path several ways (D:\\a, D:/a, d:/a): compare the
-- canonical form (forward slashes, lower-case drive letter) there.
local function canon(v)
  if type(v) == "string" then
    if v:find("%f[%a]%a:[/\\]") then
      -- also drive paths embedded in a message ("coverage loaded (D:\\x\\y)")
      return (v:gsub("\\", "/"):gsub("%f[%a](%a):/", function(d)
        return d:lower() .. ":/"
      end))
    end
    return v
  elseif type(v) == "table" then
    local t = {}
    for k, x in pairs(v) do
      t[k] = canon(x)
    end
    return t
  end
  return v
end

function H.eq(expected, actual, msg)
  local same = vim.deep_equal(expected, actual)
  if not same and vim.fn.has("win32") == 1 then
    same = vim.deep_equal(canon(expected), canon(actual))
  end
  if not same then
    fail(
      ("%sexpected %s\n  actual   %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    fail(msg or ("expected a truthy value, got " .. vim.inspect(v)), 2)
  end
  return v
end

function H.not_ok(v, msg)
  if v then
    fail(msg or ("expected a falsy value, got " .. vim.inspect(v)), 2)
  end
end

function H.is_nil(v, msg)
  if v ~= nil then
    fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. vim.inspect(v), 2)
  end
end

--- Lua pattern match (plain = true for a literal substring).
function H.match(str, pat, plain, msg)
  if type(str) ~= "string" or not str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s does not match %q"):format(vim.inspect(str), pat), 2)
  end
end

function H.no_match(str, pat, plain, msg)
  if type(str) == "string" and str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s unexpectedly matches %q"):format(vim.inspect(str), pat), 2)
  end
end

--- A list contains `item` (deep compare), or a string contains the substring.
function H.has(container, item, msg)
  local found = false
  if type(container) == "string" then
    found = container:find(item, 1, true) ~= nil
  else
    for _, v in ipairs(container) do
      if vim.deep_equal(v, item) then
        found = true
        break
      end
    end
  end
  if not found then
    fail(
      (msg and (msg .. ": ") or "") .. ("%s does not contain %s"):format(vim.inspect(container), vim.inspect(item)),
      2
    )
  end
end

--- fn must raise an error (matching `pat`, a Lua pattern, when given).
function H.throws(fn, pat)
  local ok, e = pcall(fn)
  if ok then
    fail("expected an error, none raised", 2)
  end
  if pat and not tostring(e):find(pat) then
    fail(("error %q does not match %q"):format(tostring(e), pat), 2)
  end
end

-- ------------------------------------------------------------------ waiting

--- Wait until pred() is truthy (vim.wait, the event loop keeps running).
--- Returns its value; raises `msg` on timeout.
function H.wait_for(pred, timeout_ms, msg)
  local value
  local done = vim.wait(timeout_ms or 5000, function()
    value = pred()
    return value and true or false
  end, 20)
  if not done then
    fail("timed out waiting for " .. (msg or "condition"), 2)
  end
  return value
end

-- ------------------------------------------------------------------- editor

--- Type keys as if typed (mappings apply). Processes them before returning.
function H.feed(keys, mode)
  local k = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(k, mode or "x", false)
end

--- :edit a file. Returns the buffer number.
function H.open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Text of :messages.
function H.messages()
  return vim.api.nvim_exec2("messages", { output = true }).output
end

--- "linux", "macos" or "windows".
H.os = vim.fn.has("win32") == 1 and "windows" or vim.fn.has("mac") == 1 and "macos" or "linux"
H.is_win = H.os == "windows"

--- Skip the test (or, at load time, the file) unless this platform is in `list`.
function H.need_os(list, reason)
  if not vim.tbl_contains(list, H.os) then
    harness.skip(("needs %s, this is %s: %s"):format(table.concat(list, " or "), H.os, reason))
  end
end

function H.skip_file(reason)
  harness.skip(reason)
end

H._dirs, H._jobs, H._restore = {}, {}, {}

--- A fresh empty directory, removed by cleanup().
function H.tmpdir()
  local base = vim.env.XYNO_HISTORY_TEST_TMP
  if not base or base == "" then
    base = vim.fs.dirname(vim.fn.tempname())
  end
  local dir = assert(vim.uv.fs_mkdtemp(base .. "/spec-XXXXXX"))
  H._dirs[#H._dirs + 1] = dir
  if H.os ~= "linux" then
    -- one spelling of the path: macOS /var is /private/var (cargo prints the
    -- latter), Windows has short 8.3 names and backslashes
    dir = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
  end
  return dir
end

--- Start a background process (killed by cleanup). Returns the vim.SystemObj.
function H.spawn(cmd, opts)
  local obj = vim.system(cmd, opts or {})
  H._jobs[#H._jobs + 1] = obj
  return obj
end

--- Kill jobs, wipe buffers, run the registered restores, delete temp dirs.
function H.cleanup()
  for _, fn in ipairs(H._restore) do
    pcall(fn)
  end
  H._restore = {}
  for _, j in ipairs(H._jobs) do
    pcall(function()
      j:kill(15)
      j:wait(2000)
    end)
  end
  H._jobs = {}
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
  for _, d in ipairs(H._dirs) do
    vim.fn.delete(d, "rf")
  end
  H._dirs = {}
end

return H
