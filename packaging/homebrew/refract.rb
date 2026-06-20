class Refract < Formula
  desc "Fast Ruby language server backed by SQLite"
  homepage "https://github.com/hrtsx/refract"
  version "0.1.0-rc1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-macos"
      sha256 "e711d2165838cbd0937c93c588a6eb720cc28565deb132c69be2b62eb8ea14c6"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-macos"
      sha256 "8514bc2004b6c82eb3e5d5d2f313e9db96d5d196409baf2385c05d98ec1d6c2b"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-aarch64-linux"
      sha256 "5a7084cc72f085ca0c41e50d0f51334827684cafcaa9e8e4dac0abb9bd1968a1"
    else
      url "https://github.com/hrtsx/refract/releases/download/v#{version}/refract-x86_64-linux"
      sha256 "790e923356aafa6fac6a2ca26bac4d1a994ab7fe5ffc7280e7c3dd1c42d6e4cf"
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
