import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';
import {
  DSC_VERSION,
  DiscoveryDeps,
  ReleaseManifest,
  ServerPlatform,
  currentPlatform,
  resolveDsc,
} from './discovery';

let client: LanguageClient | undefined;
let output: vscode.OutputChannel | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  output = vscode.window.createOutputChannel('DekaScript');
  context.subscriptions.push(output);
  output.appendLine(`DekaScript extension activating (server pin: dsc v${DSC_VERSION})`);

  context.subscriptions.push(
    vscode.commands.registerCommand('deka.downloadServer', async () => {
      await startClient(context, { forceDownload: true });
    }),
  );

  await startClient(context, { forceDownload: false });
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
}

async function startClient(
  context: vscode.ExtensionContext,
  opts: { forceDownload: boolean },
): Promise<void> {
  if (opts.forceDownload && client) {
    await client.stop();
    client = undefined;
  }
  if (client) return;

  const config = vscode.workspace.getConfiguration('deka');
  const platform = currentPlatform(process.platform, process.arch);
  if (!platform) {
    void vscode.window.showErrorMessage(
      `DekaScript: unsupported platform ${process.platform}/${process.arch}; ` +
        'dsc publishes darwin-arm64, darwin-x64, and linux-x64.',
    );
    return;
  }

  const cacheDir = context.globalStorageUri.fsPath;
  const dirname = require('node:path').dirname as (p: string) => string;
  const activeDocDir = vscode.window.activeTextEditor?.document.uri.fsPath;
  const projectSearchDirs = [
    ...(activeDocDir ? [dirname(activeDocDir)] : []),
    ...(vscode.workspace.workspaceFolders ?? []).map((f) => f.uri.fsPath),
  ];
  const deps = nodeDeps({
    overridePath: nonempty(config.get<string>('server.path')),
    projectSearchDirs,
    bundledDir: vscode.Uri.joinPath(context.extensionUri, 'bin').fsPath,
    cacheDir,
    skipCache: opts.forceDownload,
    platform,
  });

  const resolved = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Window, title: 'DekaScript: locating language server' },
    () => resolveDsc(deps),
  );

  if (resolved.kind === 'error') {
    const pick = await vscode.window.showErrorMessage(
      resolved.message,
      'Download Language Server',
    );
    if (pick) {
      await vscode.commands.executeCommand('deka.downloadServer');
    }
    return;
  }

  output?.appendLine(`using dsc at ${resolved.path} (source: ${resolved.source})`);

  const serverOptions: ServerOptions = {
    command: resolved.path,
    args: ['lsp'],
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'dekascript' }],
    outputChannel: output,
  };

  client = new LanguageClient('deka', 'DekaScript Language Server', serverOptions, clientOptions);
  await client.start();
}

function nonempty(value: string | undefined): string | undefined {
  return value && value.trim() !== '' ? value : undefined;
}

/** Wire Node built-ins into the injectable discovery deps. */
function nodeDeps(init: {
  overridePath?: string;
  projectSearchDirs: string[];
  bundledDir: string;
  cacheDir: string;
  skipCache: boolean;
  platform: ServerPlatform;
}): DiscoveryDeps {
  const fs = require('node:fs') as typeof import('node:fs');
  const fsp = require('node:fs/promises') as typeof import('node:fs/promises');
  const path = require('node:path') as typeof import('node:path');
  const { createHash } = require('node:crypto') as typeof import('node:crypto');

  return {
    ...init,
    env: process.env,
    async isExecutableFile(path: string) {
      try {
        fs.accessSync(path, fs.constants.X_OK);
        return fs.statSync(path).isFile();
      } catch {
        return false;
      }
    },
    async fetchJson(url: string) {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`GET ${url}: HTTP ${res.status}`);
      return (await res.json()) as ReleaseManifest;
    },
    async downloadToFile(url: string, dest: string) {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`GET ${url}: HTTP ${res.status}`);
      await fsp.mkdir(path.dirname(dest), { recursive: true });
      const buffer = Buffer.from(await res.arrayBuffer());
      await fsp.writeFile(dest, buffer);
    },
    async sha256File(path: string) {
      const buffer = await fsp.readFile(path);
      return createHash('sha256').update(buffer).digest('hex');
    },
    async chmodExecutable(path: string) {
      await fsp.chmod(path, 0o755);
    },
    async renameFile(from: string, to: string) {
      await fsp.rename(from, to);
    },
  };
}
