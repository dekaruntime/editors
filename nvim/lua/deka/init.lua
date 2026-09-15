--- DekaScript LSP attachment for Neovim (>= 0.11).
---
--- Zero required configuration: buffers ending in .ds/.dsx get the
--- `dekascript` filetype, and this plugin attaches `dsc lsp` (stdio) using
--- the shared binary-discovery search order (see lua/deka/discovery.lua and
--- the repo README).
---
--- Highlighting is provided by the tree-sitter parser
--- (dekaruntime/tree-sitter-deka) via nvim-treesitter; this plugin ships no
--- legacy syntax file on purpose.

local discovery = require('deka.discovery')

local M = {}

--- Test hook: when set, ensure_server uses this deps table instead of
--- host_deps(), so tests can drive the real discovery.resolve code with
--- real vim.system calls and no network (see tests/test_managed_download.lua).
M._test_deps = nil

local config = {
  --- Optional absolute path to the dsc binary (discovery level 1).
  server_path = nil,
  --- Workspace root markers, first match wins; falls back to the server cwd.
  root_markers = { 'deka.json', 'index.ds', '.git' },
  --- Extra arguments appended after `lsp`.
  extra_args = {},
}

local resolved_path = nil
local resolve_inflight = false
local pending_buffers = {}

--- Host wiring for the injectable discovery deps.
local function host_deps()
  local cache_dir = vim.fn.stdpath('data') .. '/deka'
  local uname = vim.uv.os_uname()
  return {
    override_path = config.server_path,
    cache_dir = cache_dir,
    platform = discovery.platform(uname.sysname, uname.machine),
    env = vim.env,
    executable = function(path)
      return vim.fn.executable(path) == 1
    end,
    exepath = function(cmd)
      local hit = vim.fn.exepath(cmd)
      return hit ~= '' and hit or nil
    end,
    mkdirp = function(dir)
      vim.fn.mkdir(dir, 'p')
    end,
    fetch_json = function(url, cb)
      vim.system({ 'curl', '-fsSL', url }, { text = true }, function(out)
        if out.code ~= 0 then
          return cb(string.format('GET %s failed: %s', url, (out.stderr or ''):gsub('%s+$', '')))
        end
        local ok, decoded = pcall(vim.json.decode, out.stdout)
        if not ok then
          return cb(string.format('GET %s returned invalid JSON', url))
        end
        cb(nil, decoded)
      end)
    end,
    download = function(url, dest, cb)
      vim.system({ 'curl', '-fsSL', '-o', dest, url }, {}, function(out)
        if out.code ~= 0 then
          return cb(string.format('GET %s failed (curl exit %d)', url, out.code))
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
          return cb(string.format('sha256 of %s failed', path))
        end
        local hex = out.stdout:match('^%s*([0-9a-fA-F]+)')
        if not hex then
          return cb(string.format('could not parse sha256 output for %s', path))
        end
        cb(nil, hex:lower())
      end)
    end,
    chmod_exec = function(path, cb)
      vim.system({ 'chmod', '755', path }, {}, function(out)
        if out.code ~= 0 then
          return cb(string.format('chmod 755 %s failed', path))
        end
        cb(nil)
      end)
    end,
    rename = function(from, to)
      os.rename(from, to)
    end,
  }
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = 'deka.nvim' })
end

local function start_lsp(bufnr)
  if resolved_path == nil then
    return false
  end
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = 'deka' })
  if #clients > 0 then
    return true
  end
  local root_dir = vim.fs.root(bufnr, config.root_markers)
  local cmd = { resolved_path, 'lsp' }
  vim.list_extend(cmd, config.extra_args)
  vim.lsp.start({
    name = 'deka',
    cmd = cmd,
    root_dir = root_dir,
    --- The server analyzes documents by URI (`.ds`); advertise its public id.
    filetypes = { 'dekascript' },
  }, { bufnr = bufnr })
  return true
end

local function on_resolved(path, source)
  resolved_path = path or false
  resolve_inflight = false
  if not path then
    notify_error(source)
    return
  end
  local buffers = pending_buffers
  pending_buffers = {}
  for _, bufnr in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'dekascript' then
      start_lsp(bufnr)
    end
  end
end

local function ensure_server(bufnr)
  if resolved_path ~= nil then
    return start_lsp(bufnr)
  end
  table.insert(pending_buffers, bufnr)
  if not resolve_inflight then
    resolve_inflight = true
    local deps = M._test_deps or host_deps()
    -- discovery.resolve may complete synchronously (override/cache/PATH) or
    -- asynchronously inside vim.system on_exit callbacks, which run in a
    -- fast-event context where most vim.api calls are illegal (E5560).
    -- Route every completion through vim.schedule_wrap so on_resolved always
    -- runs on the main loop.
    local on_resolved_scheduled = vim.schedule_wrap(on_resolved)
    if not deps.platform then
      return on_resolved_scheduled(nil, string.format(
        'DekaScript: unsupported platform %s/%s; dsc publishes darwin-arm64, darwin-x64, and linux-x64. %s',
        vim.uv.os_uname().sysname, vim.uv.os_uname().machine, discovery.INSTALL_HINT
      ))
    end
    deps.mkdirp(deps.cache_dir)
    discovery.resolve(deps, on_resolved_scheduled)
  end
  return true
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

  local group = vim.api.nvim_create_augroup('deka', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = group,
    pattern = { '*.ds', '*.dsx' },
    callback = function()
      vim.bo.filetype = 'dekascript'
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'dekascript',
    callback = function(event)
      ensure_server(event.buf)
    end,
  })
end

return M
