-- Unit tests for lua/deka/discovery.lua, runnable with either:
--   nvim --headless -l tests/test_discovery.lua
--   lua tests/test_discovery.lua          (if a standalone lua is available)
--
-- The discovery module takes all host effects through `deps`, so these tests
-- run with a fully mocked fs/PATH/network.

local script = arg and arg[0] or ''
local root = script:match('^(.*)/tests/test_discovery%.lua$') or '.'
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local discovery = require('deka.discovery')

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write('ok   - ', name, '\n')
  else
    failed = failed + 1
    io.write('FAIL - ', name, '\n       ', tostring(err), '\n')
  end
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format('%s: expected %s, got %s', what or 'eq', tostring(expected), tostring(actual)), 2)
  end
end

local PLATFORM = 'darwin-arm64'
local BINARY = 'dsc-darwin-arm64'

--- Build a mock deps table. `state` captures calls; `state.files` is the set
--- of executable files.
local function mock_deps(opts, state)
  opts = opts or {}
  state = state or {}
  state.files = state.files or {}
  state.tried_exepath = state.tried_exepath or false
  local deps = {
    cache_dir = '/cache',
    platform = PLATFORM,
    env = opts.env or {},
    override_path = opts.override_path,
    executable = function(path)
      return state.files[path] == true
    end,
    exepath = function(cmd)
      state.tried_exepath = true
      return state.on_path
    end,
    fetch_json = function(url, cb)
      state.fetched_url = url
      if state.fetch_err then
        return cb(state.fetch_err)
      end
      cb(nil, state.manifest or {
        version = discovery.DSC_VERSION,
        binaries = { [PLATFORM] = { name = BINARY, sha256 = 'abc123' } },
      })
    end,
    download = function(url, dest, cb)
      state.downloaded = { url = url, dest = dest }
      cb(state.download_err)
    end,
    sha256_file = function(path, cb)
      cb(nil, state.file_sha or 'abc123')
    end,
    chmod_exec = function(path, cb)
      state.chmodded = path
      cb()
    end,
    rename = function(from, to)
      state.renamed = { from = from, to = to }
    end,
  }
  return deps, state
end

local function resolve_sync(deps)
  local out = {}
  discovery.resolve(deps, function(path, source)
    out.path = path
    out.source = source
  end)
  return out
end

test('platform maps uname pairs to published artifacts', function()
  eq(discovery.platform('Darwin', 'arm64'), 'darwin-arm64')
  eq(discovery.platform('Darwin', 'x86_64'), 'darwin-x64')
  eq(discovery.platform('Linux', 'x86_64'), 'linux-x64')
  eq(discovery.platform('Linux', 'arm64'), nil)
  eq(discovery.platform('Windows', 'x86_64'), nil)
end)

test('manifest_sha256 validates the version pin', function()
  local sha, err = discovery.manifest_sha256({ version = '99', binaries = {} }, discovery.DSC_VERSION, PLATFORM)
  eq(sha, nil)
  assert(err:match('describes version'), 'error names the mismatch')
end)

test('manifest_sha256 extracts the platform sha256', function()
  local sha = discovery.manifest_sha256({
    version = discovery.DSC_VERSION,
    binaries = { [PLATFORM] = { name = BINARY, sha256 = 'deadbeef' } },
  }, discovery.DSC_VERSION, PLATFORM)
  eq(sha, 'deadbeef')
end)

test('level 1: override wins when executable', function()
  local deps, state = mock_deps({ override_path = '/opt/custom/dsc' })
  state.files['/opt/custom/dsc'] = true
  state.files['/cache/' .. BINARY] = true
  local out = resolve_sync(deps)
  eq(out.path, '/opt/custom/dsc', 'path')
  eq(out.source, 'override', 'source')
end)

test('level 1: unusable override falls through to cache', function()
  local deps, state = mock_deps({ override_path = '/opt/custom/dsc' })
  state.files['/cache/' .. BINARY] = true
  local out = resolve_sync(deps)
  eq(out.path, '/cache/' .. BINARY)
  eq(out.source, 'downloaded')
end)

test('level 2: cached copy reused, no network touched', function()
  local deps, state = mock_deps()
  state.files['/cache/' .. BINARY] = true
  local out = resolve_sync(deps)
  eq(out.path, '/cache/' .. BINARY)
  eq(out.source, 'downloaded')
  eq(state.downloaded, nil, 'no download')
end)

test('level 3: DEKA_DSC honored when executable', function()
  local deps, state = mock_deps({ env = { DEKA_DSC = '/env/dsc' } })
  state.files['/env/dsc'] = true
  local out = resolve_sync(deps)
  eq(out.path, '/env/dsc')
  eq(out.source, 'path')
  eq(state.downloaded, nil)
end)

test('level 3: dsc on PATH wins over download', function()
  local deps, state = mock_deps()
  state.on_path = '/usr/local/bin/dsc'
  local out = resolve_sync(deps)
  eq(out.path, '/usr/local/bin/dsc')
  eq(out.source, 'path')
  eq(state.downloaded, nil)
end)

test('level 4: full miss downloads pinned, checksum-verified binary', function()
  local deps, state = mock_deps()
  local out = resolve_sync(deps)
  eq(out.path, '/cache/' .. BINARY)
  eq(out.source, 'downloaded')
  eq(state.fetched_url, string.format('%s/v%s/release.json', discovery.RELEASE_BASE_URL, discovery.DSC_VERSION))
  eq(state.downloaded.url, string.format('%s/v%s/%s', discovery.RELEASE_BASE_URL, discovery.DSC_VERSION, BINARY))
  eq(state.chmodded, '/cache/' .. BINARY .. '.tmp')
  eq(state.renamed.to, '/cache/' .. BINARY)
end)

test('level 4: checksum mismatch refuses to install', function()
  local deps, state = mock_deps()
  state.file_sha = 'tampered'
  local out = resolve_sync(deps)
  eq(out.path, nil)
  assert(out.source:match('checksum mismatch'), 'error explains the mismatch')
end)

test('level 4: manifest version mismatch refuses the download', function()
  local deps, state = mock_deps()
  state.manifest = { version = '99.0.0', binaries = { [PLATFORM] = { name = BINARY, sha256 = 'abc123' } } }
  local out = resolve_sync(deps)
  eq(out.path, nil)
  assert(out.source:match('managed download failed'), 'error mentions managed download')
end)

test('level 5: total failure gives a clear error with the install hint', function()
  local deps, state = mock_deps()
  state.fetch_err = 'network down'
  local out = resolve_sync(deps)
  eq(out.path, nil)
  assert(out.source:match('could not be located'), 'error says what happened')
  assert(out.source:match('dsc on PATH'), 'error lists what was tried')
  assert(out.source:find(discovery.INSTALL_HINT, 1, true) ~= nil, 'error embeds the one-command fix')
end)

io.write(string.format('\n%d passed, %d failed\n', passed, failed))
if failed > 0 then
  os.exit(1)
end
