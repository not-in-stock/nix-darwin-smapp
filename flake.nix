{
  description = "SMAppService wrapper for nix-darwin — Nix icon in macOS Login Items";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = fn:
        nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ] (system:
          fn nixpkgs.legacyPackages.${system}
        );

      # Available built-in icons
      icons = {
        nix-snowflake-colors = ./resources/nix-snowflake-colors.icns;
        nix-snowflake-white = ./resources/nix-snowflake-white.icns;
      };
    in
    {
      inherit icons;

      lib.mkServiceBundle =
        pkgs:
        {
          bundleIdentifier,
          bundleName,
          icon ? icons.nix-snowflake-colors,
          services, # attrset: { "org.nixos.skhd" = { command = "exec .../bin/skhd"; }; }
        }:
        let
          serviceNames = builtins.attrNames services;

          mkWrapperSrc = name: command:
            pkgs.writeText "wrapper-${name}.c" ''
              #include <unistd.h>
              int main() {
                char *argv[] = {"/bin/sh", "-c", ${builtins.toJSON command}, NULL};
                execv("/bin/sh", argv);
                return 1;
              }
            '';

          mkAgentPlist = name:
            pkgs.writeText "${name}.plist" ''
              <?xml version="1.0" encoding="UTF-8"?>
              <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
              <plist version="1.0">
              <dict>
                  <key>Label</key>
                  <string>${name}</string>
                  <key>BundleProgram</key>
                  <string>Contents/MacOS/${name}</string>
                  <key>RunAtLoad</key>
                  <true/>
                  <key>AssociatedBundleIdentifiers</key>
                  <array>
                      <string>${bundleIdentifier}</string>
                  </array>
              </dict>
              </plist>
            '';

          infoPlist = pkgs.writeText "Info.plist" ''
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>${bundleIdentifier}</string>
                <key>CFBundleName</key>
                <string>${bundleName}</string>
                <key>CFBundleDisplayName</key>
                <string>${bundleName}</string>
                <key>CFBundleExecutable</key>
                <string>register</string>
                <key>CFBundleIconFile</key>
                <string>AppIcon</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleVersion</key>
                <string>1.0</string>
                <key>LSUIElement</key>
                <true/>
            </dict>
            </plist>
          '';

          # Sanitize bundle name for use as .app directory name
          appName = bundleName;
        in
        pkgs.stdenv.mkDerivation {
          name = "smapp-bundle-${builtins.replaceStrings [" "] ["-"] appName}";
          src = ./src;

          buildInputs = [
            pkgs.apple-sdk_15
          ];

          buildPhase =
            let
              wrapperCommands = builtins.concatStringsSep "\n" (map (name:
                let
                  cfg = services.${name};
                  wrapperSrc = mkWrapperSrc name cfg.command;
                in ''
                  $CC -o "$BUNDLE/Contents/MacOS/${name}" ${wrapperSrc}
                  cp ${mkAgentPlist name} "$BUNDLE/Contents/Library/LaunchAgents/${name}.plist"
                ''
              ) serviceNames);
            in ''
              runHook preBuild

              BUNDLE="$out/${appName}.app"
              mkdir -p "$BUNDLE/Contents/MacOS"
              mkdir -p "$BUNDLE/Contents/Resources"
              mkdir -p "$BUNDLE/Contents/Library/LaunchAgents"

              cp ${infoPlist} "$BUNDLE/Contents/Info.plist"
              cp ${icon} "$BUNDLE/Contents/Resources/AppIcon.icns"

              $CC -framework Foundation -framework ServiceManagement \
                -o "$BUNDLE/Contents/MacOS/register" \
                register.m

              ${wrapperCommands}

              /usr/bin/codesign --force --sign - --deep "$BUNDLE"

              runHook postBuild
            '';

          installPhase = "true";
        };

      darwinModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.nix-darwin-smapp;

          bundleSubmodule = lib.types.submodule {
            options = {
              bundleIdentifier = lib.mkOption {
                type = lib.types.str;
                description = "CFBundleIdentifier for the .app bundle";
              };

              bundleName = lib.mkOption {
                type = lib.types.str;
                description = "Display name shown in System Settings";
              };

              icon = lib.mkOption {
                type = lib.types.path;
                default = icons.nix-snowflake-colors;
                description = "Path to .icns icon file. Built-in options: nix-snowflake-colors, nix-snowflake-white";
              };

              services = lib.mkOption {
                type = lib.types.attrsOf (lib.types.submodule {
                  options.command = lib.mkOption {
                    type = lib.types.str;
                    description = "Shell command to execute for this service";
                  };
                });
                default = {};
                description = "Services to group under this bundle";
              };
            };
          };

          # Build all bundles
          builtBundles = lib.mapAttrs (name: bundleCfg:
            let
              bundle = self.lib.mkServiceBundle pkgs {
                inherit (bundleCfg) bundleIdentifier bundleName icon services;
              };
              appName = builtins.replaceStrings [" "] ["-"] bundleCfg.bundleName;
            in {
              inherit bundle appName;
              path = "/Applications/Nix Apps/${appName}.app";
              registerBin = "/Applications/Nix Apps/${appName}.app/Contents/MacOS/register";
            }
          ) cfg.bundles;

          bundleNames = builtins.attrNames cfg.bundles;
        in
        {
          options.services.nix-darwin-smapp = {
            enable = lib.mkEnableOption "SMAppService wrapper with Nix icon in Login Items";

            bundles = lib.mkOption {
              type = lib.types.attrsOf bundleSubmodule;
              default = {};
              description = "App bundles to create. Each bundle groups related services under one icon in System Settings.";
            };
          };

          config = lib.mkMerge [
            # Always unregister — must run even when module is disabled
            {
              system.activationScripts.preActivation.text = ''
                # Unregister ALL existing smapp bundles in Nix Apps
                # Must run as console user — root cannot unregister user-scoped SMAppService agents
                consoleUser="$(/usr/bin/stat -f '%Su' /dev/console)"
                for app in "/Applications/Nix Apps/"*.app; do
                  reg="$app/Contents/MacOS/register"
                  if [ -x "$reg" ]; then
                    echo "smapp: unregistering $(basename "$app")..."
                    sudo -u "$consoleUser" "$reg" --unregister || true
                  fi
                done
              '';
            }

            (lib.mkIf cfg.enable {
            system.activationScripts.postActivation.text =
              let
                # List of expected bundle .app names
                expectedApps = lib.concatStringsSep " " (map (name:
                  let b = builtBundles.${name}; in
                  ''"${b.appName}.app"''
                ) bundleNames);

                installCommands = lib.concatStringsSep "\n" (map (name:
                  let b = builtBundles.${name}; in ''
                    echo "smapp: installing ${name}..."
                    rm -f "${b.path}"
                    ln -sf "${b.bundle}/${b.appName}.app" "${b.path}"
                  ''
                ) bundleNames);

                registerCommands = lib.concatStringsSep "\n" (map (name:
                  let b = builtBundles.${name}; in ''
                    sudo -u "$consoleUser" open -W "${b.path}"
                  ''
                ) bundleNames);
              in ''
                # Remove stale smapp bundles not in current config
                expected=(${expectedApps})
                for app in "/Applications/Nix Apps/"*.app; do
                  [ -e "$app" ] || continue
                  reg="$app/Contents/MacOS/register"
                  [ -x "$reg" ] || continue
                  name="$(basename "$app")"
                  found=0
                  for e in "''${expected[@]}"; do
                    [ "$name" = "$e" ] && found=1 && break
                  done
                  if [ "$found" = "0" ]; then
                    echo "smapp: removing stale $name..."
                    rm -f "$app"
                  fi
                done

                ${installCommands}

                echo "smapp: registering services..."
                consoleUser="$(/usr/bin/stat -f '%Su' /dev/console)"
                ${registerCommands}
              '';
            })
          ];
        };

      packages = forAllSystems (pkgs: {
        default = self.lib.mkServiceBundle pkgs {
          bundleIdentifier = "org.nixos.nix-darwin-services";
          bundleName = "nix-darwin";
          services = {
            "org.nixos.test-service" = {
              command = "exec /bin/sleep 86400";
            };
          };
        };
      });
    };
}
