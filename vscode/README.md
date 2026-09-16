# DekaScript for VS Code

Language support for [DekaScript](https://deka.gg), a full-stack language that
compiles to JavaScript with a React-like component model, run by the `dsc`
compiler ([dekaruntime/dsc](https://github.com/dekaruntime/dsc)).

## What this extension does

- **Syntax highlighting** for `.ds` and `.dsx` files, via a TextMate grammar
  (`syntaxes/dekascript.tmLanguage.json`) registered under the `dekascript`
  language id.
- **Language Server Protocol support** by spawning `dsc lsp` (stdio) and
  wiring it up through `vscode-languageclient`. This gives you whatever the
  server advertises — today that includes diagnostics, hover, completion,
  rename, and document symbols for `.ds` files. `.dsx` files get syntax
  highlighting everywhere; LSP features on `.dsx` follow server-side support.
- A **"DekaScript: Download Language Server"** command
  (`deka.downloadServer`) that forces a fresh, version-pinned,
  checksum-verified download of `dsc`, bypassing any cached or on-`PATH`
  copy.

The extension activates automatically when you open a `.ds` or `.dsx` file.

## How it finds `dsc`

The extension needs the `dsc` compiler binary to run `dsc lsp`. It looks in
this order, using the first one it finds ([`src/discovery.ts`](src/discovery.ts)):

1. **Explicit override** — the `deka.server.path` setting, if set.
2. **Bundled or previously downloaded copy** — a binary shipped inside the
   extension, or one already downloaded into the extension's managed storage
   (VS Code's per-extension global storage directory).
3. **`dsc` on `PATH`** — a `dsc` found via `PATH` (`which dsc` semantics),
   also honoring a `DEKA_DSC` environment variable if set.
4. **Managed download** — a version-pinned download from
   `https://dsc-wasm.deka.gg/v{VERSION}/`, verified against the `sha256`
   published in that version's `release.json`, then cached so it's only
   downloaded once.
5. **Clear error** — if none of the above work, the extension reports exactly
   what it tried and offers a one-click retry of the managed download (or run
   `curl -fsSL https://deka.gg/install.sh | bash` yourself).

This same search order is implemented identically in the Zed and Neovim
extensions in this repo.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `deka.server.path` | `string` | `""` | Optional absolute path to the `dsc` binary. When empty, the extension falls back to bundled → `PATH` → managed download. The server is started as `dsc lsp` over stdio. |

## Requirements

- VS Code 1.85.0 or newer.
- No local `dsc` install is required — the extension will download and pin
  one for you the first time you open a `.ds`/`.dsx` file, unless you already
  have `dsc` on `PATH` or set `deka.server.path`.
- Supported platforms for the managed download: `darwin-arm64`,
  `darwin-x64`, and `linux-x64`.

## Getting started

```sh
npm create deka-app@latest myapp
```

Then open the `myapp` folder in VS Code. The extension activates on the
project's `.ds`/`.dsx` files and starts the language server automatically.

## Issues

File issues against the language, compiler, or language server at
[dekaruntime/deka](https://github.com/dekaruntime/deka/issues). Issues
specific to this editor extension (this repo) can go to
[dekaruntime/editors](https://github.com/dekaruntime/editors/issues).
