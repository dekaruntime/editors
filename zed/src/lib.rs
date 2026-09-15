//! Zed extension for DekaScript.
//!
//! Registers the `dekascript` language (`.ds` / `.dsx`, tree-sitter grammar
//! from dekaruntime/tree-sitter-deka) and resolves the editor-facing language
//! server, which is `dsc lsp` (stdio) — the dsc compiler binary published at
//! https://dsc-wasm.deka.gg/v{VERSION}/ with sha256 checksums in that
//! version's release.json (same host/pattern as dekaruntime/deka's
//! scripts/ci-install-dsc.sh).
//!
//! Binary search order (kept identical to the VS Code and Neovim
//! implementations, see the repo README):
//!   1. explicit override — Zed's core setting `lsp.deka.binary.path` is
//!      handled by Zed itself and never reaches this code
//!   2. a previously downloaded copy inside the extension's working directory
//!   3. `dsc` on the worktree PATH
//!   4. managed download, version-pinned + checksum-verified, then cached
//!   5. clear error with a one-command fix

use std::fs;
use zed_extension_api as zed;
use zed::{Command, DownloadedFileType, LanguageServerId, LanguageServerInstallationStatus, Result, Worktree};

/// Pinned dsc release, single-sourced from the repo-root DSC_VERSION file
/// (keep the include path — scripts/check-dsc-version.sh fails CI on drift).
/// The file ends in a newline, so trim at the point of use.
const DSC_VERSION: &str = include_str!("../../DSC_VERSION");
const RELEASE_BASE_URL: &str = "https://dsc-wasm.deka.gg";
const INSTALL_HINT: &str = "Install dsc: curl -fsSL https://deka.gg/install.sh | bash";

struct DekaExtension {
    cached_binary_path: Option<String>,
}

impl DekaExtension {
    fn language_server_binary_path(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<String> {
        // 2. previously downloaded copy in the extension working directory
        if let Some(path) = &self.cached_binary_path {
            if fs::metadata(path).is_ok_and(|stat| stat.is_file()) {
                return Ok(path.clone());
            }
        }

        // 3. dsc on the worktree PATH
        if let Some(path) = worktree.which("dsc") {
            return Ok(path);
        }

        // 4. managed download: version-pinned, checksum-verified, cached
        self.download_pinned(language_server_id)
    }

    fn download_pinned(&mut self, language_server_id: &LanguageServerId) -> Result<String> {
        zed::set_language_server_installation_status(
            language_server_id,
            &LanguageServerInstallationStatus::CheckingForUpdate,
        );

        let (platform_key, binary_name) = platform_artifact()
            .ok_or_else(unsupported_platform_error)?;
        let version = DSC_VERSION.trim();

        let manifest_url = format!("{RELEASE_BASE_URL}/v{version}/release.json");
        let request = zed::http_client::HttpRequest::builder()
            .method(zed::http_client::HttpMethod::Get)
            .url(manifest_url)
            .build()
            .map_err(|err| format!("failed to build manifest request: {err}"))?;
        let response = zed::http_client::fetch(&request)
            .map_err(|err| format!("failed to fetch release manifest: {err}"))?;
        let manifest: serde_json::Value = serde_json::from_slice(&response.body)
            .map_err(|err| format!("release manifest is not valid JSON: {err}"))?;

        let published = manifest
            .get("version")
            .and_then(|value| value.as_str())
            .unwrap_or("");
        if published != version {
            return Err(format!(
                "release manifest describes version {published}, not {version}"
            ));
        }
        let expected_sha = manifest
            .get("binaries")
            .and_then(|binaries| binaries.get(platform_key))
            .and_then(|entry| entry.get("sha256"))
            .and_then(|sha| sha.as_str())
            .ok_or_else(|| format!("no {platform_key} binary in the release manifest"))?;

        let version_dir = format!("dsc-v{version}");
        let binary_path = format!("{version_dir}/{binary_name}");

        if !fs::metadata(&binary_path).is_ok_and(|stat| stat.is_file()) {
            zed::set_language_server_installation_status(
                language_server_id,
                &LanguageServerInstallationStatus::Downloading,
            );

            zed::download_file(
                &format!("{RELEASE_BASE_URL}/v{version}/{binary_name}"),
                &version_dir,
                DownloadedFileType::Uncompressed,
            )
            .map_err(|err| format!("failed to download dsc v{version}: {err}"))?;

            // Verify the published sha256 before the binary is ever executed.
            use sha2::Digest;
            let bytes = fs::read(&binary_path)
                .map_err(|err| format!("failed to read downloaded dsc: {err}"))?;
            let actual_sha = format!("{:x}", sha2::Sha256::digest(&bytes));
            if actual_sha != expected_sha {
                fs::remove_file(&binary_path).ok();
                return Err(format!(
                    "dsc checksum mismatch for {platform_key} v{version}: expected {expected_sha}, got {actual_sha}"
                ));
            }

            zed::make_file_executable(&binary_path)
                .map_err(|err| format!("failed to make dsc executable: {err}"))?;
        }

        zed::set_language_server_installation_status(
            language_server_id,
            &LanguageServerInstallationStatus::None,
        );

        self.cached_binary_path = Some(binary_path.clone());
        Ok(binary_path)
    }
}

/// (release.json platform key, artifact file name) for this host.
fn platform_artifact() -> Option<(&'static str, String)> {
    let (os, arch) = zed::current_platform();
    let key = match (os, arch) {
        (zed::Os::Mac, zed::Architecture::Aarch64) => "darwin-arm64",
        (zed::Os::Mac, zed::Architecture::X8664) => "darwin-x64",
        (zed::Os::Linux, zed::Architecture::X8664) => "linux-x64",
        _ => return None,
    };
    Some((key, format!("dsc-{key}")))
}

fn unsupported_platform_error() -> String {
    format!(
        "DekaScript: this platform is not supported by the managed dsc downloader \
         (dsc publishes darwin-arm64, darwin-x64, and linux-x64). {INSTALL_HINT}"
    )
}

impl zed::Extension for DekaExtension {
    fn new() -> Self {
        Self {
            cached_binary_path: None,
        }
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        let path = self
            .language_server_binary_path(language_server_id, worktree)
            .map_err(|err| format!("{err}. Tried: extension cache, worktree PATH, managed download. {INSTALL_HINT}"))?;
        Ok(Command {
            command: path,
            args: vec!["lsp".to_string()],
            env: Vec::new(),
        })
    }
}

zed::register_extension!(DekaExtension);
