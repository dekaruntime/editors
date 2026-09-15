-- Extends smoke.lua: after the client attaches, send a real LSP request
-- (textDocument/completion) and a pull-diagnostics request, log the results.
local out = assert(io.open(vim.env.DEKA_SMOKE_OUT or '/dev/stderr', 'w'))
local function log(...)
  out:write(table.concat(vim.tbl_map(tostring, { ... }), ' '), '\n')
  out:flush()
end

vim.cmd('edit ' .. vim.fn.fnameescape(vim.env.DEKA_SMOKE_SAMPLE or 'sample.ds'))
log('ft:', vim.bo.filetype)

vim.defer_fn(function()
  local client = vim.lsp.get_clients({ name = 'deka' })[1]
  if not client then
    log('no client')
    out:close()
    os.exit(1)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding or 'utf-16')
  client.request('textDocument/completion', params, function(err, result)
    log('completion err:', tostring(err))
    local items = result and (result.items or result) or {}
    log('completion items:', #items)
    client.request('textDocument/diagnostic', { textDocument = params.textDocument }, function(derr, dresult)
      log('diagnostic err:', tostring(derr))
      local kinds = dresult and dresult.items or {}
      log('diagnostic items:', #kinds)
      out:close()
      os.exit(0)
    end, bufnr)
  end, bufnr)
end, 2000)
