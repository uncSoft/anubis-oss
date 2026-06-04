//
//  Secrets.swift
//  anubis
//
//  The open-source build ships with an EMPTY leaderboard secret, so the app
//  compiles and runs out of the box — no setup required.
//
//  Submitting to the *official* Anubis leaderboard needs the project's HMAC
//  signing secret, which is intentionally kept private (publishing it would
//  let anyone forge submissions). So self-compiled / forked builds can't
//  upload to the official leaderboard — every other feature works normally.
//
//  Running your OWN leaderboard server? Put your 64-char hex secret below
//  (it must match your server's config). Generate one with:
//      openssl rand -hex 32
//
enum Secrets {
    /// HMAC secret for signing leaderboard submissions. Empty = uploads to the
    /// official leaderboard are disabled (expected for OSS / forked builds).
    static let leaderboardHMACSecret = ""

    /// Whether this build can sign leaderboard submissions.
    static var isLeaderboardConfigured: Bool { !leaderboardHMACSecret.isEmpty }
}
