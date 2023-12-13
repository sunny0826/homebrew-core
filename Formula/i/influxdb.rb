class Influxdb < Formula
  desc "Time series, events, and metrics database"
  homepage "https://influxdata.com/time-series-platform/influxdb/"
  # When bumping to 3.x, remove from `permitted_formula_license_mismatches.json`
  # and update license stanza to `license any_of: ["Apache-2.0", "MIT"]`
  # Ref: https://github.com/influxdata/influxdb/blob/main/Cargo.toml#L124
  license "MIT"
  head "https://github.com/influxdata/influxdb.git", branch: "main-2.x"

  stable do
    url "https://github.com/influxdata/influxdb.git",
        tag:      "v2.7.3",
        revision: "ed645d9216af16b49f8c6a49aee84341ea168180"

    # Backport flux upgrades to build with newer Rust 1.72+. Remove in the next release.
    patch :DATA # Minimal diff to apply upstream commits. Reverted via inreplace during install
    patch do
      url "https://github.com/influxdata/influxdb/commit/08b4361b367460fb8c6b77047ff518634739ccec.patch?full_index=1"
      sha256 "9cc2b080012dcc39f57e3b14aedb6e6255388944c793ca8016a82b7b996d5642"
    end
    patch do
      url "https://github.com/influxdata/influxdb/commit/924735a96d73ea4c67501447f0b885a6dc2e0d28.patch?full_index=1"
      sha256 "b0da74d79580ab4ccff57858d053f447ae23f60909875a73b4f21376c2f1ce95"
    end
  end

  # There can be a notable gap between when a version is tagged and a
  # corresponding release is created, so we check releases instead of the Git
  # tags. Upstream maintains multiple major/minor versions and the "latest"
  # release may be for an older version, so we have to check multiple releases
  # to identify the highest version.
  livecheck do
    url :stable
    regex(/^v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  bottle do
    rebuild 1
    sha256 cellar: :any_skip_relocation, arm64_ventura:  "670862068c34ac14ec02285f5a595368cfd220b40a1b751048f8c7e841c43b13"
    sha256 cellar: :any_skip_relocation, arm64_monterey: "dfdf6a86156a846eec66077e5e106841db510b1dbb156344a4ce211b0d6ff245"
    sha256 cellar: :any_skip_relocation, arm64_big_sur:  "dd78caabdcf598ab0928142a4c96695e4db7ac2af95002a8fbfb9b5f5fb199d6"
    sha256 cellar: :any_skip_relocation, ventura:        "47c76305bcaf77dc4b5f1d714a02e28a53dbc7cfd12bb46c662a60e3c08322fa"
    sha256 cellar: :any_skip_relocation, monterey:       "283ab05e2a2908868cccd57412178ac5d3b38c727e08b9e322fd40db6e45e202"
    sha256 cellar: :any_skip_relocation, big_sur:        "f42f0c68eddfce6c3bb724b49da6b9922301510627d3ac19462daa44ee4c4b43"
    sha256 cellar: :any_skip_relocation, x86_64_linux:   "3182bc34bd3089c1a37b2c18301d2d1e9d17901d9360f3a95d804529b969f88f"
  end

  depends_on "breezy" => :build
  depends_on "go" => :build
  depends_on "pkg-config" => :build
  depends_on "protobuf" => :build
  depends_on "rust" => :build

  # NOTE: The version here is specified in the go.mod of influxdb.
  # If you're upgrading to a newer influxdb version, check to see if this needs upgraded too.
  resource "pkg-config-wrapper" do
    url "https://github.com/influxdata/pkg-config/archive/refs/tags/v0.2.11.tar.gz"
    sha256 "52b22c151163dfb051fd44e7d103fc4cde6ae8ff852ffc13adeef19d21c36682"

    livecheck do
      url "https://raw.githubusercontent.com/influxdata/influxdb/v#{LATEST_VERSION}/go.mod"
      regex(/pkg-config\s+v?(\d+(?:\.\d+)+)/i)
    end
  end

  # NOTE: The version/URL here is specified in scripts/fetch-ui-assets.sh in influxdb.
  # If you're upgrading to a newer influxdb version, check to see if this needs upgraded too.
  resource "ui-assets" do
    url "https://github.com/influxdata/ui/releases/download/OSS-v2.7.1/build.tar.gz"
    sha256 "d24e7d48abedf6916ddd649de4f4544e16df6dcb6dd9162d6b16b1a322c80a6f"

    livecheck do
      url "https://raw.githubusercontent.com/influxdata/influxdb/v#{LATEST_VERSION}/scripts/fetch-ui-assets.sh"
      regex(/UI_RELEASE=["']?OSS[._-]v?(\d+(?:\.\d+)+)["']?$/i)
    end
  end

  def install
    # Revert :DATA patch to avoid having to modify go.sum
    if build.stable?
      inreplace "go.mod", "golang.org/x/tools v0.14.0",
                          "golang.org/x/tools v0.14.1-0.20231011210224-b9b97d982b0a"
    end

    # Set up the influxdata pkg-config wrapper to enable just-in-time compilation & linking
    # of the Rust components in the server.
    resource("pkg-config-wrapper").stage do
      system "go", "build", *std_go_args(output: buildpath/"bootstrap/pkg-config")
    end
    ENV.prepend_path "PATH", buildpath/"bootstrap"

    # Extract pre-build UI resources to the location expected by go-bindata.
    resource("ui-assets").stage(buildpath/"static/data/build")
    # Embed UI files into the Go source code.
    system "make", "generate-web-assets"

    # Build the server.
    ldflags = %W[
      -s
      -w
      -X main.version=#{version}
      -X main.commit=#{Utils.git_short_head(length: 10)}
      -X main.date=#{time.iso8601}
    ]

    system "go", "build", *std_go_args(output: bin/"influxd", ldflags: ldflags),
           "-tags", "assets,sqlite_foreign_keys,sqlite_json", "./cmd/influxd"

    data = var/"lib/influxdb2"
    data.mkpath

    # Generate default config file.
    config = buildpath/"config.yml"
    config.write Utils.safe_popen_read(bin/"influxd", "print-config",
                                       "--bolt-path=#{data}/influxdb.bolt",
                                       "--engine-path=#{data}/engine")
    (etc/"influxdb2").install config

    # Create directory for DB stdout+stderr logs.
    (var/"log/influxdb2").mkpath
  end

  def caveats
    <<~EOS
      This formula does not contain command-line interface; to install it, run:
        brew install influxdb-cli
    EOS
  end

  service do
    run opt_bin/"influxd"
    keep_alive true
    working_dir HOMEBREW_PREFIX
    log_path var/"log/influxdb2/influxd_output.log"
    error_log_path var/"log/influxdb2/influxd_output.log"
    environment_variables INFLUXD_CONFIG_PATH: etc/"influxdb2/config.yml"
  end

  test do
    influxd_port = free_port
    influx_host = "http://localhost:#{influxd_port}"
    ENV["INFLUX_HOST"] = influx_host

    influxd = fork do
      exec "#{bin}/influxd", "--bolt-path=#{testpath}/influxd.bolt",
                             "--engine-path=#{testpath}/engine",
                             "--http-bind-address=:#{influxd_port}",
                             "--log-level=error"
    end
    sleep 30

    # Check that the server has properly bundled UI assets and serves them as HTML.
    curl_output = shell_output("curl --silent --head #{influx_host}")
    assert_match "200 OK", curl_output
    assert_match "text/html", curl_output
  ensure
    Process.kill("TERM", influxd)
    Process.wait influxd
  end
end

__END__
diff --git a/go.mod b/go.mod
index a5e2981ff2..2bf67347a4 100644
--- a/go.mod
+++ b/go.mod
@@ -68,7 +68,7 @@ require (
 	golang.org/x/sys v0.13.0
 	golang.org/x/text v0.13.0
 	golang.org/x/time v0.0.0-20220210224613-90d013bbcef8
-	golang.org/x/tools v0.14.1-0.20231011210224-b9b97d982b0a
+	golang.org/x/tools v0.14.0
 	google.golang.org/protobuf v1.28.1
 	gopkg.in/yaml.v2 v2.4.0
 	gopkg.in/yaml.v3 v3.0.1
