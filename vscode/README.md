# DekaScript for VS Code

Language support for [DekaScript](https://deka.gg) — syntax highlighting and a language server for `.ds` and `.dsx` files.

## Features

- Syntax highlighting for `.ds` and `.dsx` files
- Inline diagnostics for syntax and type errors in the open file
- Bracket matching, auto-closing pairs, and comment toggling

Completions, hover, and project-wide diagnostics are in progress ([dekaruntime/dsc#265](https://github.com/dekaruntime/dsc/issues/265)).

## Getting started

Install the extension, then open a folder containing a DekaScript project (a `deka.json` or some `.ds` files). If the project has `deka` installed via npm, the extension uses that; otherwise it downloads a matching compiler automatically the first time you open a DekaScript file.

## Settings

| Setting | Description |
| --- | --- |
| `deka.server.path` | Absolute path to a `dsc` binary to use instead of the one the extension finds or downloads automatically. Leave empty unless you need a specific build. |

## Links

- [deka.gg](https://deka.gg)
- [Docs](https://deka.gg/docs) and the [DekaScript tour](https://deka.gg/tour)
- [Report an issue](https://github.com/dekaruntime/deka/issues)
