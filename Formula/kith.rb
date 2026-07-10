# Build-from-source Homebrew formula.
#
# The signed + notarized cask in supaku/tools is the recommended install.
# This formula remains available for contributors who want Homebrew to build
# the CLI from source with the local Swift toolchain:
#
#   brew tap supaku/kith https://github.com/supaku/kith
#   brew install kith
#
class Kith < Formula
  desc "CLI bridging Apple Contacts and iMessage for terminal users and AI agents"
  homepage "https://github.com/supaku/kith"
  url "https://github.com/supaku/kith.git",
      tag: "v0.2.4"
  license "MIT"
  head "https://github.com/supaku/kith.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "--arch", Hardware::CPU.arch.to_s
    bin.install ".build/release/kith"
  end

  test do
    assert_match "kith", shell_output("#{bin}/kith version")
    assert_match version.to_s, shell_output("#{bin}/kith version")

    # Manifest must parse as JSON and list the killer command.
    manifest = shell_output("#{bin}/kith tools manifest --style kith")
    assert_match "history", manifest
    assert_match "find", manifest
  end
end
