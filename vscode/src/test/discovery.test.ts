import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DSC_VERSION,
  DiscoveryDeps,
  INSTALL_HINT,
  RELEASE_BASE_URL,
  currentPlatform,
  resolveDsc,
} from '../discovery';

const PLATFORM = 'darwin-arm64';
const BINARY = 'dsc-darwin-arm64';

interface MockState {
  executables: Set<string>;
  env: NodeJS.ProcessEnv;
  manifest?: unknown;
  downloadSha256: string;
  downloads: Array<{ url: string; dest: string }>;
  chmods: string[];
  renames: Array<{ from: string; to: string }>;
  fetchErrors?: Error;
}

function mockDeps(overrides: Partial<DiscoveryDeps> = {}, state?: MockState): {
  deps: DiscoveryDeps;
  state: MockState;
} {
  const s: MockState = state ?? {
    executables: new Set(),
    env: {},
    manifest: {
      version: DSC_VERSION,
      binaries: {
        'darwin-arm64': { name: BINARY, sha256: 'abc123' },
      },
    },
    downloadSha256: 'abc123',
    downloads: [],
    chmods: [],
    renames: [],
  };
  const deps: DiscoveryDeps = {
    cacheDir: '/cache',
    platform: PLATFORM,
    env: s.env,
    async isExecutableFile(path) {
      return s.executables.has(path);
    },
    async fetchJson(url) {
      if (s.fetchErrors) throw s.fetchErrors;
      return s.manifest;
    },
    async downloadToFile(url, dest) {
      s.downloads.push({ url, dest });
    },
    async sha256File() {
      return s.downloadSha256;
    },
    async chmodExecutable(path) {
      s.chmods.push(path);
    },
    async renameFile(from, to) {
      s.renames.push({ from, to });
    },
    ...overrides,
  };
  return { deps, state: s };
}

test('currentPlatform maps node platform/arch to published artifacts', () => {
  assert.equal(currentPlatform('darwin', 'arm64'), 'darwin-arm64');
  assert.equal(currentPlatform('darwin', 'x64'), 'darwin-x64');
  assert.equal(currentPlatform('linux', 'x64'), 'linux-x64');
  assert.equal(currentPlatform('linux', 'arm64'), null);
  assert.equal(currentPlatform('win32', 'x64'), null);
});

test('level 1: explicit override wins when executable', async () => {
  const { deps, state } = mockDeps({ overridePath: '/opt/custom/dsc' });
  state.executables.add('/opt/custom/dsc');
  state.executables.add('/bundled/' + BINARY);
  const result = await resolveDsc(deps);
  assert.deepEqual(result, { kind: 'found', path: '/opt/custom/dsc', source: 'override' });
});

test('level 1: unusable override falls through to bundled', async () => {
  const { deps, state } = mockDeps({
    overridePath: '/opt/custom/dsc',
    bundledDir: '/bundled',
  });
  state.executables.add('/bundled/' + BINARY);
  const result = await resolveDsc(deps);
  assert.deepEqual(result, {
    kind: 'found',
    path: '/bundled/' + BINARY,
    source: 'bundled',
  });
});

test('level 2: cached managed download is reused', async () => {
  const { deps, state } = mockDeps();
  state.executables.add('/cache/' + BINARY);
  const result = await resolveDsc(deps);
  assert.deepEqual(result, {
    kind: 'found',
    path: '/cache/' + BINARY,
    source: 'downloaded',
  });
  assert.equal(state.downloads.length, 0, 'no re-download when cache hit');
});

test('level 3: non-executable DEKA_DSC does not short-circuit discovery', async () => {
  const { deps, state } = mockDeps({ env: { DEKA_DSC: '/env/dsc' } });
  const result = await resolveDsc(deps);
  // /env/dsc is not executable, so discovery falls through to managed download.
  assert.deepEqual(result, {
    kind: 'found',
    path: '/cache/' + BINARY,
    source: 'downloaded',
  });
  assert.equal(state.downloads.length, 1);
});

test('level 3: DEKA_DSC executable wins over download', async () => {
  const { deps, state } = mockDeps({ env: { DEKA_DSC: '/env/dsc' } });
  state.executables.add('/env/dsc');
  const result = await resolveDsc(deps);
  assert.deepEqual(result, { kind: 'found', path: '/env/dsc', source: 'path' });
  assert.equal(state.downloads.length, 0);
});

test('level 3: dsc found on PATH via PATH scan', async () => {
  const { deps, state } = mockDeps({ env: { PATH: '/usr/local/bin:/usr/bin' } });
  state.executables.add('/usr/local/bin/dsc');
  const result = await resolveDsc(deps);
  assert.deepEqual(result, { kind: 'found', path: '/usr/local/bin/dsc', source: 'path' });
});

test('level 4: full miss triggers pinned, checksum-verified download', async () => {
  const { deps, state } = mockDeps({ env: { PATH: '/usr/bin' } });
  const result = await resolveDsc(deps);
  assert.equal(result.kind, 'found');
  if (result.kind === 'found') {
    assert.equal(result.source, 'downloaded');
    assert.equal(result.path, '/cache/' + BINARY);
  }
  assert.deepEqual(state.downloads, [
    {
      url: `${RELEASE_BASE_URL}/v${DSC_VERSION}/${BINARY}`,
      dest: `/cache/${BINARY}.tmp-${process.pid}`,
    },
  ]);
  assert.deepEqual(state.chmods, [`/cache/${BINARY}.tmp-${process.pid}`]);
  assert.deepEqual(state.renames, [
    { from: `/cache/${BINARY}.tmp-${process.pid}`, to: `/cache/${BINARY}` },
  ]);
});

test('level 4: manifest version mismatch refuses the download', async () => {
  const { deps, state } = mockDeps({ env: { PATH: '/usr/bin' } });
  state.manifest = {
    version: '99.0.0',
    binaries: { 'darwin-arm64': { name: BINARY, sha256: 'abc123' } },
  };
  const result = await resolveDsc(deps);
  assert.equal(result.kind, 'error');
  if (result.kind === 'error') assert.match(result.message, /managed download failed/);
});

test('level 4: checksum mismatch refuses to install the binary', async () => {
  const { deps, state } = mockDeps({ env: { PATH: '/usr/bin' } });
  state.downloadSha256 = 'tampered';
  const result = await resolveDsc(deps);
  assert.equal(result.kind, 'error');
  if (result.kind === 'error') assert.match(result.message, /managed download failed/);
});

test('level 4: skipCache forces re-download even with a cached copy', async () => {
  const { deps, state } = mockDeps({ skipCache: true, env: { PATH: '/usr/bin' } });
  state.executables.add('/cache/' + BINARY);
  const result = await resolveDsc(deps);
  assert.equal(result.kind, 'found');
  assert.equal(state.downloads.length, 1, 're-downloaded despite cache hit');
});

test('level 5: total failure produces a clear error with the one-command fix', async () => {
  const { deps, state } = mockDeps({ env: { PATH: '/usr/bin' } });
  state.fetchErrors = new Error('network down');
  const result = await resolveDsc(deps);
  assert.equal(result.kind, 'error');
  if (result.kind === 'error') {
    assert.match(result.message, /DekaScript language server/);
    assert.match(result.message, /INSTALL_HINT_PLACEHOLDER|Install dsc/);
    assert.ok(result.message.includes(INSTALL_HINT), 'error embeds the install hint');
    assert.match(result.message, /dsc on PATH/);
  }
});
