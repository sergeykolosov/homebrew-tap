class GlobalprotectOpenconnectSlim < Formula
  desc "GlobalProtect VPN client (slim build, system-browser SSO; no embedded webview)"
  homepage "https://github.com/yuezk/GlobalProtect-openconnect"
  url "https://github.com/yuezk/GlobalProtect-openconnect/archive/refs/tags/v2.5.4.tar.gz"
  sha256 "ac2252f579b853901e867aed56a1a9f6a65f77f1a1337017f13d0efed40b780d"
  license "GPL-3.0-only"

  bottle do
    root_url "https://github.com/sergeykolosov/homebrew-tap/releases/download/globalprotect-openconnect-slim-2.5.4"
    sha256 cellar: :any,                 arm64_tahoe:  "d39fa915f3d43cf2e4e392ba02a164abe97510bbd50586483921865451de67b3"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "b03e43fc38e646daccd9107df1f1bd99253f687f8bbc01baff62c7a560d20617"
  end

  depends_on "autoconf" => :build
  depends_on "automake" => :build
  depends_on "libtool" => :build
  depends_on "pkgconf" => :build
  depends_on "rust" => :build

  # From crates/openconnect/build.rs
  depends_on "gmp" # via gnutls
  depends_on "gnutls"
  depends_on "lz4"
  depends_on "nettle" # via gnutls
  depends_on "openssl@3"
  depends_on "p11-kit" # via gnutls

  uses_from_macos "libxml2"
  uses_from_macos "zlib"

  on_linux do
    depends_on "xz"              # gpservice links xz2 -> liblzma
    depends_on "zlib-ng-compat"  # Linuxbrew zlib replacement
  end

  # Both formulae install gpclient/gpservice/gpauth to bin
  conflicts_with "globalprotect-openconnect",
                 because: "both install gpclient, gpservice, and gpauth"

  # Git submodule: OpenConnect library source pinned to commit used by v2.5.4
  # (gitlab.com/openconnect/openconnect @ 0dcdff87, v9.12-255-g0dcdff87)
  resource "openconnect-src" do
    url "https://gitlab.com/openconnect/openconnect/-/archive/0dcdff87db65daf692dc323732831391d595d98d/openconnect-0dcdff87.tar.gz"
    sha256 "efb4a49ed9866c91b37ca95aad7a89aa092447e322c81d8508c05ef1254c01e3"
  end

  def install
    # Populate the git submodule directory, it's not in GitHub archive tarball
    resource("openconnect-src").stage "crates/openconnect/deps/openconnect"

    # Private vpnc-script path to avoid conflict with the openconnect formula
    # (whether installed or not), which installs it to etc/"vpnc/vpnc-script"
    (libexec/"gpclient").install "packaging/files/usr/libexec/gpclient/vpnc-script"

    # Use our libexec in the cross-platform vpnc-script search list, and in the
    # Linux hipreport.sh path. The #[cfg]-gated macOS entries in this file point
    # at standard Homebrew prefixes (aarch64: /opt/homebrew, x86_64: /usr/local)
    inreplace "crates/openconnect/src/vpn_utils.rs" do |s|
      s.gsub! "/etc/vpnc/vpnc-script",
              "#{opt_prefix}/libexec/gpclient/vpnc-script"
      s.gsub! "/usr/libexec/gpclient/hipreport.sh",
              "#{opt_prefix}/libexec/gpclient/hipreport.sh"
    end

    # Patch Linux binary fallbacks; macOS #[cfg]-gated defaults upstream are OK
    inreplace "crates/common/src/constants.rs" do |s|
      s.gsub! "/usr/bin/gpclient", "#{bin}/gpclient"
      s.gsub! "/usr/bin/gpservice", "#{bin}/gpservice"
      s.gsub! "/usr/bin/gpgui-helper", "#{bin}/gpgui-helper"
      s.gsub! "/usr/bin/gpgui", "#{bin}/gpgui"
      s.gsub! "/usr/bin/gpauth", "#{bin}/gpauth"
    end

    # Drop the unconditional gtk hard requirement from gpapi. Without this, the
    # Linux build pulls gtk+3 + glib + their transitive chain (webkitgtk etc.)
    # even when no tauri/webview feature is active. The crates/gpapi/src/utils/
    # window.rs file that imports gtk is module-gated by `#[cfg(feature =
    # "tauri")]` in mod.rs, and `browser-auth` doesn't activate gpapi/tauri, so
    # leaving the file alone is safe — cargo never reaches its gtk imports.
    inreplace "crates/gpapi/Cargo.toml", /^gtk = "0\.18"\n/, ""

    # webview-auth used to pull tokio's rt-multi-thread feature transitively
    # via tauri. Without it, gpauth's #[tokio::main] (default multi-thread
    # flavor) fails to compile. Re-enable rt-multi-thread on the workspace
    # tokio dep so the runtime stays multi-threaded as upstream intended.
    inreplace "Cargo.toml",
              'tokio = { version = "1" }',
              'tokio = { version = "1", features = ["rt-multi-thread"] }'

    # Drop --locked: Cargo.toml edit above desyncs Cargo.lock (no gpapi -> gtk).
    # gpauth: --no-default-features disables `webview-auth` (its only default).
    # The browser-auth path stays on via gpauth's unconditional dep declaration
    # `auth = { features = ["browser-auth"] }` — no --features flag needed.
    system "cargo", "install", *(std_cargo_args(path: "apps/gpclient")  - ["--locked"])
    system "cargo", "install", *(std_cargo_args(path: "apps/gpservice") - ["--locked"])
    system "cargo", "install", *(std_cargo_args(path: "apps/gpauth")    - ["--locked"]),
           "--no-default-features"

    if OS.linux?
      inreplace "packaging/files/usr/lib/NetworkManager/dispatcher.d/pre-down.d/gpclient.down" do |s|
        s.gsub! "/usr/bin/gpclient", "#{bin}/gpclient"
      end

      (pkgshare/"NetworkManager").install Dir["packaging/files/usr/lib/NetworkManager/*"]
    end

    inreplace "packaging/files/usr/libexec/gpclient/hipreport.sh" do |s|
      s.gsub! "/usr/bin/gpclient", "#{bin}/gpclient"
    end

    (libexec/"gpclient").install "packaging/files/usr/libexec/gpclient/hipreport.sh"

    if OS.mac?
      # Build the globalprotectcallback:// URL handler app bundle, roughly based
      # on https://github.com/yuezk/GlobalProtect-openconnect/commit/43f5b3b69939d358094f1e6eaacda953a1c178c8
      callback_url_scheme = "globalprotectcallback"

      applescript = buildpath/"GlobalProtectURLHandler.applescript"
      applescript.write <<~APPLESCRIPT
        -- GlobalProtect callback URL handler
        -- Handles #{callback_url_scheme}:// URLs and forwards them to gpclient.
        on open location urlString
          set logFile to "/tmp/gpclient-url-handler.log"
          set currentDate to do shell script "date '+%Y-%m-%d %H:%M:%S'"
          try
            set logFileRef to open for access logFile with write permission
            write (currentDate & " - Received URL: " & urlString & return) to logFileRef starting at eof
            close access logFileRef
          on error
            try
              close access logFile
            end try
          end try
          try
            do shell script "#{opt_bin}/gpclient launch-gui " & quoted form of urlString
          on error errMsg
            try
              set logFileRef to open for access logFile with write permission
              write (currentDate & " - Error: " & errMsg & return) to logFileRef starting at eof
              close access logFileRef
            on error
              try
                close access logFile
              end try
            end try
            display dialog "Error launching GlobalProtect client: " & errMsg buttons {"OK"} default button "OK" with icon stop
          end try
        end open location
        on run
          display dialog "This application handles #{callback_url_scheme}:// URLs. It should not be launched directly." buttons {"OK"} default button "OK" with icon note
          quit
        end run
      APPLESCRIPT

      app = prefix/"GlobalProtectURLHandler.app"
      system "osacompile", "-o", app, applescript

      plist = app/"Contents/Info.plist"
      buddy = "/usr/libexec/PlistBuddy"
      # Bundle identity
      system buddy, "-c", "Add :CFBundleIdentifier string 'com.yuezk.globalprotect-url-handler'", plist
      system buddy, "-c", "Add :CFBundleDisplayName string 'GlobalProtect URL Handler'", plist
      # Background-only — no Dock icon, no menu bar
      system buddy, "-c", "Add :LSBackgroundOnly bool true", plist
      system buddy, "-c", "Add :LSUIElement bool true", plist
      # Register the globalprotectcallback:// URL scheme
      system buddy, "-c", "Add :CFBundleURLTypes array", plist
      system buddy, "-c", "Add :CFBundleURLTypes:0 dict", plist
      system buddy, "-c", "Add :CFBundleURLTypes:0:CFBundleURLName string 'GlobalProtect Callback Handler'", plist
      system buddy, "-c", "Add :CFBundleURLTypes:0:CFBundleURLSchemes array", plist
      system buddy, "-c", "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string '#{callback_url_scheme}'", plist
    end
  end

  def caveats
    if OS.linux?
      <<~EOS
        This is the slim build: gpauth uses the system browser for SSO
        (no embedded webview, no gtk/webkitgtk runtime deps).

        NetworkManager dispatcher hooks were installed to:

          #{opt_pkgshare}/NetworkManager

        NetworkManager loads dispatcher scripts from system directories like:

          /usr/lib/NetworkManager/dispatcher.d

        To enable the gpclient dispatcher hooks, create the system directories
        and symlink the installed scripts:

          sudo mkdir -p /usr/lib/NetworkManager/dispatcher.d/pre-down.d
          sudo ln -sf #{opt_pkgshare}/NetworkManager/dispatcher.d/pre-down.d/gpclient.down \
            /usr/lib/NetworkManager/dispatcher.d/pre-down.d/gpclient.down
          sudo ln -sf #{opt_pkgshare}/NetworkManager/dispatcher.d/gpclient-nm-hook \
            /usr/lib/NetworkManager/dispatcher.d/gpclient-nm-hook

        Then restart NetworkManager:

          sudo systemctl restart NetworkManager
      EOS
    else
      <<~EOS
        This is the slim build: gpauth uses the system browser for SSO
        (no embedded webview).

        Install the URL handler app that forwards globalprotectcallback://
        redirects from the system browser back to gpclient:

          cp -r #{opt_prefix}/GlobalProtectURLHandler.app ~/Applications/
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \\
            -r -f ~/Applications/GlobalProtectURLHandler.app

        You may need to log out and back in for the URL scheme to be fully recognized.
        To test if it's working, run:

          open 'globalprotectcallback:test'

        Check /tmp/gpclient-url-handler.log for debug logs.

        To uninstall the handler, remove the app and re-run lsregister without -f.
      EOS
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/gpclient --version")
    assert_match version.to_s, shell_output("#{bin}/gpauth --version")
    assert_match version.to_s, shell_output("#{bin}/gpservice --version")
  end
end
