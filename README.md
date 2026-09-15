# DekaScript editor extensions

Editor extensions for [DekaScript](https://deka.gg): VS Code, Cursor, Neovim, and Zed.

Every extension attaches to the same language server — `dsc lsp` (stdio), shipped
with the [`dsc` compiler](https://github.com/dekaruntime/dsc) — and every
extension resolves that server with the same binary-discovery search order.

## Which server binary speaks LSP to editors?

**`dsc lsp` (stdio) is the editor-facing surface.** The extensions spawn the
`dsc` compiler binary as `dsc lsp` and talk LSP over stdio (language id
`dekascript`, sync kind `FULL`, hover / completion / pull diagnostics / rename /
document symbols).

Evidence, recorded for dekaruntime/deka#1050:

- `dsc lsp` runs `dekascript_lsp::run_stdio()` via tower-lsp over stdio
  (`crates/cli/src/cli/lsp.rs` in dekaruntime/dsc). It needs no project file to
  initialize: workspace roots come from the LSP `initialize` params
  (`workspace_folders` → `root_uri` → process cwd).
- `deka lsp [--stdio]` in the deka CLI is a **passthrough**: it locates the `dsc`
  binary and execs it with the same argv
  (`crates/compiler/src/lsp.rs` → `crates/compiler/src/dsc.rs:exec_if_present`
  in dekaruntime/deka). The deka CLI never embeds an LSP server, so there is no
  second stdio surface to choose.
- `dekaruntime/lsp` (`deka-lsp`, crates.io) describes itself as the
  "LSP-over-HTTP language server … consumed by the deka CLI", versions
  independently of deka/dsc, and targets the HTTP/wasm side. It is not the
  stdio transport editors attach to, and nothing in the current deka CLI wires
  it in for editor traffic.
- dsc ships versioned, checksumed per-platform binaries
  (`https://dsc-wasm.deka.gg/v{VERSION}/dsc-{platform}` with a per-version
  `release.json`), which is exactly what these extensions download during
  managed install — the same host/pattern as deka's
  `scripts/ci-install-dsc.sh`.

Note: today the server analyzes `.ds` files only (URI extension check). `.dsx`
gets editor highlighting everywhere; LSP features follow server-side support.

## Binary discovery search order (identical in all three implementations)

Every extension implements the same search order. First hit wins:

1. **Explicit override** — VS Code setting `deka.server.path`; Neovim
   `require('deka').setup{ server_path = ... }`; Zed core setting
   `lsp.deka.binary.path` (handled by Zed itself, no extension wiring).
2. **Bundled / previously downloaded copy** — a `dsc` binary bundled inside the
   extension, or one previously downloaded into the extension's managed cache.
3. **`dsc` on `PATH`** — a `dsc` found via `PATH` (`which dsc` semantics;
   also honors `DEKA_DSC` where the host runtime can read it).
4. **Managed download** — a version-pinned download from
   `https://dsc-wasm.deka.gg/v{VERSION}/`, verified against the `sha256`
   published in that version's `release.json`, cached in the extension's
   storage so it is downloaded once.
5. **Clear error** — if all of the above fail, the extension tells you exactly
   what it tried and gives the one-command fix
   (`curl -fsSL https://deka.gg/install.sh | bash`, or the editor command to
   retry the managed download).

The pinned server version lives next to each implementation
(`DSC_VERSION` in `vscode/src/discovery.ts`, `zed/src/lib.rs`, and
`lua/deka/discovery.lua`) and is bumped with the same cadence as deka's
`scripts/dsc-version` pin.

## Install

### VS Code

From the Marketplace (once published): search **"DekaScript"** (publisher
`dekaruntime`). Until then, from a CI-built artifact:

```sh
code --install-extension deka-<version>.vsix
```

or VS Code → Extensions view → `...` → *Install from VSIX…*.

The extension activates on `.ds` / `.dsx`, starts `dsc lsp` (found via the
search order above), and contributes a TextMate grammar for highlighting.
Optional setting: `deka.server.path` (explicit override, level 1).

### Cursor

Cursor speaks the VS Code extension format. Install the same VSIX via
*Extensions → Install from VSIX…*, or from OpenVSX once published (Cursor's
marketplace default is OpenVSX).

### Neovim (lazy.nvim)

The plugin lives in the `nvim/` directory of this monorepo:

```lua
{
  'dekaruntime/editors',
  init = function(plugin)
    vim.opt.rtp:append(plugin.dir .. '/nvim')
  end,
  -- optional; zero required config:
  -- opts = { server_path = '/path/to/dsc' },
  config = function(_, opts)
    require('deka').setup(opts)
  end,
}
```

Once the rock is published, luarocks/rocks.nvim users can also
`luarocks install deka.nvim` and skip the `rtp` dance entirely.

Zero required configuration: on `*.ds` / `*.dsx` buffers the plugin attaches
`dsc lsp` using the search order above, with root detection via `deka.json` →
`index.ds` → `.git` (the server also falls back to its own cwd).

Highlighting comes from the tree-sitter parser, not a legacy syntax file:

```lua
{ 'dekaruntime/tree-sitter-deka', build = ':TSInstall deka' } -- or nvim-treesitter custom parser entry
```

Requires Neovim ≥ 0.10 (`vim.lsp.start` / `vim.uv` / `vim.fs.root`).

### Zed

```json
// ~/.config/zed/settings.json
"extension": { ... }
```

Install from the Zed extension registry (once upstreamed) or from a git source
in the Zed extensions UI. The extension registers the `dekascript` language for
`.ds` / `.dsx` (tree-sitter grammar from `dekaruntime/tree-sitter-deka`) and
resolves `dsc lsp` via the search order above, downloading it on first use.

## Repository layout

```
vscode/   VS Code + Cursor extension (TypeScript, vsce)
zed/      Zed extension (Rust → wasm32-wasip1)
nvim/     Neovim plugin (Lua, luarocks rockspec)
```

## CI and publishing

All workflows run on the org's self-hosted runners
(`runs-on: [self-hosted, macOS, ARM64]`, mirroring dekaruntime/deka's ci.yml)
and build on every push; publishing runs on `v*` tags and is otherwise inert.

| Ecosystem | Workflow | Publishes to | Secret required |
|---|---|---|---|
| VS Code / Cursor | `.github/workflows/publish-vscode.yml` | VS Marketplace (`vsce publish`) + OpenVSX (`ovsx publish`) | `VSCE_PAT` (Azure DevOps publisher token for publisher `dekaruntime`), `OVSX_PAT` (open-vsx.org token) |
| Zed | `.github/workflows/publish-zed.yml` | zed-industries/extensions PR | none required — the workflow prints manual upstreaming steps; add `ZED_EXTENSIONS_TOKEN` (PAT with push to zed-industries/extensions) to have it open the upstream PR automatically |
| Neovim | `.github/workflows/publish-nvim.yml` | luarocks.org (`luarocks upload`) | `LUAROCKS_API_KEY` (luarocks.org API key) |

`.github/workflows/ci.yml` runs on PRs: vscode typecheck + unit tests + VSIX
packaging, zed `cargo check`/`build` for wasm32-wasip1, and nvim lua tests with a
headless Neovim. What Ava must add: the secrets above, plus an Azure publisher
named `dekaruntime` if not already registered.

## License

Apache-2.0, matching deka and dsc.
