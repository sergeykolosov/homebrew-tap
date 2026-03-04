class GlobalprotectOpenconnect < Formula
  desc "GlobalProtect VPN client based on OpenConnect, supports SSO with MFA, YubiKey"
  homepage "https://github.com/yuezk/GlobalProtect-openconnect"
  url "https://github.com/yuezk/GlobalProtect-openconnect/archive/refs/tags/v2.5.1.tar.gz"
  sha256 "b991582beb92628a9babee4f81abb0d93df2b6c7a3bfff4324b7f0e80444799e"
  license "GPL-3.0-only"

  bottle do
    root_url "https://github.com/sergeykolosov/homebrew-tap/releases/download/globalprotect-openconnect-2.5.1"
    sha256 cellar: :any,                 arm64_tahoe:  "8393747ce6f00e9614718ba6f72394528ac37b7e8f40a79413ebffa881bd64c0"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "c1f86e1ba0a29b7ebf441ca80bfc91f3c80df4e90ab1815431854d6706061408"
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
    depends_on "cairo"
    depends_on "gdk-pixbuf"
    depends_on "glib"
    depends_on "gtk+3"
    depends_on "libsoup"
    depends_on "webkitgtk"
    depends_on "xz"
    depends_on "zlib-ng-compat"
  end

  # Git submodule: OpenConnect library source pinned to commit used by v2.5.1
  # (gitlab.com/openconnect/openconnect @ 0dcdff87, v9.12-255-g0dcdff87)
  resource "openconnect-src" do
    url "https://gitlab.com/openconnect/openconnect/-/archive/0dcdff87db65daf692dc323732831391d595d98d/openconnect-0dcdff87.tar.gz"
    sha256 "efb4a49ed9866c91b37ca95aad7a89aa092447e322c81d8508c05ef1254c01e3"
  end

  # Pinned to the same commit as the openconnect Homebrew formula
  resource "vpnc-script" do
    url "https://gitlab.com/openconnect/vpnc-scripts/-/raw/5b9e7e4c8e813cc6d95888e7e1d2992964270ec8/vpnc-script"
    sha256 "dee08feb571dc788018b5d599e4a79177e6acc144d196a776a521ff5496fddb8"
  end

  def install
    # Populate the git submodule directory, it's not in GitHub archive tarball
    resource("openconnect-src").stage "crates/openconnect/deps/openconnect"

    # Private vpnc-script path to avoid conflict with the openconnect formula
    # (whether installed or not), which installs it to etc/"vpnc/vpnc-script"
    (libexec/"gpclient").install resource("vpnc-script")
    chmod 0755, libexec/"gpclient/vpnc-script"

    # Patch hardcoded paths both for own and openconnect's scripts
    inreplace "crates/openconnect/src/vpn_utils.rs" do |s|
      s.gsub! "/etc/vpnc/vpnc-script",
              "#{opt_prefix}/libexec/gpclient/vpnc-script"
      s.gsub! "/opt/homebrew/etc/vpnc/vpnc-script",
              "#{HOMEBREW_PREFIX}/etc/vpnc/vpnc-script",
              audit_result: false
      s.gsub! "/usr/libexec/gpclient/hipreport.sh",
              "#{opt_prefix}/libexec/gpclient/hipreport.sh"
      s.gsub! "/opt/homebrew/opt/openconnect/libexec/openconnect/hipreport.sh",
              "#{HOMEBREW_PREFIX}/opt/openconnect/libexec/openconnect/hipreport.sh",
              audit_result: false
    end

    inreplace "crates/common/src/constants.rs" do |s|
      s.gsub! "/usr/bin/gpclient", "#{bin}/gpclient"
      s.gsub! "/usr/bin/gpservice", "#{bin}/gpservice"
      s.gsub! "/usr/bin/gpgui-helper", "#{bin}/gpgui-helper"
      s.gsub! "/usr/bin/gpgui", "#{bin}/gpgui"
      s.gsub! "/usr/bin/gpauth", "#{bin}/gpauth"
      s.gsub! "/opt/homebrew/", "#{HOMEBREW_PREFIX}/", audit_result: false
    end

    # Install only the CLI apps, GUI apps (gpgui-helper) are excluded because
    # GUI version is a paid application

    system "cargo", "install", *std_cargo_args(path: "apps/gpclient")
    system "cargo", "install", *std_cargo_args(path: "apps/gpservice")
    system "cargo", "install", *std_cargo_args(path: "apps/gpauth")

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
        To enable browser-based (SSO) authentication, install the URL handler app
        that forwards globalprotectcallback:// redirects to gpclient:

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
