class Sloppy < Formula
  desc "Agent runtime and dashboard for Sloppy"
  homepage "https://github.com/TeamSloppy/Sloppy"
  version "2.3.0"
  url "https://github.com/TeamSloppy/Sloppy/releases/download/v2.3.0/Sloppy-linux-x86_64.tar.gz"
  sha256 "0723799175596a9068c6fb206f658b193e3448db0ace8875f9ba08f29b0113ae"
  license "AGPL-3.0-only"

  def install
    bin.install "bin/sloppy" => "sloppy"
    (share/"sloppy").install Dir["share/sloppy/*"]
  end

  test do
    system "#{bin}/sloppy", "--version"
  end
end
