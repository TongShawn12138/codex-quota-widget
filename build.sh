#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")" && pwd -P)
app_path=${1:-"$project_dir/build/用量额度.app"}
if [[ $# -gt 1 || $app_path != *.app ]]; then
    echo "Usage: $0 [output-path.app]" >&2
    exit 2
fi

mkdir -p -- "$(dirname "$app_path")"
output_dir=$(cd "$(dirname "$app_path")" && pwd -P)
app_name=$(basename "$app_path")
app_path="$output_dir/$app_name"

if [[ -e $app_path || -L $app_path ]]; then
    if [[ -L $app_path ]] || [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
        "$app_path/Contents/Info.plist" 2>/dev/null) != local.openai.usage ]]; then
        echo "Output path is already occupied: $app_path" >&2
        exit 1
    fi
fi

staging_dir=$(mktemp -d "$output_dir/.usage-build.XXXXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name"
widget_path="$staged_app/Contents/PlugIns/OpenAIUsageWidget.appex"
mkdir -p "$staged_app/Contents/MacOS" "$widget_path/Contents/MacOS"

source_dir="$project_dir/Sources"
bundle_dir="$project_dir/Bundle"
/usr/bin/plutil -lint -- "$bundle_dir/App-Info.plist" "$bundle_dir/Widget-Info.plist" "$bundle_dir/Widget.entitlements" >/dev/null
cp "$bundle_dir/App-Info.plist" "$staged_app/Contents/Info.plist"
cp "$bundle_dir/Widget-Info.plist" "$widget_path/Contents/Info.plist"
quota_cache="$HOME/Library/Application Support/Local OpenAI Usage/usage.json"
widget_entitlements="$staging_dir/Widget.entitlements"
cp "$bundle_dir/Widget.entitlements" "$widget_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only:0 string $quota_cache" "$widget_entitlements"
for bundle in "$staged_app" "$widget_path"; do
    /usr/bin/plutil -insert QuotaCachePath -string "$quota_cache" "$bundle/Contents/Info.plist"
done

sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
sdk_version=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
target="$(/usr/bin/uname -m)-apple-macosx26.0"
swift_options=(-sdk "$sdk_path" -target "$target" -parse-as-library -O -module-cache-path "$staging_dir/modules")
if /usr/bin/awk -F. '{ exit !($1 > 27 || ($1 == 27 && $2 >= 3)) }' <<< "$sdk_version"; then
    swift_options+=(-D QUOTA_LIVE_ACTIVITY)
    /usr/bin/plutil -insert NSSupportsLiveActivities -bool true "$staged_app/Contents/Info.plist"
elif [[ ${QUOTA_REQUIRE_LIVE_ACTIVITY:-0} == 1 ]]; then
    printf 'Native Live Activities require the macOS 27.3 SDK or later. Found %s.\n' "$sdk_version" >&2
    exit 1
fi

/usr/bin/xcrun swiftc "${swift_options[@]}" -module-name OpenAIUsage \
    "$source_dir/UsageApp.swift" "$source_dir/CodexClient.swift" "$source_dir/UsageStore.swift" \
    "$source_dir/QuotaActivityAttributes.swift" "$source_dir/QuotaActivityController.swift" \
    "$source_dir/QuotaWorkProgress.swift" \
    -o "$staged_app/Contents/MacOS/OpenAIUsage"

/usr/bin/xcrun swiftc "${swift_options[@]}" -application-extension -module-name OpenAIUsageWidget \
    -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -u -Xlinker _main \
    "$source_dir/UsageWidget.swift" "$source_dir/UsageStore.swift" \
    "$source_dir/QuotaActivityAttributes.swift" "$source_dir/QuotaLiveActivity.swift" \
    "$source_dir/QuotaWorkProgress.swift" \
    -o "$widget_path/Contents/MacOS/OpenAIUsageWidget"

/usr/bin/codesign --force --sign - --entitlements "$widget_entitlements" "$widget_path"
/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"

if [[ -d $app_path ]]; then
    mv -- "$app_path" "$staging_dir/previous.app"
fi
if ! mv -- "$staged_app" "$app_path"; then
    if [[ -d $staging_dir/previous.app ]]; then
        mv -- "$staging_dir/previous.app" "$app_path"
    fi
    exit 1
fi

printf '%s\n' "$app_path"
