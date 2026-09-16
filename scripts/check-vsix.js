#!/usr/bin/env node
// Fails the build if a packaged VSIX would repeat the dekaruntime.deka 0.1.1
// activation bug: `.vscodeignore` excludes node_modules, but the packaged
// main file did a runtime `require("vscode-languageclient/node")` that only
// exists in node_modules, so activation threw before the LSP was ever
// spawned (exthost.log: "Cannot find module 'vscode-languageclient/node'").
//
// Two checks, both meant to catch that class of bug generically:
//   1. The packaged main file (package.json "main") must not require()
//      anything except Node builtins and "vscode" — i.e. it must be a
//      self-contained bundle, not a thin file that reaches into
//      node_modules at runtime.
//   2. README.md and icon.png must be present in the archive, so the
//      Marketplace listing doesn't regress to the blank icon / "No README
//      available" state this same release fixed.
//
// Usage: node scripts/check-vsix.js <path-to-vsix>

const { execFileSync } = require('node:child_process');
const path = require('node:path');
const Module = require('node:module');

const vsixPath = process.argv[2];
if (!vsixPath) {
  console.error('usage: node scripts/check-vsix.js <path-to-vsix>');
  process.exit(2);
}

const builtins = new Set(Module.builtinModules);

function isAllowedSpecifier(spec) {
  if (spec === 'vscode') return true;
  const bare = spec.startsWith('node:') ? spec.slice('node:'.length) : spec;
  const top = bare.split('/')[0];
  return builtins.has(bare) || builtins.has(top);
}

function listEntries(vsix) {
  const out = execFileSync('unzip', ['-Z1', vsix], { encoding: 'utf8' });
  return out.split('\n').filter(Boolean);
}

function readEntry(vsix, entry) {
  return execFileSync('unzip', ['-p', vsix, entry], { encoding: 'utf8' });
}

function main() {
  const entries = listEntries(vsixPath);
  const failures = [];

  // vsce packages the README under "extension/readme.md" (it lowercases the
  // filename regardless of the source file's casing), so match
  // case-insensitively rather than pinning to one spelling.
  const readme = entries.find((e) => e.toLowerCase() === 'extension/readme.md');
  if (!readme) {
    failures.push('extension/README.md is missing from the .vsix');
  }
  const icon = entries.find((e) => e === 'extension/icon.png');
  if (!icon) {
    failures.push('extension/icon.png is missing from the .vsix');
  }

  const pkgEntry = entries.find((e) => e === 'extension/package.json');
  if (!pkgEntry) {
    failures.push('extension/package.json is missing from the .vsix');
  } else {
    const pkg = JSON.parse(readEntry(vsixPath, pkgEntry));
    const mainRel = (pkg.main || './out/extension.js').replace(/^\.\//, '');
    const mainEntry = `extension/${mainRel}`;
    if (!entries.includes(mainEntry)) {
      failures.push(`packaged main "${mainEntry}" (from package.json "main": "${pkg.main}") is not in the .vsix`);
    } else {
      const src = readEntry(vsixPath, mainEntry);
      const requireRe = /require\(\s*(['"])((?:(?!\1).)+)\1\s*\)/g;
      const bad = new Set();
      let m;
      while ((m = requireRe.exec(src))) {
        const spec = m[2];
        if (!isAllowedSpecifier(spec)) bad.add(spec);
      }
      if (bad.size > 0) {
        failures.push(
          `${mainEntry} requires non-bundled module(s): ${[...bad].join(', ')}. ` +
            'The packaged main must be a self-contained bundle (only "vscode" and ' +
            'Node builtins may be required at runtime) — node_modules is excluded ' +
            'from the .vsix by .vscodeignore, so anything else throws on activation.',
        );
      }
    }
  }

  if (failures.length > 0) {
    console.error(`check-vsix: ${path.basename(vsixPath)} failed:`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }

  console.log(`check-vsix: ${path.basename(vsixPath)} OK (bundled main, README.md, icon.png all present)`);
}

main();
