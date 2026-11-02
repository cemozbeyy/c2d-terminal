# Homebrew cask for C2D Terminal (ADR-039). Lives in a personal tap first (e.g. cemozbeyy/homebrew-tap, file
# Casks/c2d-terminal.rb); homebrew-cask core wants a notarized app plus notability, so that comes later.
# Per release: bump `version`, paste the DMG digest from build/release/SHA256SUMS. Never point it at an unsigned build.
cask "c2d-terminal" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256_FROM_SHA256SUMS"

  url "https://github.com/cemozbeyy/c2d-terminal/releases/download/v#{version}/C2DTerminal-#{version}.dmg"
  name "C2D Terminal"
  desc "Terminal and workspace for running and reviewing Claude Code sessions"
  homepage "https://c2dterminal.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "C2DTerminal.app"

  zap trash: [
    "~/Library/Application Support/C2D Terminal",
    "~/Library/Caches/works.c2d.terminal",
    "~/Library/Preferences/works.c2d.terminal.plist",
    "~/Library/Saved Application State/works.c2d.terminal.savedState",
  ]
end
