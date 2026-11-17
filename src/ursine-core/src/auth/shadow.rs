//! Webmin-style local authentication: verify user+password directly
//! against the system shadow database (`/etc/shadow`) using `pwhash`.
//!
//! No PAM, no C dependencies — the same approach Webmin uses for its
//! default "Unix authentication" backend. Fail-closed everywhere: an
//! unknown user, a locked/empty password field, an expired account or
//! an unsupported hash format all collapse to [`AuthError::Invalid`]
//! (no user-existence oracle). Password values live only for the
//! duration of this call — never logged, never audited, never stored.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use super::{local_groups, AuthError, Authenticator, PeerInfo};
use ursine_api::Principal;

/// Default shadow database path.
const SHADOW_PATH: &str = "/etc/shadow";

/// Fixed `$6$` hash burned when the account cannot be verified, so the
/// timing of an unknown/locked user matches a real crypt round-trip.
const TIMING_DUMMY_HASH: &str = "$6$YeS0faisto4MrAU7$Jt33WmcI0CG5TTSoxe98SdqhSdtzhcbyYvOqiPrd3m/EbhHr0jU9njlbgSSjmnx.ijXmboM3280MCEblgKG5I0";

/// Minimum wall-clock time for every authentication attempt. Combined
/// with the unconditional dummy burn this erases the response-time
/// differences between unknown users, cheap hashes ($1$) and expensive
/// ones ($6$) — no user-existence or hash-class oracle. Login happens
/// once per session, so the latency is acceptable.
const AUTH_TIME_FLOOR: Duration = Duration::from_millis(600);

/// Authenticator reading `/etc/shadow` directly (root daemon only).
#[derive(Debug, Clone)]
pub struct ShadowAuthenticator {
    shadow_path: PathBuf,
}

impl Default for ShadowAuthenticator {
    fn default() -> Self {
        Self {
            shadow_path: SHADOW_PATH.into(),
        }
    }
}

impl ShadowAuthenticator {
    /// Verify against a specific shadow file (tests/fixtures).
    pub fn with_path(path: impl Into<PathBuf>) -> Self {
        Self {
            shadow_path: path.into(),
        }
    }
}

impl Authenticator for ShadowAuthenticator {
    fn authenticate(
        &self,
        _peer: &PeerInfo,
        user: &str,
        password: &str,
    ) -> Result<Principal, AuthError> {
        let start = Instant::now();
        let content = std::fs::read_to_string(&self.shadow_path)
            .map_err(|e| AuthError::Internal(format!("shadow read failed: {e}")))?;
        let result = verify_shadow(&content, user, password, today_days());
        // Equalize on every outcome (success included): burn one dummy
        // crypt, then hold a fixed floor so elapsed time reveals nothing.
        burn_timing(password);
        if let Some(remaining) = AUTH_TIME_FLOOR.checked_sub(start.elapsed()) {
            std::thread::sleep(remaining);
        }
        result?;
        Ok(Principal::local(user, local_groups(user)))
    }
}

/// Days since the Unix epoch (the unit `/etc/shadow` dates use).
fn today_days() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() / 86_400)
}

/// Burn one default-rounds sha512crypt to equalize timing when no real
/// hash can be verified (unknown user, locked account, odd format).
fn burn_timing(password: &str) {
    let _ = pwhash::sha512_crypt::verify(password, TIMING_DUMMY_HASH);
}

/// Verify `password` against the `user` entry of shadow `content`.
///
/// `today` is days since the epoch, injected so expiry is testable.
pub(crate) fn verify_shadow(
    content: &str,
    user: &str,
    password: &str,
    today: u64,
) -> Result<(), AuthError> {
    if user.is_empty() || password.is_empty() {
        return Err(AuthError::Invalid);
    }
    let entry = content
        .lines()
        .find(|line| line.split(':').next().is_some_and(|name| name == user));
    let Some(line) = entry else {
        burn_timing(password);
        return Err(AuthError::Invalid);
    };
    verify_entry(line, password, today)
}

/// Verify one `name:password:…` shadow line against `password`.
fn verify_entry(line: &str, password: &str, today: u64) -> Result<(), AuthError> {
    let fields: Vec<&str> = line.split(':').collect();
    // name:password:lastchg:min:max:warn:inactive:expire:reserved
    // musl's shadow parser requires all 9 fields; a truncated line is
    // treated as "no such user" there — same rejection here (fail closed).
    if fields.len() < 9 {
        burn_timing(password);
        return Err(AuthError::Invalid);
    }
    let Some(hash) = fields.get(1).copied() else {
        burn_timing(password);
        return Err(AuthError::Invalid);
    };
    // Locked (`!`, `!!`, `!$6$…`, `*`, `LK`) or no-password (`""`):
    // unusable for login — same as PAM's DISALLOW_NULL_AUTHTOK path.
    if hash.is_empty() || hash.starts_with('!') || hash.starts_with('*') || !hash.starts_with('$') {
        burn_timing(password);
        return Err(AuthError::Invalid);
    }
    if !crypt_verify(password, hash) {
        return Err(AuthError::Invalid);
    }
    if account_rejected(&fields, today) {
        return Err(AuthError::Invalid);
    }
    Ok(())
}

/// Account policy: absolute expiry plus password aging (max/inactive),
/// mirroring what the old `pam_unix` account stack enforced.
fn account_rejected(fields: &[&str], today: u64) -> bool {
    let opt = |i: usize| {
        fields
            .get(i)
            .filter(|v| !v.is_empty())
            .and_then(|v| v.parse::<u64>().ok())
    };
    // Absolute account expiry: empty = never; present rejects ON the day
    // (`curdays >= sp_expire`), so expire=0 (epoch) is always expired.
    if let Some(expire) = opt(7) {
        if today >= expire {
            return true;
        }
    }
    let lastchg = opt(2);
    let max = opt(4);
    let inactive = opt(6);
    // Forced password change (`chage -d 0` writes an explicit 0).
    if lastchg == Some(0) {
        return true;
    }
    // Password aging only with a finite max (>= 99999 = never expires).
    let Some(max) = max.filter(|&m| m < 99999) else {
        return false;
    };
    let Some(lastchg) = lastchg else {
        // Empty lastchg with a finite max: pam computes `curdays - (-1)
        // > sp_max`, which rejects any sane max value.
        return today.saturating_add(1) > max;
    };
    let expires = lastchg.saturating_add(max);
    // Expired password: the old path returned PAM_NEW_AUTHTOK_REQD,
    // which was mapped to Invalid — same behavior here.
    if today > expires {
        return true;
    }
    // Inactive grace period after password expiry disables the account.
    inactive.is_some_and(|inactive| today > expires.saturating_add(inactive))
}

/// Crypt verify dispatched on the hash prefix. Unknown formats
/// (`$y$` yescrypt and friends) fail closed.
fn crypt_verify(password: &str, hash: &str) -> bool {
    if hash.starts_with("$6$") {
        pwhash::sha512_crypt::verify(password, hash)
    } else if hash.starts_with("$5$") {
        pwhash::sha256_crypt::verify(password, hash)
    } else if hash.starts_with("$1$") {
        pwhash::md5_crypt::verify(password, hash)
    } else if hash.starts_with("$2") {
        pwhash::bcrypt::verify(password, hash)
    } else {
        // Unsupported format: burn to keep timing flat, then fail closed.
        burn_timing(password);
        false
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::disallowed_methods)] // tests use the host temp dir
    use super::*;

    fn hash_of(password: &str) -> String {
        pwhash::sha512_crypt::hash(password).unwrap()
    }

    fn shadow_line(user: &str, hash: &str) -> String {
        // lastchg=1000, max=99999 (no aging), expire=0 (never)
        format!("{user}:{hash}:1000:0:99999:7:::")
    }

    #[test]
    fn correct_password_is_accepted() {
        let line = shadow_line("alice", &hash_of("s3cret"));
        let content = format!("{line}\n");
        assert!(verify_shadow(&content, "alice", "s3cret", 2000).is_ok());
    }

    #[test]
    fn wrong_password_is_rejected() {
        let line = shadow_line("alice", &hash_of("s3cret"));
        let content = format!("{line}\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "wrong", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn unknown_user_is_rejected_like_wrong_password() {
        let content = shadow_line("alice", &hash_of("s3cret"));
        assert!(matches!(
            verify_shadow(&content, "bob", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn empty_user_or_password_is_rejected() {
        let content = shadow_line("alice", &hash_of("s3cret"));
        assert!(matches!(
            verify_shadow(&content, "", "x", 2000),
            Err(AuthError::Invalid)
        ));
        assert!(matches!(
            verify_shadow(&content, "alice", "", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn locked_accounts_are_rejected() {
        for hash in ["!", "!!", "*", "!*"] {
            let content = format!("alice:{hash}:1000:0:99999:7:::\n");
            assert!(
                matches!(
                    verify_shadow(&content, "alice", "any", 2000),
                    Err(AuthError::Invalid)
                ),
                "hash {hash:?} must lock the account"
            );
        }
    }

    #[test]
    fn locked_with_remembered_hash_is_rejected() {
        let content = format!("alice:!{}:1000:0:99999:7:::\n", hash_of("s3cret"));
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn empty_password_field_is_rejected() {
        let content = "alice::1000:0:99999:7:::\n";
        assert!(matches!(
            verify_shadow(content, "alice", "anything", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn expired_account_is_rejected() {
        let hash = hash_of("s3cret");
        // expire = day 1500; today = 2000 → expired
        let content = format!("alice:{hash}:1000:0:99999:7::1500:\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
        // before the expire date → accepted
        let content = format!("alice:{hash}:1000:0:99999:7::1500:\n");
        assert!(verify_shadow(&content, "alice", "s3cret", 1400).is_ok());
    }

    #[test]
    fn expired_password_is_rejected() {
        let hash = hash_of("s3cret");
        // lastchg=1000, max=30 → password expires day 1030
        let content = format!("alice:{hash}:1000:0:30:7:::\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
        assert!(verify_shadow(&content, "alice", "s3cret", 1020).is_ok());
    }

    #[test]
    fn inactive_account_is_rejected() {
        let hash = hash_of("s3cret");
        // lastchg=1000, max=30, inactive=7 → dead after day 1037
        let content = format!("alice:{hash}:1000:0:30:7:7::\n");
        // Day 1040: past password expiry (1000+30=1030) and the inactive
        // grace (1030+7=1037) → dead. Day 1020: password still fresh.
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 1040),
            Err(AuthError::Invalid)
        ));
        assert!(verify_shadow(&content, "alice", "s3cret", 1020).is_ok());
    }

    #[test]
    fn unsupported_hash_format_fails_closed() {
        // yescrypt ($y$) and other formats we do not verify.
        for hash in ["$y$j9T$deadbeef$deadbeef", "$pbkdf2-sha256$x"] {
            let content = format!("alice:{hash}:1000:0:99999:7:::\n");
            assert!(
                matches!(
                    verify_shadow(&content, "alice", "s3cret", 2000),
                    Err(AuthError::Invalid)
                ),
                "format {hash:?} must fail closed"
            );
        }
    }

    #[test]
    #[allow(deprecated)] // legacy formats must keep verifying existing hashes
    fn sha256_and_md5_and_bcrypt_formats_verify() {
        let sha256 = pwhash::sha256_crypt::hash("pw").unwrap();
        let content = format!("a:{sha256}:1000:0:99999:7:::\n");
        assert!(verify_shadow(&content, "a", "pw", 2000).is_ok());

        let md5 = pwhash::md5_crypt::hash("pw").unwrap();
        let content = format!("a:{md5}:1000:0:99999:7:::\n");
        assert!(verify_shadow(&content, "a", "pw", 2000).is_ok());

        let bcrypt = pwhash::bcrypt::hash("pw").unwrap();
        let content = format!("a:{bcrypt}:1000:0:99999:7:::\n");
        assert!(verify_shadow(&content, "a", "pw", 2000).is_ok());
    }

    #[test]
    fn epoch_expire_is_rejected() {
        // `usermod -e 1970-01-01` writes expire=0: always expired.
        let hash = hash_of("s3cret");
        let content = format!("alice:{hash}:1000:0:99999:7::0:\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn expiry_boundary_rejects_on_the_day() {
        // pam rejects when curdays >= expire (inclusive), not after.
        let hash = hash_of("s3cret");
        let content = format!("alice:{hash}:1000:0:99999:7::1500:\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 1500),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn forced_password_change_is_rejected() {
        // `chage -d 0` writes an explicit lastchg=0: change at next login.
        let hash = hash_of("s3cret");
        let content = format!("alice:{hash}:0:0:99999:7:::\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn zero_max_expires_right_after_the_change_day() {
        // `chage -M 0`: password dies the day after it was set.
        let hash = hash_of("s3cret");
        let content = format!("alice:{hash}:1000:0:0:7:::\n");
        assert!(verify_shadow(&content, "alice", "s3cret", 1000).is_ok());
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 1001),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn empty_lastchg_with_finite_max_is_rejected() {
        // musl parses an empty lastchg as -1: curdays - (-1) > max.
        let hash = hash_of("s3cret");
        let content = format!("alice:{hash}::0:30:7:::\n");
        assert!(matches!(
            verify_shadow(&content, "alice", "s3cret", 2000),
            Err(AuthError::Invalid)
        ));
    }

    #[test]
    fn truncated_shadow_line_fails_closed() {
        // musl's parser requires all 9 fields; a short line means
        // "no such user" there — identical rejection here.
        let hash = hash_of("s3cret");
        for line in [
            format!("alice:{hash}"),
            format!("alice:{hash}:1000:0:99999:7::"),
        ] {
            assert!(
                matches!(
                    verify_shadow(&format!("{line}\n"), "alice", "s3cret", 2000),
                    Err(AuthError::Invalid)
                ),
                "line {line:?} must fail closed"
            );
        }
    }

    #[test]
    fn authenticator_reads_the_injected_shadow_file() {
        let path = std::env::temp_dir().join(format!("ursine-shadow-test-{}", std::process::id()));
        let hash = hash_of("s3cret");
        std::fs::write(&path, format!("alice:{hash}:1000:0:99999:7:::\n")).unwrap();

        let auth = ShadowAuthenticator::with_path(&path);
        let peer = PeerInfo {
            uid: 1000,
            user: "alice".into(),
        };
        assert!(auth.authenticate(&peer, "alice", "s3cret").is_ok());
        assert!(matches!(
            auth.authenticate(&peer, "alice", "wrong"),
            Err(AuthError::Invalid)
        ));
        assert!(matches!(
            auth.authenticate(&peer, "mallory", "s3cret"),
            Err(AuthError::Invalid)
        ));

        // Unreadable path → Internal (not Invalid): the operator must see it.
        let missing = ShadowAuthenticator::with_path("/nonexistent/shadow");
        assert!(matches!(
            missing.authenticate(&peer, "alice", "s3cret"),
            Err(AuthError::Internal(_))
        ));

        std::fs::remove_file(&path).ok();
    }
}
