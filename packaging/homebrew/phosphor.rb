# Homebrew cask template for Phosphor.
# Fill in after publishing a release with scripts/release.sh:
#   version  -> the tag without "v"
#   sha256   -> printed by release.sh (dist/Phosphor-<version>.zip.sha256)
#   url      -> the GitHub release asset URL of your fork/repo
# Then put it in a tap: brew tap <you>/tap && cp phosphor.rb $(brew --repo <you>/tap)/Casks/
cask "phosphor" do
  version "0.2.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/OWNER/phosphor-hud/releases/download/v#{version}/Phosphor-#{version}.zip"
  name "Phosphor"
  desc "Always-on-top HUD for AI coding plan usage (Claude Code, Codex, Antigravity, ...)"
  homepage "https://github.com/OWNER/phosphor-hud"

  depends_on macos: ">= :sonoma"

  app "Phosphor.app"

  # Until the app is signed with a Developer ID and notarized, Gatekeeper blocks the first launch.
  # Users can right-click -> Open, or: xattr -dr com.apple.quarantine /Applications/Phosphor.app
  caveats <<~EOS
    Phosphor is not notarized yet. If macOS blocks the first launch, right-click Phosphor.app -> Open.
  EOS

  zap trash: [
    "~/.config/phosphor",
    "~/Library/Application Support/Phosphor",
    "~/Library/Caches/Phosphor",
    "~/Library/Preferences/io.github.nirvanasangsara.phosphor.plist",
  ]
end
