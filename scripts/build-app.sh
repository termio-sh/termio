#!/usr/bin/env bash
# Assemble termio.app — a real macOS application bundle with a Dock icon and the
# embedded Sparkle.framework that powers in-app auto-update.
#
# termio is a plain SwiftPM executable; `swift run` produces a bare binary with
# no bundle, so macOS shows a generic Dock icon. This script builds the release
# binary and wraps it in a `.app` bundle whose Info.plist + AppIcon.icns give it
# a proper name and Dock icon, then embeds Sparkle (which SwiftPM links but does
# NOT bundle on its own) under Contents/Frameworks. It also builds the `termiod`
# session daemon (Rust + a Zig-built VT engine) into Contents/Resources, so a
# shipped app carries the session host it starts. The release bundle is universal
# (arm64 + x86_64) so one DMG runs on Apple silicon and Intel Macs alike.
#
# Requires: full Xcode (xcstringstool), and — for the daemon — Rust and Zig. A
# release build fails without them; a dev build says so and ships without one.
#
# Usage:
#   ./scripts/build-app.sh            # ad-hoc-signed release build into ./termio.app
#   open ./termio.app                 # launch it
#
# Environment overrides (used by the release workflow; all optional):
#   TERMIO_CHANNEL   which identity to build; only two values exist. Unset (or
#                    "release") builds ./termio.app. "dev" builds a side-by-side
#                    termio-dev.app (bundle id ….dev, its own ~/.termio-dev state +
#                    companion port 8788, Sparkle stripped) so it runs beside an
#                    installed release build. Any other value is rejected — see
#                    the channel check below for why.
#   TERMIO_VERSION   CFBundleShortVersionString to stamp (default: keep Info.plist's)
#   TERMIO_BUILD     CFBundleVersion to stamp; must increase across shipped builds
#                    because Sparkle compares it (default: keep Info.plist's)
#   SIGN_IDENTITY    codesign identity, e.g. "Developer ID Application: …" for a
#                    notarizable build (default: "-", ad-hoc, for local use)
#
# `AppIcon.png` is the shipped icon. `AppIcon-dev.png` is the inverted icon for
# local dev builds, so the two app bundles remain distinct in the Dock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

configuration="release"
# The SPM product / CFBundleExecutable name is always "termio"; only the bundle
# wrapper and identity change per channel.
product_name="termio"
# TERMIO_CHANNEL=dev builds a side-by-side dev app (termio-dev.app, id ….dev, its
# own state dir + port, Sparkle stripped) so it can run beside an installed release.
# Unset or "release" builds the shipped identity. Lower-cased the way AppChannel
# lower-cases it at runtime, so the two agree on what a channel name is.
channel="$(printf '%s' "${TERMIO_CHANNEL:-release}" | tr '[:upper:]' '[:lower:]')"
# Anything else must NOT fall through to the release branch below. Arbitrary
# channel names are a *runtime* feature — AppChannel.suffix turns any plain name
# into its own state dir, socket and companion port — but no bundle identity has
# ever been built for a third channel, so a typo (or session control's advice to
# take a channel of your own, read as build advice) used to hand back a bundle
# stamped sh.termio.app with a CLI stamped
# SUPPORT_DIR_NAME="termio": a build that silently drives the app you use daily,
# down to `sessions send` typing into a live session. Refuse instead.
if [[ "$channel" != "release" && "$channel" != "dev" ]]; then
    cat >&2 <<EOF
error: TERMIO_CHANNEL="${TERMIO_CHANNEL:-}" is not a channel this script can build.
       Supported values:
         unset (or "release")  ->  ./termio.app      (sh.termio.app,     CLI "termio")
         dev                   ->  ./termio-dev.app  (sh.termio.app.dev, CLI "termio-dev")
       A name of your own works when *running* termio (it picks a state directory,
       control socket and companion port), but there is no bundle to build for it —
       so this build would have taken the RELEASE identity and driven your daily app.
       Re-run with TERMIO_CHANNEL=dev, or leave TERMIO_CHANNEL unset for a release build.
EOF
    exit 1
fi
if [[ "$channel" == "dev" ]]; then
    app_name="termio-dev"
    source_icon="$repo_root/packaging/AppIcon-dev.png"
else
    app_name="termio"
    source_icon="$repo_root/packaging/AppIcon.png"
fi
app_dir="$repo_root/${app_name}.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
frameworks_dir="$contents_dir/Frameworks"
# Signing identity resolution:
#   - Explicit SIGN_IDENTITY always wins (the release runbook sets it).
#   - Otherwise a dev build tries to auto-pick a real identity from the keychain,
#     because local notifications (UNUserNotificationCenter) are rejected outright
#     for an ad-hoc-signed app — dev builds can only banner when properly signed.
#   - If no identity is present (e.g. a contributor without a signing cert), fall
#     back to ad-hoc so the build STILL succeeds — you just don't get notifications.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    sign_identity="$SIGN_IDENTITY"
elif [[ "$channel" == "dev" ]]; then
    # Prefer a Developer ID cert: it is self-sufficient for notification
    # authorization. An "Apple Development" cert needs a matching provisioning
    # profile or usernoted answers "Notifications are not allowed", so it is only
    # a last resort.
    ids="$(security find-identity -v -p codesigning 2>/dev/null)"
    sign_identity="$(printf '%s\n' "$ids" | grep -oE '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')"
    [[ -z "$sign_identity" ]] && sign_identity="$(printf '%s\n' "$ids" | grep -oE '"Apple Development:[^"]*"' | head -1 | tr -d '"')"
    sign_identity="${sign_identity:--}"
    [[ "$sign_identity" == "-" ]] \
        && echo "==> No signing identity found — ad-hoc (notifications will not work in this dev build)"
else
    sign_identity="-"
fi

# Regenerate the compiled .lproj resources from the String Catalog so a shipped
# build can never carry strings that lag an edited Localizable.xcstrings.
echo "==> Compiling localized strings"
"$repo_root/scripts/compile-strings.sh"

# Build one slice per Mac architecture, then lipo them together, so the shipped app
# runs on Apple silicon and Intel from one bundle. SwiftPM's own multi-arch mode
# (`swift build --arch arm64 --arch x86_64`) is NOT usable here: it routes the build
# through the Xcode build system, whose eager-linking step links libghostty's static
# xcframework with `-lghostty` but no matching `-L`, so it fails with "library not
# found for -lghostty". One `--arch` at a time keeps the normal build system, which
# resolves the xcframework correctly.
#
# Each slice lands in its own `.build/<arch>-apple-macosx/<config>` directory. Only
# the executable differs between them — Sparkle.framework already ships universal
# from its xcframework, and the SwiftPM resource bundles are arch-independent — so
# everything else is copied out of the first slice's directory.
#
# A dev build only ever runs on the machine that produced it, so it builds the host
# slice alone and keeps the rebuild loop at one compile.
architectures=(arm64 x86_64)
[[ "$channel" == "dev" ]] && architectures=("$(uname -m)")
slice_binaries=()
for arch in "${architectures[@]}"; do
    echo "==> Building $app_name ($configuration, $arch)"
    swift build -c "$configuration" --arch "$arch"

    slice_bin_path="$(swift build -c "$configuration" --arch "$arch" --show-bin-path)"
    slice_binary="$slice_bin_path/$product_name"
    if [[ ! -x "$slice_binary" ]]; then
        echo "error: built $arch binary not found at $slice_binary" >&2
        exit 1
    fi
    slice_binaries+=("$slice_binary")
    [[ -n "${bin_path:-}" ]] || bin_path="$slice_bin_path"
done

sparkle_src="$bin_path/Sparkle.framework"
if [[ ! -d "$sparkle_src" ]]; then
    echo "error: Sparkle.framework not found at $sparkle_src — did the SPM build run?" >&2
    exit 1
fi

echo "==> Assembling bundle at $app_dir"
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"
lipo -create "${slice_binaries[@]}" -output "$macos_dir/$product_name"
chmod +x "$macos_dir/$product_name"
cp "$repo_root/packaging/Info.plist" "$contents_dir/Info.plist"

# Fail loudly rather than shipping a DMG that Intel Macs refuse to open: a build
# that silently drops a slice is invisible until a user on the other arch tries it.
bundled_archs="$(lipo -archs "$macos_dir/$product_name")"
for required_arch in "${architectures[@]}"; do
    if [[ " $bundled_archs " != *" $required_arch "* ]]; then
        echo "error: bundled binary is missing the $required_arch slice — has [$bundled_archs]" >&2
        exit 1
    fi
done
echo "==> Bundled binary architectures: $bundled_archs"

# Ship every SwiftPM resource bundle into the app's Resources. NOTE: this alone is
# NOT enough for a dependency that reads its own `Bundle.module` — `swift build`
# bakes that accessor with only the .app ROOT + a hardcoded build-machine path, so
# it never looks in Contents/Resources and a CI-built release crashes (the v0.2.4
# Highlightr editor crash; Highlightr is vendored now for exactly this reason).
# termio's own lookups go through `Bundle.termioResources`, which resolves here.
echo "==> Bundling SwiftPM resource bundles"
shopt -s nullglob
for resource_bundle in "$bin_path"/*.bundle; do
    cp -R "$resource_bundle" "$resources_dir/"
done
shopt -u nullglob

# Ship the command-line tool inside the bundle. The app installs it onto the user's
# PATH by symlinking to this copy, so it version-updates with the app. A dev build
# ships it as `termio-dev`, rebound to the dev socket + bundle id, so it drives the
# dev app without clobbering the release `termio`.
cli_name="termio"
[[ "$channel" == "dev" ]] && cli_name="termio-dev"
echo "==> Bundling $cli_name command-line tool"
cp "$repo_root/scripts/termio" "$resources_dir/$cli_name"
if [[ "$channel" == "dev" ]]; then
    /usr/bin/sed -i '' \
        -e 's/^SUPPORT_DIR_NAME="termio"/SUPPORT_DIR_NAME="termio-dev"/' \
        -e 's/^BUNDLE_ID="sh.termio.app"/BUNDLE_ID="sh.termio.app.dev"/' \
        "$resources_dir/$cli_name"
fi
if [[ -n "${TERMIO_VERSION:-}" ]]; then
    /usr/bin/sed -i '' -e "s/^VERSION=\"dev\"/VERSION=\"$TERMIO_VERSION\"/" \
        "$resources_dir/$cli_name"
fi
chmod +x "$resources_dir/$cli_name"

# Ship the session daemon inside the bundle, beside the CLI. `termiod` owns the
# PTY for every session the app opens through it, and the app resolves it out of
# Contents/Resources (`Termiod.daemonBinaryPath`). Nothing shipped it before:
# a released build looked for a debug artifact relative to its working directory,
# which for a Finder launch is "/", so it could never start a daemon at all.
#
# Built one slice per architecture and lipo'd exactly like the app binary — the
# release DMG is universal, and an arm64-only daemon inside it is a daemon an
# Intel Mac cannot execute. It keeps the name `termiod` on both channels: unlike
# the CLI it is never symlinked onto PATH, only executed by absolute path out of
# the bundle that ships it.
daemon_name="termiod"
daemon_dest="$resources_dir/$daemon_name"

# The VT engine is built by Zig from our libghostty fork, and `libghostty-vt-sys`
# invokes `zig` by name and honours no env override — so it has to be found on
# PATH. Homebrew leaves it unlinked whenever a second `zig@N` formula holds the
# link, so check its prefix before concluding it is absent.
zig_bin=""
if command -v zig >/dev/null 2>&1; then
    zig_bin="$(dirname "$(command -v zig)")"
else
    brew_zig="$(brew --prefix zig 2>/dev/null || true)"
    [[ -n "$brew_zig" && -x "$brew_zig/bin/zig" ]] && zig_bin="$brew_zig/bin"
fi

daemon_toolchain_missing=""
command -v cargo >/dev/null 2>&1 || daemon_toolchain_missing="cargo"
[[ -n "$zig_bin" ]] || daemon_toolchain_missing="${daemon_toolchain_missing:+$daemon_toolchain_missing and }zig"

if [[ -n "$daemon_toolchain_missing" ]]; then
    # A release without a daemon is a release with no session backend, so it
    # fails. A dev build degrades instead: TERMIO_TERMIOD is opt-in, so a
    # contributor with no Rust/Zig toolchain still gets a working app.
    if [[ "$channel" != "dev" ]]; then
        echo "error: cannot build termiod — $daemon_toolchain_missing not found." >&2
        echo "       Rust: https://rustup.rs — Zig: brew install zig (termiod/README.md)." >&2
        exit 1
    fi
    echo "==> Skipping termiod: $daemon_toolchain_missing not found — this dev build cannot start a daemon"
else
    # Xcode 26's libSystem.tbd advertises arm64e only and Zig cannot link against
    # it (the build dies in a wall of "undefined symbol: _malloc"); the Command
    # Line Tools SDK is the fix, same as .github/workflows/termiod.yml. Scoped to
    # the cargo build alone — the Swift build above needs full Xcode, whose
    # xcstringstool compiles the String Catalog.
    daemon_developer_dir="${DEVELOPER_DIR:-}"
    if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
        daemon_developer_dir=/Library/Developer/CommandLineTools
    fi

    daemon_slices=()
    for arch in "${architectures[@]}"; do
        # Rust spells Apple silicon `aarch64`; lipo and uname spell it `arm64`.
        rust_target="$arch-apple-darwin"
        [[ "$arch" == "arm64" ]] && rust_target="aarch64-apple-darwin"
        echo "==> Building $daemon_name ($rust_target)"
        (
            cd "$repo_root/termiod"
            export PATH="$zig_bin:$PATH"
            [[ -n "$daemon_developer_dir" ]] && export DEVELOPER_DIR="$daemon_developer_dir"
            # The cross slice's std is not installed by default on a fresh
            # machine or a CI runner; a non-rustup cargo just skips this.
            rustup target add "$rust_target" >/dev/null 2>&1 || true
            cargo build --release --target "$rust_target"
        )
        daemon_slices+=("$repo_root/termiod/target/$rust_target/release/$daemon_name")
    done

    lipo -create "${daemon_slices[@]}" -output "$daemon_dest"
    chmod +x "$daemon_dest"
    daemon_archs="$(lipo -archs "$daemon_dest")"
    for required_arch in "${architectures[@]}"; do
        if [[ " $daemon_archs " != *" $required_arch "* ]]; then
            echo "error: bundled $daemon_name is missing the $required_arch slice — has [$daemon_archs]" >&2
            exit 1
        fi
    done
    echo "==> Bundled $daemon_name architectures: $daemon_archs"
fi

# Stamp version / build number when the release workflow supplies them. The
# binary's rpath already resolves @rpath/Sparkle.framework via @executable_path
# below, so embedding is purely a copy + one rpath entry.
plist="$contents_dir/Info.plist"
if [[ -n "${TERMIO_VERSION:-}" ]]; then
    echo "==> Stamping CFBundleShortVersionString=$TERMIO_VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TERMIO_VERSION" "$plist"
fi
if [[ -n "${TERMIO_BUILD:-}" ]]; then
    echo "==> Stamping CFBundleVersion=$TERMIO_BUILD"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TERMIO_BUILD" "$plist"
fi

# Dev channel: suffix the bundle id (so LaunchServices, UserDefaults, and
# AppChannel's paths/port all diverge from the release build), rename it, and strip
# Sparkle so the dev app can never auto-update itself onto the release channel.
if [[ "$channel" == "dev" ]]; then
    base_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    echo "==> Dev channel: bundle id ${base_id}.dev, Sparkle stripped"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${base_id}.dev" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName termio dev" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName termio dev" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 termio-dev" "$plist"
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist" 2>/dev/null || true
fi

echo "==> Embedding Sparkle.framework"
cp -R "$sparkle_src" "$frameworks_dir/"
# SwiftPM links @rpath/Sparkle.framework with only an @loader_path rpath, which
# would look beside the binary. Point @rpath at Contents/Frameworks so the
# embedded copy is found at runtime. (Harmless if the entry already exists.)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$macos_dir/$product_name" 2>/dev/null || true

if [[ -f "$source_icon" ]]; then
    echo "==> Generating AppIcon.icns from ${source_icon#$repo_root/}"
    iconset_dir="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset_dir"
    # macOS expects these exact names/sizes inside the .iconset directory.
    for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
                "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
                "512:512x512" "1024:512x512@2x"; do
        px="${spec%%:*}"
        label="${spec##*:}"
        sips -z "$px" "$px" "$source_icon" --out "$iconset_dir/icon_${label}.png" >/dev/null
    done
    iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"
    rm -rf "$(dirname "$iconset_dir")"
else
    echo "==> No icon found at ${source_icon#$repo_root/} — building without a Dock icon."
fi

# Sign inside-out. A Developer ID identity (with the hardened runtime) makes the
# bundle notarizable; the default "-" ad-hoc identity is enough for local runs.
# Either way Sparkle's nested helpers must be sealed before the framework, and
# the framework before the outer app, or codesign rejects the bundle.
sign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_args+=(--options runtime)
    # A secure timestamp needs the network and only matters for notarized
    # distribution; skip it for local dev builds so a rebuild works offline/fast.
    [[ "$channel" == "dev" ]] || sign_args+=(--timestamp)
fi

echo "==> Signing with identity: $sign_identity"
sparkle="$frameworks_dir/Sparkle.framework"
sparkle_version="$(readlink "$sparkle/Versions/Current" || echo B)"
sparkle_v="$sparkle/Versions/$sparkle_version"
for component in \
    "$sparkle_v/XPCServices/Installer.xpc" \
    "$sparkle_v/XPCServices/Downloader.xpc" \
    "$sparkle_v/Autoupdate" \
    "$sparkle_v/Updater.app"; do
    [[ -e "$component" ]] && codesign "${sign_args[@]}" "$component"
done
codesign "${sign_args[@]}" "$sparkle"
# The daemon is a nested Mach-O like Sparkle's helpers, so it is sealed before the
# outer app for the same reason — and with the same hardened runtime, because
# notarization rejects any executable inside the bundle that lacks it.
[[ -e "$daemon_dest" ]] && codesign "${sign_args[@]}" "$daemon_dest"
# Seal the outer app last so CodeResources covers the embedded framework. NOT
# --deep: the framework's components are already individually signed above.
codesign "${sign_args[@]}" "$app_dir"
# Not --deep here either: Apple deprecated it for verification, and it does not
# check nested code the way the name suggests. --strict is what does.
codesign --verify --strict --verbose=2 "$app_dir"

echo "==> Done: $app_dir"
echo "    Launch with:  open \"$app_dir\""
