#!/usr/bin/env bash
# Old Flutter plugins break modern Gradle/AGP in mechanical ways, and the
# offending code sits in pub caches rather than in the project, so it has to be
# repaired where it is unpacked. Two failures show up in practice:
#
#   jcenter()                      removed in Gradle 9; the whole build dies at
#                                  Gradle *evaluation*, before compiling
#   package="x" in the plugin's    rejected by AGP 8: "Setting the namespace via
#   android/src/main/             the package attribute in the source
#   AndroidManifest.xml           AndroidManifest.xml is no longer supported"
#
# Both the project's pub cache and flutter_patcher's private one are repaired:
# Gradle reads the plugin from whichever cache resolved it, and the patcher
# resolves into ~/.flutter_patcher/pub-cache with its own PUB_CACHE.
#
# Sourced by ota-patch.yml; not meant to be run on its own.

MODERNIZED_LIST="${MODERNIZED_LIST:-/tmp/modernized-plugins.txt}"

modernize_plugins() {
  local roots=("$PUB_CACHE/hosted" "$HOME/.flutter_patcher/pub-cache/hosted")
  local touched
  touched=$(mktemp)
  : > "$MODERNIZED_LIST"
  local n=0

  # jcenter() first: it kills Gradle before anything else can be evaluated.
  while IFS= read -r f; do
    sed -i 's/jcenter()/mavenCentral()/g' "$f"
    dirname "$(dirname "$f")" >> "$touched"
    n=$((n + 1))
  done < <(grep -rl --include=build.gradle "jcenter()" "${roots[@]}" 2>/dev/null)

  # Then the manifest package attribute, per plugin.
  while IFS= read -r pkgdir; do
    [ -n "$pkgdir" ] || continue
    local manifest="$pkgdir/android/src/main/AndroidManifest.xml"
    local gradle="$pkgdir/android/build.gradle"
    [ -f "$manifest" ] || continue
    local pkg
    pkg=$(sed -n 's/.*package="\([^"]*\)".*/\1/p' "$manifest" | head -1)
    [ -n "$pkg" ] || continue
    if [ -f "$gradle" ] && ! grep -q "namespace" "$gradle"; then
      # First `android {` block only: 0,/re/ is a range address, and the
      # substitution needs its own pattern (s//.../ would mean "previous regex").
      sed -i "0,/^android {/{s/^android {/android {\n    namespace \"$pkg\"/}" "$gradle"
      if ! grep -q "namespace" "$gradle"; then
        echo "  WARN: no 'android {' block in $gradle, namespace not added"
      fi
    fi
    sed -i 's/[[:space:]]package="[^"]*"//' "$manifest"
    echo "  manifest $pkg"
    n=$((n + 1))
  done < <(sort -u "$touched")

  rm -f "$touched"
  sort -u -o "$MODERNIZED_LIST" "$MODERNIZED_LIST" 2>/dev/null || true
  echo "  $n plugin file(s) modernized"
}

# True when patch validation rejected a native plugin because its sources
# differ from the host baseline. After patcher's first run has downloaded
# pristine copies, another modernize pass normally reconciles them.
patch_native_change() {
  grep -q "PATCH_NATIVE_CHANGE" "$1" 2>/dev/null
}

# Copy the already-repaired packages into the patcher's cache so its own
# `pub get` finds them instead of downloading pristine copies. Anything it
# still downloads is repaired on the next attempt.
seed_patcher_cache() {
  local target="$HOME/.flutter_patcher/pub-cache/hosted/pub.dev"
  mkdir -p "$target"
  local n=0
  while IFS= read -r pkgdir; do
    [ -n "$pkgdir" ] || continue
    case "$pkgdir" in
      "$PUB_CACHE"/hosted/*) ;;
      *) continue ;;
    esac
    local pkg
    pkg=$(basename "$pkgdir")
    cp -R "$pkgdir" "$target/" 2>/dev/null && n=$((n + 1))
  done < "$MODERNIZED_LIST"
  echo "  $n package(s) seeded into flutter_patcher's cache"
}

# True when the last build died on one of the old-plugin symptoms above.
old_plugin_failure() {
  grep -qE "jcenter\(\)|Setting the namespace via the package attribute|Incorrect package=" "$1" 2>/dev/null
}
