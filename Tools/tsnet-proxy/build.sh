#!/bin/sh
set -eu

# Xcode invokes this as a post-build script; its environment has a minimal
# PATH without Homebrew, so find `go` explicitly when the caller can't.
if ! command -v go >/dev/null 2>&1 && [ -x /opt/homebrew/bin/go ]; then
    PATH="/opt/homebrew/bin:$PATH"
    export PATH
fi

# Xcode invokes this as a post-build script. Build a universal helper when the
# Release configuration asks for both architectures; Debug normally provides a
# single CURRENT/ARCHS value. CGO is disabled so Go can cross-compile the two
# macOS userspace binaries on either Apple Silicon or Intel.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_DIR="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}"
OUT="$OUT_DIR/tsnet-proxy"
TMP="$OUT_DIR/.tsnet-proxy-$$"

mkdir -p "$OUT_DIR" "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

ARCH_LIST=${ARCHS:-${CURRENT_ARCH:-$(uname -m)}}
for arch in $ARCH_LIST; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "tsnet-proxy: unsupported architecture $arch" >&2; exit 1 ;;
    esac
    goarch="$arch"
    [ "$arch" = "x86_64" ] && goarch=amd64
    (
        cd "$ROOT/Tools/tsnet-proxy"
        GOOS=darwin GOARCH="$goarch" CGO_ENABLED=0 \
            go build -trimpath -ldflags="-s -w" -o "$TMP/tsnet-proxy-$arch" .
    )
done

set -- $ARCH_LIST
if [ "$#" -eq 1 ]; then
    cp "$TMP/tsnet-proxy-$1" "$OUT"
else
    /usr/bin/lipo -create $(for arch in $ARCH_LIST; do printf '%s ' "$TMP/tsnet-proxy-$arch"; done) -output "$OUT"
fi
chmod 755 "$OUT"
# When Xcode is doing a signed Release build, sign the nested executable
# before the app's own CodeSign phase seals the resource directory. Debug
# builds with CODE_SIGNING_ALLOWED=NO intentionally skip this step.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$OUT"
fi
echo "tsnet-proxy: embedded $(file "$OUT")"
