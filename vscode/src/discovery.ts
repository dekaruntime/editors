// Binary discovery for the DekaScript language server.
//
// The editor-facing server is `dsc lsp` (stdio), shipped inside the `dsc`
// compiler binary published at https://dsc-wasm.deka.gg/v{VERSION}/ with
// sha256 checksums in that version's release.json (same host/pattern as
// dekaruntime/deka's scripts/ci-install-dsc.sh).
//
// Search order (kept identical in the Zed and Neovim implementations):
//   1. explicit override (deka.server.path setting)
//   2. project-scoped: node_modules/.bin/dsc, walked up from the open
//      document's folder and each workspace folder. This is the exact
//      runtime a project pins via @dekaruntime/deka (dsc ships next to deka,
//      in lockstep version), so it wins over this extension's own
//      DSC_VERSION pin below, which can lag behind what a project installed.
//   3. bundled / previously downloaded copy in the managed cache
//   4. `dsc` on PATH
//   5. managed download, version-pinned + checksum-verified, then cached
//   6. clear error with a one-command fix
//
// All effects are injected through DiscoveryDeps so the whole module is
// unit-testable with a mocked fs/PATH/network (see src/test/discovery.test.ts).

// DSC_VERSION lives in ./dsc-version.ts, generated from the repo-root
// DSC_VERSION file (the single source of truth across clients) by
// scripts/sync-dsc-version.js at build time.
import { DSC_VERSION } from './dsc-version';
export { DSC_VERSION };
export const RELEASE_BASE_URL = 'https://dsc-wasm.deka.gg';
export const INSTALL_HINT =
  'Install dsc: curl -fsSL https://deka.gg/install.sh | bash';

export type ServerPlatform = 'darwin-arm64' | 'darwin-x64' | 'linux-x64';

/** Map process.platform/process.arch to the published artifact platform. */
export function currentPlatform(platform: string, arch: string): ServerPlatform | null {
  if (platform === 'darwin' && arch === 'arm64') return 'darwin-arm64';
  if (platform === 'darwin' && arch === 'x64') return 'darwin-x64';
  if (platform === 'linux' && arch === 'x64') return 'linux-x64';
  return null;
}

export interface ReleaseManifest {
  version: string;
  binaries: Record<string, { name: string; sha256: string }>;
}

export interface DiscoveryDeps {
  /** Level 1: explicit user override (absolute path to the dsc binary). */
  overridePath?: string;
  /**
   * Level 2: directories to walk upward from looking for a project-local
   * `node_modules/.bin/dsc` (the open document's folder, each workspace
   * folder). May be empty (e.g. no active editor, no open folder).
   */
  projectSearchDirs?: string[];
  /** Level 3: directory a platform binary may be bundled in (may not exist). */
  bundledDir?: string;
  /** Level 3/5: managed cache directory (created on demand). */
  cacheDir: string;
  /** Skip the cached copy (force a fresh managed download). */
  skipCache?: boolean;
  platform: ServerPlatform;
  env: NodeJS.ProcessEnv;
  isExecutableFile(path: string): Promise<boolean>;
  fetchJson(url: string): Promise<unknown>;
  downloadToFile(url: string, dest: string): Promise<void>;
  sha256File(path: string): Promise<string>;
  chmodExecutable(path: string): Promise<void>;
  renameFile(from: string, to: string): Promise<void>;
}

export type DiscoveryResult =
  | {
      kind: 'found';
      path: string;
      source: 'override' | 'project' | 'bundled' | 'path' | 'downloaded';
    }
  | { kind: 'error'; message: string };

export async function resolveDsc(deps: DiscoveryDeps): Promise<DiscoveryResult> {
  const tried: string[] = [];

  // 1. explicit override
  if (deps.overridePath) {
    if (await deps.isExecutableFile(deps.overridePath)) {
      return { kind: 'found', path: deps.overridePath, source: 'override' };
    }
    tried.push(`override ${deps.overridePath} (not an executable file)`);
  }

  // 2. project-scoped: node_modules/.bin/dsc, walked up from the open
  // document's folder and each workspace folder. Beats this extension's own
  // DSC_VERSION pin because it is the exact runtime the project installed.
  const projectDsc = await findProjectDsc(deps.projectSearchDirs ?? [], deps);
  if (projectDsc) {
    return { kind: 'found', path: projectDsc, source: 'project' };
  }
  if (deps.projectSearchDirs?.length) {
    tried.push(`node_modules/.bin/dsc above ${deps.projectSearchDirs.join(', ')}`);
  }

  // 3. bundled, then previously downloaded copy in the managed cache
  const binaryName = `dsc-${deps.platform}`;
  const searchDirs = deps.skipCache
    ? [deps.bundledDir]
    : [deps.bundledDir, deps.cacheDir];
  for (const dir of searchDirs) {
    if (!dir) continue;
    const candidate = joinPath(dir, binaryName);
    if (await deps.isExecutableFile(candidate)) {
      return {
        kind: 'found',
        path: candidate,
        source: dir === deps.bundledDir ? 'bundled' : 'downloaded',
      };
    }
    tried.push(dir);
  }

  // 4. PATH (DEKA_DSC env honored like deka's own lookup)
  const envOverride = deps.env.DEKA_DSC;
  if (envOverride && (await deps.isExecutableFile(envOverride))) {
    return { kind: 'found', path: envOverride, source: 'path' };
  }
  const onPath = await findOnPath('dsc', deps);
  if (onPath) {
    return { kind: 'found', path: onPath, source: 'path' };
  }
  tried.push('dsc on PATH');

  // 5. managed download, version-pinned + checksum-verified
  try {
    const downloaded = await downloadPinned(deps);
    return { kind: 'found', path: downloaded, source: 'downloaded' };
  } catch (err) {
    tried.push(`managed download failed: ${errMessage(err)}`);
  }

  // 6. clear error with a one-command fix
  return {
    kind: 'error',
    message:
      'The DekaScript language server (dsc) could not be located. ' +
      `Tried: ${tried.join('; ')}. ` +
      `${INSTALL_HINT}, then reload the window — or run the ` +
      `"DekaScript: Download Language Server" command to retry the managed download.`,
  };
}

async function downloadPinned(deps: DiscoveryDeps): Promise<string> {
  const { platform } = deps;
  const versionDir = `v${DSC_VERSION}`;
  const manifestUrl = `${RELEASE_BASE_URL}/${versionDir}/release.json`;
  const manifest = (await deps.fetchJson(manifestUrl)) as ReleaseManifest;
  if (manifest.version !== DSC_VERSION) {
    throw new Error(
      `${manifestUrl} describes version ${manifest.version}, not ${DSC_VERSION}`,
    );
  }
  const entry = manifest.binaries?.[platform];
  if (!entry?.sha256) {
    throw new Error(`no ${platform} binary in ${manifestUrl}`);
  }

  const dest = joinPath(deps.cacheDir, `dsc-${platform}`);
  const tmp = `${dest}.tmp-${process.pid}`;
  await deps.downloadToFile(`${RELEASE_BASE_URL}/${versionDir}/${entry.name}`, tmp);
  const actual = await deps.sha256File(tmp);
  if (actual !== entry.sha256) {
    throw new Error(
      `checksum mismatch for dsc ${platform} v${DSC_VERSION}: expected ${entry.sha256}, got ${actual}`,
    );
  }
  await deps.chmodExecutable(tmp);
  await deps.renameFile(tmp, dest);
  return dest;
}

function joinPath(dir: string, name: string): string {
  return dir.endsWith('/') || dir.endsWith('\\') ? `${dir}${name}` : `${dir}/${name}`;
}

/**
 * Walk upward from each start directory (deduplicating already-visited
 * directories across starts) looking for `node_modules/.bin/dsc`. First hit
 * wins. Mirrors how Node itself resolves `node_modules` up the tree, so a
 * monorepo with the project root above the open file still resolves.
 */
async function findProjectDsc(startDirs: string[], deps: DiscoveryDeps): Promise<string | null> {
  const visited = new Set<string>();
  for (const start of startDirs) {
    if (!start) continue;
    let dir: string | null = start;
    let guard = 0;
    while (dir && guard++ < 64) {
      if (visited.has(dir)) break;
      visited.add(dir);
      const candidate = joinPath(joinPath(dir, 'node_modules/.bin'), 'dsc');
      if (await deps.isExecutableFile(candidate)) {
        return candidate;
      }
      dir = parentDir(dir);
    }
  }
  return null;
}

/** Posix/Windows-ish parent directory, without touching the real filesystem. */
function parentDir(dir: string): string | null {
  const trimmed = dir.replace(/[\\/]+$/, '');
  const sepIdx = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'));
  if (sepIdx < 0) return null;
  if (sepIdx === 0) return trimmed.slice(0, 1); // posix root "/"
  const parent = trimmed.slice(0, sepIdx);
  if (parent === dir) return null;
  return /^[A-Za-z]:$/.test(parent) ? `${parent}\\` : parent;
}

/** `which` semantics: scan the PATH env var for an executable file. */
async function findOnPath(command: string, deps: DiscoveryDeps): Promise<string | null> {
  const pathVar = deps.env.PATH;
  if (!pathVar) return null;
  for (const dir of pathVar.split(require('node:path').delimiter)) {
    if (!dir) continue;
    const candidate = joinPath(dir, command);
    if (await deps.isExecutableFile(candidate)) return candidate;
  }
  return null;
}

function errMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
