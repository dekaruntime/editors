-- Helper for scripts/check-dsc-version.sh: print the dsc version that the
-- real nvim plugin resolves (repo-root DSC_VERSION file when present, else
-- the shipped fallback constant), so CI can fail on pin drift.

local root = arg and arg[1] or '.'
package.path = root .. '/nvim/lua/?.lua;' .. root .. '/nvim/lua/?/init.lua;' .. package.path

local discovery = require('deka.discovery')
io.write(discovery.DSC_VERSION)
