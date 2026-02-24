//
//  Secrets.example.swift
//  anubis
//
//  Copy this file to Secrets.swift and replace the placeholder with your real secret.
//  Secrets.swift is gitignored and will NOT be committed.
//
//  Generate a secret with: openssl rand -hex 32
//  The same secret must be set in your server's config.php.
//

enum Secrets {
    static let leaderboardHMACSecret = "REPLACE_WITH_YOUR_64_CHAR_HEX_SECRET"
}
