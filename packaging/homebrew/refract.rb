class Refract < Formula
  desc "Fast Ruby language server backed by SQLite"
  homepage "https://github.com/hrtsx/refract"
  version "0.1.0-rc1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-macos"
      sha256 "23cc1381e21e7a05f453384f9e8554ba7abe1b4cfaf2f07cadb72d3432fd386c"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-macos"
      sha256 "fa506ae3b5390ac50cf20a1eb4bcd2f440f8d209b69bc5aa3f71871a7e4afed0"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-linux"
      sha256 "3c1d84274b82120de0ce4403e9f5279c2d15ca4eb11a557c19c77acacccfbe20"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-linux"
      sha256 "0529f0480b08d8ded5b55f8c4b96be07d6731e72e474c5e4904d91d34628a86b"
    end
  end

  def install
    binary = Dir["refract-*"].first || "refract"
    bin.install binary => "refract"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/refract --version")
  end
end
