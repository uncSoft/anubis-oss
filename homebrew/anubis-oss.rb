cask "anubis-oss" do
  version "3.6"
  sha256 "40f654488803ac9410334eee3abb25260d5d0b7609ca38e9228cee31318c8124"

  url "https://github.com/uncSoft/anubis-oss/releases/download/v#{version}.0/Anubis-OSS-#{version}.zip"
  name "Anubis OSS"
  desc "Local LLM benchmarking on Apple Silicon"
  homepage "https://github.com/uncSoft/anubis-oss"

  # Homebrew's livecheck strategy for github_latest understands the
  # vX.Y.Z release tag pattern; pairs with the `auto_updates true`
  # line below so brew tracks the version it installed without
  # fighting Sparkle's in-app self-update.
  livecheck do
    url :url
    strategy :github_latest
  end

  # Anubis OSS uses Sparkle for in-app updates. Setting this tells
  # Homebrew not to auto-manage the version (it'd drift the moment
  # Sparkle ran). Users get updates either via Sparkle's prompt or
  # by running `brew upgrade --cask anubis-oss`.
  auto_updates true

  # Built against macOS 15.0 (Sequoia). MARKETING_VERSION is bumped
  # in lockstep with this — if the deployment target ever changes,
  # update both.
  depends_on macos: ">= :sequoia"

  # The .app bundle on disk is `anubis.app` (PRODUCT_NAME), but the
  # display name we want in /Applications and Spotlight is
  # "Anubis OSS". The `target:` rename achieves that.
  app "anubis.app", target: "Anubis OSS.app"

  # Sparkle ticket cache + the GRDB SQLite database + plist live
  # under these paths. Listed for `brew uninstall --zap` so users
  # who want a true uninstall get one.
  zap trash: [
    "~/Library/Application Support/com.uncsoft.anubisoss",
    "~/Library/Preferences/com.uncsoft.anubisoss.plist",
    "~/Library/Caches/com.uncsoft.anubisoss",
    "~/Library/Saved Application State/com.uncsoft.anubisoss.savedState",
  ]
end
