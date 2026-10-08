#!/usr/bin/env bash
set -euo pipefail

log() {
    printf '[AURA-BUILD] %s\n' "$*"
}

fail() {
    printf '[AURA-BUILD][ERROR] %s\n' "$*" >&2
    exit 1
}

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
android_dir="$project_root/android"
local_properties="$android_dir/local.properties"

property_value() {
    local key="$1"
    local file="$2"
    if [[ -f "$file" ]]; then
        awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value = $0} END {print value}' "$file"
    fi
}

flutter_root="${FLUTTER_ROOT:-}"
if [[ -z "$flutter_root" || ! -x "$flutter_root/bin/flutter" ]]; then
    flutter_root="$(property_value flutter.sdk "$local_properties")"
fi
if [[ -z "$flutter_root" || ! -x "$flutter_root/bin/flutter" ]]; then
    flutter_binary="$(command -v flutter || true)"
    if [[ -n "$flutter_binary" ]]; then
        flutter_root="$(cd "$(dirname "$flutter_binary")/.." && pwd -P)"
    fi
fi
if [[ -z "$flutter_root" || ! -x "$flutter_root/bin/flutter" ]]; then
    for candidate in \
        "$HOME/development/flutter" \
        "$HOME/.flutter_sdk/flutter" \
        /opt/flutter \
        /usr/local/flutter
    do
        if [[ -x "$candidate/bin/flutter" ]]; then
            flutter_root="$candidate"
            break
        fi
    done
fi
[[ -n "$flutter_root" && -x "$flutter_root/bin/flutter" ]] ||
    fail "Flutter SDK not found. Set FLUTTER_ROOT to an installed stable Flutter SDK."
export FLUTTER_ROOT="$(cd "$flutter_root" && pwd -P)"
export PATH="$FLUTTER_ROOT/bin:$PATH"

if [[ -z "${AURA_PUBLIC_KEY_ENV:-}" ]]; then
    AURA_PUBLIC_KEY_ENV='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAi9+ZvYGgwGWKyG+1CfBsF0Qb9iUCqg454HU011guOGZPxcQNpAtVheZ+Ek3UrlQwYOrWbdCeqr7v1OwkomfmEsdSq9qEBsPGlpdA4PXdeC18aVs/jGMKXQIVBWkXRUCWSGczCrKLzNqujCbYp+/7XSOgcjaLZocLv2G0PZUPDVEwqNmSRD4nYAeF6kyLn/4Syi6nEcUMLCFz8jzpWagCYvrJROfjQeD3DFHpRKLrP9TJQD+nQ7uL9kUakz0aO5rJ2fTD/Sr4XX/pT9tgshCN9VZUxPHy1OqPD/Dkckfh91XKDm5wPbJiDuIqgT7zOxZ9nxqP8u/tEGn/slEp9LnoNwIDAQAB'
    public_key_source="build-only fallback"
    log "WARNING: AURA_PUBLIC_KEY_ENV is empty; using the build-only fallback key. Signed model updates will fail closed. Configure production_keys for a production release."
else
    public_key_source="production"
fi
[[ "$AURA_PUBLIC_KEY_ENV" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
    fail "AURA_PUBLIC_KEY_ENV must be the Base64 DER body without PEM delimiters or whitespace."

key_file="$(mktemp "${TMPDIR:-/tmp}/aura-public-key.XXXXXX")"
trap 'rm -f "$key_file"' EXIT
python3 - "$AURA_PUBLIC_KEY_ENV" "$key_file" <<'PY'
import base64
import sys

try:
    der = base64.b64decode(sys.argv[1], validate=True)
except (ValueError, base64.binascii.Error) as error:
    raise SystemExit(f"AURA_PUBLIC_KEY_ENV is not valid Base64: {error}")
if not der:
    raise SystemExit("AURA_PUBLIC_KEY_ENV decoded to an empty public key.")
with open(sys.argv[2], "wb") as key_file:
    key_file.write(der)
PY
openssl pkey -pubin -inform DER -in "$key_file" -noout
rm -f "$key_file"
trap - EXIT

log "Selecting JDK 17 and mapping the installed Android SDK/NDK."
source "$project_root/tool/setup_env_fix.sh"
[[ -x "$JAVA_HOME/bin/java" ]] ||
    fail "The JDK 17 setup did not provide JAVA_HOME/bin/java."

java_version="$("$JAVA_HOME/bin/java" -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')"
[[ "$java_version" == 17.* ]] ||
    fail "Expected Java 17 at JAVA_HOME, found '${java_version:-unknown}'."
export PATH="$JAVA_HOME/bin:$PATH"
export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.java.home=$JAVA_HOME"
log "Gradle Java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1)"

gradle_version_output="$(
    cd "$android_dir"
    ./gradlew --version
)"
gradle_java_major="$(
    printf '%s\n' "$gradle_version_output" |
        awk '/^(Launcher )?JVM:/ {version = $NF; sub(/\..*/, "", version); print version; exit}'
)"
[[ "$gradle_java_major" == "17" ]] ||
    fail "Gradle reports Java ${gradle_java_major:-unknown}; Java 17 is required."

properties_tmp="$(mktemp "$local_properties.XXXXXX")"
trap 'rm -f "$properties_tmp"' EXIT
if [[ -f "$local_properties" ]]; then
    awk -F= '$1 != "flutter.sdk" {print}' "$local_properties" > "$properties_tmp"
fi
printf 'flutter.sdk=%s\n' "$FLUTTER_ROOT" >> "$properties_tmp"
mv "$properties_tmp" "$local_properties"
trap - EXIT

if [[ -n "${CM_ENV:-}" ]]; then
    printf 'FLUTTER_ROOT=%s\n' "$FLUTTER_ROOT" >> "$CM_ENV"
fi

cd "$project_root"
log "Building the release APK with the ${public_key_source} RSA public key."
"$FLUTTER_ROOT/bin/flutter" build apk --release \
    --dart-define="AURA_PUBLIC_KEY=$AURA_PUBLIC_KEY_ENV"
log "Release APK built at build/app/outputs/flutter-apk/app-release.apk."
