cask "sloppy" do
  version "2.3.0"
  sha256 "17bdb41d3450fc9af95cee716b45e28ee9d93da1f1b583f26c877d6dd7afd2d0"

  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.3.0/Sloppy-macos-arm64.tar.gz"
  name "Sloppy"
  desc "Agent runtime and dashboard for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"

  binary "bin/sloppy"

  artifact "share/sloppy/dashboard", target: "#{Dir.home}/.local/share/sloppy/dashboard"
end
