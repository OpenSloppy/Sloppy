class Sloppy < Formula
  desc "Agent runtime and dashboard for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"
  version "2.4.0"
  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.4.0/Sloppy-linux-x86_64.tar.gz"
  sha256 "ddd81748ae0bbc4dab5d0e8c95877495d323bb47c5c7284f40bc963b7b43c6db"
  license "AGPL-3.0-only"

  def install
    bin.install "bin/sloppy" => "sloppy"
    (share/"sloppy").install Dir["share/sloppy/*"]
  end

  test do
    system "#{bin}/sloppy", "--version"
  end
end
