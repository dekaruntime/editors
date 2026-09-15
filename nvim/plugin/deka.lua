-- Zero-config entry: as soon as the plugin is on &runtimepath, set up
-- filetype detection and LSP attachment. Users who want options call
-- require('deka').setup{...} from their config; plugin managers that call
-- setup themselves can set g.deka_no_auto_setup to skip this.
if vim.g.deka_no_auto_setup then
  return
end
require('deka').setup()
