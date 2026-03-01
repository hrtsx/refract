class Refract < Formula
  desc "Fast Ruby language server backed by SQLite"
  homepage "https://github.com/hrtsx/refract"
  version "0.3.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-macos"
      sha256 "320ba540e58c60856aaaee7db20fe4ebcc43eb3749b7bec266feee53ccf79236"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-macos"
      sha256 "05cffe451c0c7f352aa9ed2f629a5dadcde5b1237e67b56913fced389cccd964"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-linux"
      sha256 "9a23c84df799b3c194e2fef1a0b9327fa7f58699cd60f0292c71810af0a0a57f"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-linux"
      sha256 "b94dd3b025dac681ffef01a62d3b834072817fcfcd5bd56b450a40e826176642"
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
