# Homebrew cask for Airbag. Lives in a tap (github.com/a1murt/homebrew-airbag) until it qualifies for homebrew/cask.
cask "airbag" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  url "https://github.com/a1murt/airbag/releases/download/v#{version}/Airbag-#{version}.zip"
  name "Airbag"
  desc "Undo for AI coding agents: snapshots before every agent command"
  homepage "https://github.com/a1murt/airbag"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Airbag.app"
  binary "#{appdir}/Airbag.app/Contents/Helpers/airbag"

  # Remove Airbag's hook entries from every agent before the binary disappears: a hook pointing at a missing
  # program fails open for most agents, but GitHub Copilot CLI denies every shell command when a hook errors.
  # Homebrew runs this on upgrades as well, so the hooks are remembered and the postflight of the new version puts
  # them back; after a real uninstall none is left pointing at the missing binary.
  uninstall quit:   "dev.airbag.Airbag",
            script: {
              executable:   "#{appdir}/Airbag.app/Contents/Helpers/airbag",
              args:         ["hooks", "uninstall", "--all", "--remember"],
              must_succeed: false,
            }

  postflight_steps do
    # The hooks the previous version remembered (upgrade or reinstall); writes only the agents' and Airbag's folders.
    run "{{appdir}}/Airbag.app/Contents/Helpers/airbag",
        args:           ["hooks", "install", "--remembered"],
        must_succeed:   false,
        writable_paths: [".claude", ".codex", ".cursor", ".gemini", ".copilot", "Library/Application Support/Airbag"],
        writable_base:  :home
    # Built and ad-hoc signed by the project's public CI until it has a Developer ID: Homebrew users skip the
    # one-time Gatekeeper prompt the DMG shows.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Airbag.app"], must_succeed: false
  end

  zap trash: [
    "~/Library/Application Support/Airbag",
    "~/Library/Preferences/dev.airbag.Airbag.plist",
    "~/Library/Caches/dev.airbag.Airbag",
  ]
end
