cask "sloppy" do
  version "2.4.0"
  sha256 "4fbb718a955a7773a1bc065f23b677e90b20d307972796d5dd97e73f34b51f92"

  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.4.0/Sloppy-macos-arm64.tar.gz"
  name "Sloppy"
  desc "Agent runtime and dashboard for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"

  binary "bin/sloppy"

  artifact "share/sloppy/dashboard", target: "#{Dir.home}/.local/share/sloppy/dashboard"
end
