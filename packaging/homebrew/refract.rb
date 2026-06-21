class Refract < Formula
  desc "Fast Ruby language server backed by SQLite"
  homepage "https://github.com/hrtsx/refract"
  version "0.1.0-rc1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-macos"
      sha256 "4b2e3a8d62556fe51cd7ab551f5ffeb290d7cccb90dea5162a439425ab76a3d3"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-macos"
      sha256 "3795e8d49f7879251161ec883649e2745c115dfcb009fc35a150f28a736a44e5"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-linux"
      sha256 "3e9b0a8b6443ce566dcfafd5cf4a61f7fc3777c749e0be385eaec650fa4dace9"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-linux"
      sha256 "de0d3b7d3717acb968da209f73991ed5ed754c44d6160c4e55afd5c969ef8652"
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
