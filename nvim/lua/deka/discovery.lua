--- Binary discovery for the DekaScript language server.
---
--- The editor-facing server is `dsc lsp` (stdio), shipped inside the `dsc`
--- compiler binary published at https://dsc-wasm.deka.gg/v{VERSION}/ with
--- sha256 checksums in that version's release.json (same host/pattern as
--- dekaruntime/deka's scripts/ci-install-dsc.sh).
---
--- Search order (kept identical to the VS Code and Zed implementations, see
--- the repo README):
---   1. explicit override (setup { server_path = ... })
---   2. previously downloaded copy in the managed cache
---   3. `dsc` on PATH (DEKA_DSC env honored like deka's own lookup)
---   4. managed download, version-pinned + checksum-verified, then cached
---   5. clear error with a one-command fix
---
--- All host effects go through `deps` so the search order is unit-testable
--- with mocks (see tests/test_discovery.lua). Host wiring lives in
--- lua/deka/init.lua.

local M = {}

-- Pinned dsc release. Bump with deka's scripts/dsc-version pin.
M.DSC_VERSION = '0.53.4'
M.RELEASE_BASE_URL = 'https://dsc-wasm.deka.gg'
M.INSTALL_HINT = 'Install dsc: curl -fsSL https://deka.gg/install.sh | bash'

--- Map `uname`-style sys/machine to the published artifact platform.
function M.platform(sys, machine)
  if sys == 'Darwin' and machine == 'arm64' then
    return 'darwin-arm64'
  end
  if sys == 'Darwin' and (machine == 'x86_64' or machine == 'amd64') then
    return 'darwin-x64'
  end
  if sys == 'Linux' and (machine == 'x86_64' or machine == 'amd64') then
    return 'linux-x64'
  end
  return nil
end

--- Validate a release.json manifest: version pin plus per-platform sha256.
--- Returns sha256 string or nil, err string.
function M.manifest_sha256(manifest, want_version, platform_key)
  if type(manifest) ~= 'table' then
    return nil, 'release manifest is not a table'
  end
  if manifest.version ~= want_version then
    return nil, string.format(
      'release manifest describes version %s, not %s',
      tostring(manifest.version), want_version
    )
  end
  local entry = manifest.binaries
    and manifest.binaries[platform_key]
  local sha = entry and entry.sha256
  if type(sha) ~= 'string' or sha == '' then
    return nil, string.format('no %s binary in the release manifest', platform_key)
  end
  return sha, nil
end

--- deps:
---   executable(path) -> boolean
---   env                -> table (optional; defaults to DEKA_DSC unset)
---   exepath(cmd)       -> string|nil   (PATH lookup)
---   cache_dir          -> string
---   override_path      -> string|nil
---   platform           -> e.g. "darwin-arm64"
---   download(url, dest, cb(err))           write file
---   fetch_json(url, cb(err, table))
---   sha256_file(path, cb(err, hex))
---   chmod_exec(path, cb(err))
---   mkdirp(dir)
--- cb receives (path, source) on success or (nil, err) on failure.
function M.resolve(deps, cb)
  local env = deps.env or {}
  local tried = {}

  local function fail(err)
    cb(nil, string.format(
      'The DekaScript language server (dsc) could not be located. Tried: %s. %s. %s',
      table.concat(tried, '; '), err or 'managed download failed', M.INSTALL_HINT
    ))
  end

  local function download()
    local manifest_url = string.format('%s/v%s/release.json', M.RELEASE_BASE_URL, M.DSC_VERSION)
    deps.fetch_json(manifest_url, function(err, manifest)
      if err then
        return fail(string.format('managed download failed: %s', err))
      end
      local sha, sha_err = M.manifest_sha256(manifest, M.DSC_VERSION, deps.platform)
      if not sha then
        return fail(string.format('managed download failed: %s', sha_err))
      end
      local binary_name = string.format('dsc-%s', deps.platform)
      local dest = string.format('%s/%s', deps.cache_dir, binary_name)
      local tmp = dest .. '.tmp'
      deps.download(string.format('%s/v%s/%s', M.RELEASE_BASE_URL, M.DSC_VERSION, binary_name), tmp, function(dl_err)
        if dl_err then
          return fail(string.format('managed download failed: %s', dl_err))
        end
        deps.sha256_file(tmp, function(hash_err, actual)
          if hash_err then
            return fail(string.format('managed download failed: %s', hash_err))
          end
          if actual ~= sha then
            return fail(string.format(
              'managed download failed: checksum mismatch for dsc %s v%s (expected %s, got %s)',
              deps.platform, M.DSC_VERSION, sha, actual
            ))
          end
          deps.chmod_exec(tmp, function(chmod_err)
            if chmod_err then
              return fail(string.format('managed download failed: %s', chmod_err))
            end
            if deps.rename then
              deps.rename(tmp, dest)
            end
            cb(dest, 'downloaded')
          end)
        end)
      end)
    end)
  end

  local function from_path()
    local env_override = env.DEKA_DSC
    if env_override and deps.executable(env_override) then
      return cb(env_override, 'path')
    end
    local on_path = deps.exepath('dsc')
    if on_path and on_path ~= '' then
      return cb(on_path, 'path')
    end
    table.insert(tried, 'dsc on PATH')
    download()
  end

  local function from_cache()
    local binary_name = string.format('dsc-%s', deps.platform)
    local cached = string.format('%s/%s', deps.cache_dir, binary_name)
    if deps.executable(cached) then
      return cb(cached, 'downloaded')
    end
    table.insert(tried, deps.cache_dir)
    from_path()
  end

  -- 1. explicit override
  if deps.override_path and deps.override_path ~= '' then
    if deps.executable(deps.override_path) then
      return cb(deps.override_path, 'override')
    end
    table.insert(tried, string.format('override %s (not executable)', deps.override_path))
  end
  from_cache()
end

return M
