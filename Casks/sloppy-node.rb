cask "sloppy-node" do
  version "2.3.0"
  sha256 "c8765c682b09a3f522c811a91038686b836381b7826eac3019e8eb8dbdcd91a1"

  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.3.0/SloppyNode-macos-arm64.tar.gz"
  name "SloppyNode"
  desc "Local computer-control executor for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"

  binary "bin/sloppy-node"
end
