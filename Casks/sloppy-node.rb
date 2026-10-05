cask "sloppy-node" do
  version "2.4.0"
  sha256 "bc679d67b7cdbf46ffb39221a3c6d2b8f33fbfa62eb1e1e388f7e326bfadf33d"

  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.4.0/SloppyNode-macos-arm64.tar.gz"
  name "SloppyNode"
  desc "Local computer-control executor for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"

  binary "bin/sloppy-node"
end
