# Homebrew cask for Airbag. Lives in a tap (github.com/<owner>/homebrew-airbag) until it qualifies for homebrew/cask.
cask "airbag" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  url "https://github.com/<owner>/airbag/releases/download/v#{version}/Airbag-#{version}.zip"
  name "Airbag"
  desc "Safety net for AI coding agents: snapshots, rollback, destructive-command breaker, port radar"
  homepage "https://github.com/<owner>/airbag"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Airbag.app"
  binary "#{appdir}/Airbag.app/Contents/Helpers/airbag"

  # Remove Airbag's hook entries from every agent before the binary disappears: a hook pointing at a missing
  # program fails open for most agents, but GitHub Copilot CLI denies every shell command when a hook errors.
  uninstall quit:   "dev.airbag.Airbag",
            script: {
              executable: "#{appdir}/Airbag.app/Contents/Helpers/airbag",
              args:       ["hooks", "uninstall", "--all"],
              must_succeed: false,
            }

  zap trash: [
    "~/Library/Application Support/Airbag",
    "~/Library/Preferences/dev.airbag.Airbag.plist",
    "~/Library/Caches/dev.airbag.Airbag",
  ]
end
