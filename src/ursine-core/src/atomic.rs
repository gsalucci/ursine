//! Atomic file replacement shared by the profile/config editors.

#![allow(clippy::redundant_pub_crate)] // private module: pub(crate) is the real visibility

use std::path::Path;

use ursine_api::ApiError;

/// Replace `path` through a pid-unique temp file in the same directory.
///
/// The full file name is part of the temp name (`usr.bin.foo` and
/// `usr.bin.bar` must never share a temp path inside one process). Write,
/// chmod and rename all clean the temp up on failure; callers rotate their
/// backups before calling this.
pub(crate) fn write(path: &Path, text: &str) -> Result<(), ApiError> {
    use std::os::unix::fs::PermissionsExt;
    let file_name = path
        .file_name()
        .map_or_else(|| "file".to_string(), |n| n.to_string_lossy().into_owned());
    let tmp = path.with_file_name(format!("{file_name}.ursine-new.{}", std::process::id()));
    let cleanup = |error: ApiError| -> ApiError {
        let _ = std::fs::remove_file(&tmp);
        error
    };
    std::fs::write(&tmp, text)
        .map_err(|e| cleanup(ApiError::internal(format!("write {}: {e}", tmp.display()))))?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644))
        .map_err(|e| cleanup(ApiError::internal(format!("chmod {}: {e}", tmp.display()))))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        cleanup(ApiError::internal(format!(
            "replace {}: {e}",
            path.display()
        )))
    })
}
