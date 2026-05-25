# Homebrew Cask — staging area

This folder holds the draft of the Anubis OSS [Homebrew Cask][cask] formula and the per-release bump script. The actual published cask lives in a separate tap repository (`uncsoft/homebrew-anubis`); the files here are the **canonical source** that gets copied into the tap.

[cask]: https://docs.brew.sh/Cask-Cookbook

## Files

- `anubis-oss.rb` — the cask formula. Mirrors `Casks/anubis-oss.rb` in the tap repo.

## Per-release workflow

After a new GitHub release is published (zip uploaded as an asset):

### Quick: local edit only

```bash
scripts/bump-cask.sh 3.7
# → updates homebrew/anubis-oss.rb in-place
# → copy that file into the tap repo at Casks/anubis-oss.rb, commit, push
```

### Tap-aware: edit + commit + push the tap repo

```bash
scripts/bump-cask.sh 3.7 --tap ../homebrew-anubis
# → edits Casks/anubis-oss.rb in the tap, commits, pushes to default branch
```

### Open a PR instead of pushing to main

```bash
scripts/bump-cask.sh 3.7 --tap ../homebrew-anubis --pr
# → creates a branch, pushes, opens PR via gh
```

## One-time setup

1. Create `uncSoft/homebrew-anubis` on GitHub (the `homebrew-` prefix is mandatory for Homebrew to recognize it as a tap).
2. Inside that repo, create `Casks/anubis-oss.rb` by copying this folder's `anubis-oss.rb`.
3. Audit it locally:
   ```bash
   brew tap uncsoft/anubis https://github.com/uncSoft/homebrew-anubis
   brew audit --new-cask anubis-oss
   brew style anubis-oss
   ```
4. Install/uninstall round-trip to confirm:
   ```bash
   brew install --cask anubis-oss
   open -a "Anubis OSS"
   brew uninstall --cask --zap anubis-oss
   ```
5. Add to the main README a line:
   ```
   brew install --cask uncsoft/anubis/anubis-oss
   ```

## When to graduate to the official `homebrew/cask` repo

When all of the following hold:
- ≥30 forks, ≥30 watchers, ≥75 stars on the main repo (we already have 153 ⭐)
- Stable release cadence with no install-path regressions for 2–3 consecutive releases
- The cask formula hasn't needed structural edits in a while (only `version` + `sha256` bumps)

At that point: open a PR against [`homebrew/homebrew-cask`](https://github.com/Homebrew/homebrew-cask) with the same `anubis-oss.rb`. Once accepted, deprecate this tap (or keep it as a backup channel — Homebrew prefers one or the other).
