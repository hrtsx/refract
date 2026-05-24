class Refract < Formula
  desc "Fast Ruby language server backed by SQLite"
  homepage "https://github.com/hrtsx/refract"
  version "0.1.0-beta.1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-macos"
      sha256 "9c01166a1ca97761267a7621e1cb7fc22a517958bb7a765e90eea968b6c90adf"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-macos"
      sha256 "b6a0dcf4059bb9680e43b559ca8a68ed81cfc4ebe5cdf4297082765cbcea9d12"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-linux"
      sha256 "e4a6830481ef29a53941c8afabb43c3ea8c1ff9e6dabf37e0b9fd94f3b648117"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-linux"
      sha256 "f56267482f3ca83e3dd9b512e8f01aebd531429aca99ba8f3c126f49ef42a6bd"
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
