-- Regression test for the managed-download fast-event crash (E5560).
--
-- Run like CI does:
--   nvim --headless -u NONE -l tests/test_managed_download.lua
--
-- Before the fix, `discovery.resolve(deps, on_resolved)` handed on_resolved to
-- vim.system on_exit callbacks directly. Those run in a fast-event context
-- where vim.api.nvim_buf_is_valid is illegal, so every first-time install
-- (dsc not on PATH, nothing cached) crashed with:
--   E5560: nvim_buf_is_valid must not be called in a fast event context
-- This test drives the REAL ensure_server -> discovery.resolve code with the
-- REAL vim.system-based deps (local files instead of the network, so the
-- on_exit callbacks still fire in a true fast-event context) and asserts the
-- LSP attach happens cleanly.

local script = arg and arg[0] or ''
local root = script:match('^(.*)/tests/test_managed_download%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local discovery = require('deka.discovery')
local deka = require('deka')

local uname = vim.uv.os_uname()
local platform = discovery.platform(uname.sysname, uname.machine)
if not platform then
  io.stderr:write('SKIP - unsupported host ', uname.sysname, '/', uname.machine, '\n')
  os.exit(0)
end

-- Fixture tree under TMPDIR (never /tmp): a fake downloaded binary plus its
-- release manifest, served to the plugin via local vim.system calls.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local cache_dir = dir .. '/cache'
local fake_bin = dir .. '/dsc-fake'
local manifest_path = dir .. '/release.json'
do
  local f = assert(io.open(fake_bin, 'w'))
  f:write('#!/bin/sh\necho fake dsc\n')
  f:close()
  local sha = vim.fn.system({ 'shasum', '-a', '256', fake_bin }):match('^%s*([0-9a-fA-F]+)')
  if not sha then
    sha = vim.fn.system({ 'sha256sum', fake_bin }):match('^%s*([0-9a-fA-F]+)')
  end
  assert(sha, 'could not sha256 the fixture binary')
  f = assert(io.open(manifest_path, 'w'))
  f:write(string.format(
    '{"version": "%s", "binaries": {"%s": {"name": "dsc-%s", "sha256": "%s"}}}',
    discovery.DSC_VERSION, platform, platform, sha:lower()
  ))
  f:close()
end

-- Host deps with every async effect going through real vim.system calls, so
-- completion lands in a genuine fast-event context; fs/network never leave
-- the fixture dir and dsc is neither cached nor on PATH (forces level 4).
local deps = {
  override_path = nil,
  cache_dir = cache_dir,
  platform = platform,
  env = {},
  executable = function() return false end,
  exepath = function() return nil end,
  mkdirp = function(d) vim.fn.mkdir(d, 'p') end,
  fetch_json = function(_, cb)
    vim.system({ 'cat', manifest_path }, { text = true }, function(out)
      if out.code ~= 0 then
        return cb('cat manifest failed: ' .. (out.stderr or ''))
      end
      local ok, decoded = pcall(vim.json.decode, out.stdout)
      if not ok then
        return cb('manifest is not JSON')
      end
      cb(nil, decoded)
    end)
  end,
  download = function(_, dest, cb)
    vim.system({ 'cp', fake_bin, dest }, {}, function(out)
      if out.code ~= 0 then
        return cb('copy failed: ' .. (out.stderr or ''))
      end
      cb(nil)
    end)
  end,
  sha256_file = function(path, cb)
    local tool = { 'shasum', '-a', '256', path }
    if uname.sysname == 'Linux' then
      tool = { 'sha256sum', path }
    end
    vim.system(tool, { text = true }, function(out)
      if out.code ~= 0 then
        return cb('sha256 failed: ' .. (out.stderr or ''))
      end
      local hex = out.stdout:match('^%s*([0-9a-fA-F]+)')
      if not hex then
        return cb('could not parse sha256 output for ' .. path)
      end
      cb(nil, hex:lower())
    end)
  end,
  chmod_exec = function(path, cb)
    vim.system({ 'chmod', '755', path }, {}, function(out)
      if out.code ~= 0 then
        return cb('chmod failed: ' .. (out.stderr or ''))
      end
      cb(nil)
    end)
  end,
  rename = function(from, to) os.rename(from, to) end,
}

deka._test_deps = deps

local started = {}
local real_start = vim.lsp.start
vim.lsp.start = function(cfg, opts)
  started.cfg = cfg
  started.opts = opts
  started.in_fast_event = vim.in_fast_event()
  return 1
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, dir .. '/sample.ds')
deka.setup({})
vim.api.nvim_buf_call(buf, function()
  vim.bo.filetype = 'dekascript'
end)

local ok_wait = vim.wait(10000, function()
  return started.cfg ~= nil
end, 50)

local errmsg = vim.v.errmsg
vim.lsp.start = real_start

if not ok_wait or not started.cfg then
  io.stderr:write(
    'FAIL - managed download never attached the LSP client\n',
    '       (pre-fix this is the E5560 fast-event crash killing on_resolved):\n',
    '       v:errmsg = ', tostring(errmsg), '\n'
  )
  vim.fn.delete(dir, 'rf')
  os.exit(1)
end

local want_bin = cache_dir .. '/dsc-' .. platform
if started.cfg.cmd[1] ~= want_bin then
  io.stderr:write('FAIL - attached server is ', tostring(started.cfg.cmd[1]),
    ', expected managed-downloaded ', want_bin, '\n')
  vim.fn.delete(dir, 'rf')
  os.exit(1)
end

if started.in_fast_event then
  io.stderr:write('FAIL - vim.lsp.start ran inside a fast-event context\n')
  vim.fn.delete(dir, 'rf')
  os.exit(1)
end

vim.fn.delete(dir, 'rf')
io.write('ok   - managed download attaches LSP with no fast-event errors (E5560 regression)\n')
