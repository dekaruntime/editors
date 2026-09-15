-- Headless smoke test for deka.nvim (run from nvim/):
--   nvim --headless -u NONE --cmd "set rtp+=." "$TMPDIR/sample.ds" \
--     -c "luafile scripts/smoke.lua"
-- Writes results to $DEKA_SMOKE_OUT and force-exits.

local out = assert(io.open(vim.env.DEKA_SMOKE_OUT or '/dev/stderr', 'w'))
local function log(...)
  out:write(table.concat(vim.tbl_map(tostring, { ... }), ' '), '\n')
  out:flush()
end

local ok, err = pcall(function()
  -- Re-edit the sample so BufRead/FileType fire after the plugin loaded.
  vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.DEKA_SMOKE_SAMPLE or 'sample.ds'))
  log('ft:', vim.bo.filetype)
  local a = vim.api.nvim_get_autocmds({ group = 'deka' })
  log('autocmds:', #a)

  vim.defer_fn(function()
    local clients = vim.lsp.get_clients({ name = 'deka' })
    log('clients:', #clients)
    if clients[1] then
      log('cmd:', clients[1].config.cmd[1], clients[1].config.cmd[2])
      log('root:', tostring(clients[1].config.root_dir))
    end
    out:close()
    os.exit(#clients > 0 and 0 or 1)
  end, 3000)
end)
if not ok then
  log('ERROR:', err)
  out:close()
  os.exit(1)
end
