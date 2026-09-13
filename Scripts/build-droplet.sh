#!/bin/bash
#
# build-droplet.sh — build a .droplet bundle from a droplet package.
#
# Run from your droplet's package root:
#
#     path/to/DroppyKit/Scripts/build-droplet.sh [--arch arm64|x86_64|universal] [--build-system native|swiftbuild]
#
# WHY THIS SCRIPT EXISTS, AND WHY `swift build` IS NOT ENOUGH
#
# A shipped droplet must contain its own code and NOT a copy of DroppyKit. The
# app already has DroppyKit as a resilient framework; a droplet carrying a second
# copy gives every shared type two metadata records, and the cast the loader
# makes between the app's `Droplet` and the droplet's fails with no useful
# diagnostic. `swift build` produces exactly that second copy, because a plain
# SwiftPM link folds the dependency in statically.
#
# Declaring the SDK product `.dynamic` is the obvious fix and does not work.
# SwiftPM refuses a dynamic product whose name matches a target another product
# also links — which the harness does — and renaming the product hits a build
# system bug that emits `libDroppyKit.dylib` while linking
# `libDroppyKit<NewName>.dylib`. Either way `droppykit run` stops building.
#
# So this script does the link itself. It builds DroppyKit resiliently, wraps it
# in a framework whose install name is the one the app ships, compiles the
# droplet's target, and links that target's object file against the framework.
# The result carries an undefined reference the host resolves at load.
#
# It also compiles with `-enable-library-evolution`. Without it a droplet emits
# direct-access imports the resilient framework does not export — static-let
# unsafe addressors, mangled `…9DroppyKit…vau` — and the bundle passes every
# structural gate, loads in the harness, and dies inside the app at dyld with
# "Symbol not found". `validate-droplet.sh` refuses both wrong shapes.
#
# SUMS: this is a copy of the SDK's Scripts/build-droplet.sh, changed only
# where marked `SUMS:`, so the bundle links and carries SoulverCore. Run it
# instead of `droppykit build` (and instead of the `droppykit_build` MCP tool).
# The SDK checkout is found through `droppykit` on the PATH, or DROPPYKIT_ROOT.
#
set -euo pipefail

KIT_ROOT="${DROPPYKIT_ROOT:-$(cd "$(dirname "$(command -v droppykit)")/.." && pwd)}"
PACKAGE_ROOT="$(pwd)"
ARCHS="universal"
# Which SwiftPM engine builds the objects. Unset, the toolchain's default is
# used, which is what a developer wants; set it (or DROPPYKIT_BUILD_SYSTEM) to
# pin one when a toolchain's default misbehaves, or to reproduce a report from
# a machine on the other engine.
BUILD_SYSTEM="${DROPPYKIT_BUILD_SYSTEM:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch) ARCHS="$2"; shift 2 ;;
        --build-system) BUILD_SYSTEM="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$BUILD_SYSTEM" in
    ""|native|swiftbuild) ;;
    *) echo "error: --build-system must be native or swiftbuild" >&2; exit 2 ;;
esac
# Passed to every swift build below. Bash 3.2 treats an empty array as unset
# under set -u, hence the guarded expansion at each use.
BUILD_SYSTEM_ARGS=()
if [ -n "$BUILD_SYSTEM" ]; then
    BUILD_SYSTEM_ARGS=(--build-system "$BUILD_SYSTEM")
fi

# The compiled objects for one module, one path per line, whichever engine
# SwiftPM used.
#
# Two engines are current. Swift Build, the default from the Swift 6.4
# toolchain, writes one `<Module>.o` beside the products. The native engine,
# the default in Swift 6.2 and 6.3 and therefore on every shipping Xcode 26,
# writes one object per source file under `<Module>.build/` and no
# `<Module>.o` at all. 1.2.0 knew only the first shape and failed on the
# shipping toolchain with "DroppyKit.o not found"; the first developer to
# build a droplet away from this machine hit it within the hour.
collect_objects() {
    local bin="$1" module="$2"
    if [ -f "$bin/$module.o" ]; then
        printf '%s\n' "$bin/$module.o"
        return 0
    fi
    if [ -d "$bin/$module.build" ]; then
        find "$bin/$module.build" -type f -name '*.o' | LC_ALL=C sort
        return 0
    fi
    return 1
}

# Fills the named array with a module's objects, or exits naming what was
# looked for and where.
require_objects() {   # <array name> <bin dir> <module>
    local name="$1" bin="$2" module="$3" object count=0
    eval "$name=()"
    while IFS= read -r object; do
        [ -n "$object" ] || continue
        eval "$name+=(\"\$object\")"
        count=$((count + 1))
    done < <(collect_objects "$bin" "$module" || true)
    if [ "$count" -eq 0 ]; then
        echo "error: no compiled objects for $module at $bin" >&2
        echo "       Expected $module.o (Swift Build engine) or $module.build/*.o (native engine)." >&2
        echo "       Contents:" >&2
        ls "$bin" 2>/dev/null | sed 's/^/         /' >&2
        exit 1
    fi
}

MANIFEST="$PACKAGE_ROOT/droplet.json"
if [ ! -f "$MANIFEST" ]; then
    echo "error: no droplet.json in $PACKAGE_ROOT" >&2
    exit 1
fi

read_manifest() {
    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$MANIFEST" "$1"
}

DROPLET_ID="$(read_manifest id)"
DROPLET_NAME="$(read_manifest name)"
DROPLET_VERSION="$(read_manifest version)"
MIN_APP_VERSION="$(read_manifest minAppVersion)"
ICON_NAME="$(read_manifest icon)"

if [ -z "$DROPLET_ID" ]; then
    echo "error: droplet.json has no id" >&2
    exit 1
fi

# The product name is the target that builds the dynamic library. By convention
# it is the package name, which is what `droppykit new` writes.
PRODUCT="$(/usr/bin/python3 - "$PACKAGE_ROOT" <<'PY'
import re, sys, pathlib
text = (pathlib.Path(sys.argv[1]) / "Package.swift").read_text()
match = re.search(r'\.library\(\s*name:\s*"([^"]+)"\s*,\s*type:\s*\.dynamic', text)
print(match.group(1) if match else "")
PY
)"
if [ -z "$PRODUCT" ]; then
    echo "error: Package.swift declares no dynamic library product." >&2
    echo "       A droplet is a loadable bundle, so its product must be:" >&2
    echo "       .library(name: \"…\", type: .dynamic, targets: [\"…\"])" >&2
    exit 1
fi

case "$ARCHS" in
    universal) SLICES="arm64 x86_64" ;;
    arm64|x86_64) SLICES="$ARCHS" ;;
    *) echo "error: --arch must be arm64, x86_64 or universal" >&2; exit 2 ;;
esac

BUILD_ROOT="$PACKAGE_ROOT/.build/droplet"
BUNDLE="$PACKAGE_ROOT/.build/$PRODUCT.droplet"
rm -rf "$BUILD_ROOT" "$BUNDLE"
mkdir -p "$BUILD_ROOT"

# ── The framework to link against ─────────────────────────────────────────
#
# Built from DroppyKit's own sources, resiliently, and laid out the way the app
# ships it. Linking against this is what makes the droplet's load command name
# the framework rather than a dylib SwiftPM invented.
FRAMEWORK_DIR="$BUILD_ROOT/Frameworks"
mkdir -p "$FRAMEWORK_DIR"

echo "Building DroppyKit resiliently…"
# Per slice, because the framework the droplet links has to carry the same
# architectures the droplet does.
for slice in $SLICES; do
    (cd "$KIT_ROOT" && swift build \
        --target DroppyKit \
        --configuration release \
        --arch "$slice" \
        --scratch-path "$BUILD_ROOT/kit-$slice" \
        ${BUILD_SYSTEM_ARGS[@]+"${BUILD_SYSTEM_ARGS[@]}"} \
        -Xswiftc -enable-library-evolution \
        -Xswiftc -emit-module-interface \
        >/dev/null)
done

# ── Assemble DroppyKit.framework ──────────────────────────────────────────
#
# Built here rather than taken from SwiftPM, because SwiftPM will not produce
# it. A `.dynamic` product named after its target is refused outright when
# another product links that target, and renaming the product hits a build
# system bug that emits one filename and links another. Both break
# `droppykit run`.
#
# So the product stays `.automatic` and this script does the dynamic link
# itself, from the object file SwiftPM does emit. The result is what the
# droplet needs: a framework whose install name is the one Droppy ships, to
# link against and then resolve from the host at load.
FRAMEWORK="$FRAMEWORK_DIR/DroppyKit.framework"
mkdir -p "$FRAMEWORK/Versions/A/Modules"

KIT_SLICES=()
for slice in $SLICES; do
    KIT_BIN="$(cd "$KIT_ROOT" && swift build --configuration release --arch "$slice" \
        --scratch-path "$BUILD_ROOT/kit-$slice" ${BUILD_SYSTEM_ARGS[@]+"${BUILD_SYSTEM_ARGS[@]}"} --show-bin-path)"
    require_objects KIT_OBJECTS "$KIT_BIN" DroppyKit
    xcrun -sdk macosx swiftc \
        -emit-library \
        -target "$slice-apple-macosx14.0" \
        -module-name DroppyKit \
        -o "$BUILD_ROOT/DroppyKit-$slice.dylib" \
        -Xlinker -install_name -Xlinker "@rpath/DroppyKit.framework/Versions/A/DroppyKit" \
        "${KIT_OBJECTS[@]}"
    KIT_SLICES+=("$BUILD_ROOT/DroppyKit-$slice.dylib")
    # The interface is architecture-specific; the last one written wins, which
    # is fine because a droplet compiles against one slice at a time.
    cp -R "$KIT_BIN/Modules/DroppyKit.swiftmodule" "$FRAMEWORK/Versions/A/Modules/" 2>/dev/null \
        || cp -R "$KIT_BIN/DroppyKit.swiftmodule" "$FRAMEWORK/Versions/A/Modules/" 2>/dev/null \
        || true
done

if [ "${#KIT_SLICES[@]}" -gt 1 ]; then
    lipo -create "${KIT_SLICES[@]}" -output "$FRAMEWORK/Versions/A/DroppyKit"
else
    cp "${KIT_SLICES[0]}" "$FRAMEWORK/Versions/A/DroppyKit"
fi
ln -sfn A "$FRAMEWORK/Versions/Current"
ln -sfn Versions/Current/DroppyKit "$FRAMEWORK/DroppyKit"
ln -sfn Versions/Current/Modules "$FRAMEWORK/Modules"

# ── The droplet itself ────────────────────────────────────────────────────
echo "Building ${PRODUCT}…"
SLICE_BINARIES=()
for slice in $SLICES; do
    # Compile only. SwiftPM's own link step would statically fold DroppyKit
    # into the droplet, giving the app and the droplet two metadata records for
    # every shared type and failing every cast between them.
    swift build \
        --target "$PRODUCT" \
        --configuration release \
        --arch "$slice" \
        --scratch-path "$BUILD_ROOT/droplet-$slice" \
        ${BUILD_SYSTEM_ARGS[@]+"${BUILD_SYSTEM_ARGS[@]}"} \
        -Xswiftc -enable-library-evolution \
        >/dev/null

    DROPLET_BIN="$(swift build --configuration release --arch "$slice" \
        --scratch-path "$BUILD_ROOT/droplet-$slice" ${BUILD_SYSTEM_ARGS[@]+"${BUILD_SYSTEM_ARGS[@]}"} --show-bin-path)"
    require_objects DROPLET_OBJECTS "$DROPLET_BIN" "$PRODUCT"

    # SUMS: SoulverCore is a binary xcframework SwiftPM unpacked into this
    # slice's scratch path. Its macOS slice is universal, so either copy works.
    SOULVER_FRAMEWORK="$(find "$BUILD_ROOT/droplet-$slice" -type d -name SoulverCore.framework -path '*macos*' 2>/dev/null | head -1)"
    if [ -z "$SOULVER_FRAMEWORK" ]; then
        echo "error: SoulverCore.framework not found under $BUILD_ROOT/droplet-$slice" >&2
        exit 1
    fi

    # The link that matters: the droplet's own code, against the framework.
    # `-rpath` reaches the host app's Frameworks directory from
    #   …/Droplets/<id>/<Name>.droplet/Contents/MacOS/<Name>
    # SUMS: and `@loader_path/../Frameworks` reaches the SoulverCore this
    # bundle carries.
    xcrun -sdk macosx swiftc \
        -emit-library \
        -target "$slice-apple-macosx14.0" \
        -module-name "$PRODUCT" \
        -o "$BUILD_ROOT/lib$PRODUCT-$slice.dylib" \
        -F "$FRAMEWORK_DIR" \
        -framework DroppyKit \
        -F "$(dirname "$SOULVER_FRAMEWORK")" \
        -framework SoulverCore \
        -Xlinker -install_name -Xlinker "@rpath/$PRODUCT" \
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
        -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
        "${DROPLET_OBJECTS[@]}"

    SLICE_BINARIES+=("$BUILD_ROOT/lib$PRODUCT-$slice.dylib")
done

# ── Assemble the bundle ───────────────────────────────────────────────────
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

if [ "${#SLICE_BINARIES[@]}" -gt 1 ]; then
    lipo -create "${SLICE_BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/$PRODUCT"
else
    cp "${SLICE_BINARIES[0]}" "$BUNDLE/Contents/MacOS/$PRODUCT"
fi

# SUMS: carry SoulverCore inside the bundle. `ditto` keeps the framework's
# symlinks and Soulver's code signature intact.
mkdir -p "$BUNDLE/Contents/Frameworks"
ditto "$SOULVER_FRAMEWORK" "$BUNDLE/Contents/Frameworks/SoulverCore.framework"
# The Info.plist is generated from droplet.json, so the two can never disagree.
/usr/bin/python3 - "$MANIFEST" "$BUNDLE/Contents/Info.plist" "$PRODUCT" <<'PY'
import json, plistlib, sys

manifest = json.load(open(sys.argv[1]))
product = sys.argv[3]
kit = manifest.get("kit", {})

plist = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": product,
    "CFBundleIdentifier": "app.getdroppy.droplet." + manifest["id"],
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": manifest["name"],
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": manifest["version"],
    "CFBundleVersion": manifest["version"],
    "NSPrincipalClass": manifest.get("principalClass", product + "Principal"),
    "DroppyDropletID": manifest["id"],
    "DroppyKitABI": int(kit.get("abi", 1)),
    "DroppyKitMinAPI": kit.get("minAPI", "1.0.0"),
    "DroppyMinAppVersion": manifest["minAppVersion"],
    "DroppyPermissions": manifest.get("capabilities", []),
}
with open(sys.argv[2], "wb") as handle:
    plistlib.dump(plist, handle)
PY

# Artwork travels with the bundle: the Store draws the icon and the creator mark
# from here, not from the repository.
if [ -n "$ICON_NAME" ] && [ -d "$PACKAGE_ROOT/$ICON_NAME" ]; then
    cp -R "$PACKAGE_ROOT/$ICON_NAME" "$BUNDLE/Contents/Resources/"

    # ...and so does the COMPILED icon. `actool` is the same compiler Xcode
    # runs on an app's icon, and what it writes is the real macOS icon: the
    # squircle, the material, the specular edge, the shadow. Droppy draws that
    # when it is there, which is the only way a droplet's icon sits beside
    # Droppy's own without looking like a flat sticker. The document stays in
    # the bundle too: it is what a reviewer reads, and what an older Droppy
    # falls back to rendering itself.
    ICON_STEM="${ICON_NAME%.icon}"
    if xcrun --find actool >/dev/null 2>&1; then
        ICON_BUILD="$(mktemp -d)"
        if xcrun actool \
            --output-format human-readable-text \
            --app-icon "$ICON_STEM" \
            --output-partial-info-plist "$ICON_BUILD/icon.plist" \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --compile "$ICON_BUILD" \
            "$PACKAGE_ROOT/$ICON_NAME" >"$ICON_BUILD/actool.log" 2>&1
        then
            for artifact in "$ICON_BUILD/$ICON_STEM.icns" "$ICON_BUILD/Assets.car"; do
                [ -f "$artifact" ] && cp "$artifact" "$BUNDLE/Contents/Resources/"
            done
            # Names the compiled icon for anything that asks the system for the
            # bundle's icon rather than reading the file directly.
            /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_STEM" \
                "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
            /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_STEM" \
                "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
        else
            # Not fatal: the bundle still carries the document, and Droppy
            # renders that. Say so, because the icon will look flatter.
            echo "  note: actool could not compile $ICON_NAME; shipping the document only"
            sed -n '1,12p' "$ICON_BUILD/actool.log" | sed 's/^/    /'
        fi
        rm -rf "$ICON_BUILD"
    else
        echo "  note: no actool on this toolchain; shipping the icon document only"
    fi
fi
if [ -d "$PACKAGE_ROOT/Assets" ]; then
    cp -R "$PACKAGE_ROOT/Assets" "$BUNDLE/Contents/Resources/"
fi
cp "$MANIFEST" "$BUNDLE/Contents/Resources/droplet.json"

echo "Built $BUNDLE"
echo "  $DROPLET_NAME $DROPLET_VERSION, needs Droppy $MIN_APP_VERSION"
lipo -archs "$BUNDLE/Contents/MacOS/$PRODUCT" 2>/dev/null | sed 's/^/  slices: /'

# Linkage is asserted here rather than left to the submission, because the two
# failures this script exists to prevent are invisible until dyld hits them.
"$KIT_ROOT/Scripts/validate-droplet.sh" --bundle "$BUNDLE" --linkage-only
