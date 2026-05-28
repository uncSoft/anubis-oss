cask "anubis-oss" do
  version "3.7.0"
  sha256 "469a46c832ffad07dd15445ee39e82bf2513bdf433ebfe075c580b3c31a60823"

  # Tag is v#{version} (e.g. v3.6.0), but the released zip is named
  # with the major.minor only (Anubis-OSS-3.6.zip). version.major_minor
  # bridges those so livecheck (which sees the full tag) and the URL
  # template stay in sync.
  url "https://github.com/uncSoft/anubis-oss/releases/download/v#{version}/Anubis-OSS-#{version.major_minor}.zip"
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
  depends_on macos: :sequoia

  # The .app bundle on disk is `anubis.app` (PRODUCT_NAME), but the
  # display name we want in /Applications and Spotlight is
  # "Anubis OSS". The `target:` rename achieves that.
  app "anubis.app", target: "Anubis OSS.app"

  # Sparkle ticket cache + the GRDB SQLite database + plist live
  # under these paths. Listed for `brew uninstall --zap` so users
  # who want a true uninstall get one.
  zap trash: [
    "~/Library/Application Support/com.uncsoft.anubisoss",
    "~/Library/Caches/com.uncsoft.anubisoss",
    "~/Library/Preferences/com.uncsoft.anubisoss.plist",
    "~/Library/Saved Application State/com.uncsoft.anubisoss.savedState",
  ]
end
