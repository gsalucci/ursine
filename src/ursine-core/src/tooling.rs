//! Trusted-tool lookup shared by the modules: absolute candidates only,
//! first existing path wins, every miss carries the exact install hint.

#![allow(clippy::redundant_pub_crate)] // private module: pub(crate) is the real visibility

use std::path::Path;

use ursine_api::ApiError;

/// Run a blocking closure on the blocking pool: file IO and host tools must
/// never stall the async executor. `label` names the module in the failure.
pub(crate) async fn blocking<F, T>(label: &'static str, work: F) -> Result<T, ApiError>
where
    F: FnOnce() -> Result<T, ApiError> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|e| ApiError::internal(format!("{label} task failed: {e}")))?
}

/// Resolve the first existing candidate, or an `unavailable` error that
/// names the package providing it.
pub(crate) fn resolve(
    candidates: &[&'static str],
    label: &str,
    fix: &str,
) -> Result<&'static str, ApiError> {
    find(candidates).ok_or_else(|| ApiError::unavailable(format!("{label} not found"), fix))
}

/// First existing candidate; `None` when the tool is not installed.
pub(crate) fn find(candidates: &[&'static str]) -> Option<&'static str> {
    candidates
        .iter()
        .find(|path| Path::new(path).is_file())
        .copied()
}
