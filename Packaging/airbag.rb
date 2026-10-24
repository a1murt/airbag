# Homebrew cask for Airbag. Lives in a tap (github.com/a1murt/homebrew-airbag) until it qualifies for homebrew/cask.
cask "airbag" do
  version "0.1.2"
  sha256 "2cf69579d98e9a495e12822facad689bc70c45bad1a4712a5e7bc935790dd95a"

  url "https://github.com/a1murt/airbag/releases/download/v#{version}/Airbag-#{version}.zip"
  name "Airbag"
  desc "Undo for AI coding agents: snapshots before agent commands that change files"
  homepage "https://github.com/a1murt/airbag"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Airbag.app"
  binary "#{appdir}/Airbag.app/Contents/Helpers/airbag"

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

  zap trash: [
    "~/Library/Application Support/Airbag",
    "~/Library/Caches/dev.airbag.Airbag",
    "~/Library/Preferences/dev.airbag.Airbag.plist",
  ]
end
