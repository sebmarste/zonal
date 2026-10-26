#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
appicon_dir="$repo_dir/Zonal/Assets.xcassets/AppIcon.appiconset"
toolbar_dir="$repo_dir/Zonal/Assets.xcassets/ZonalToolbar.imageset"
render_dir="$(mktemp -d /private/tmp/zonal-icon-export.XXXXXX)"

cleanup() {
    rm -rf "$render_dir"
}
trap cleanup EXIT

mkdir -p "$appicon_dir" "$toolbar_dir"

geometry="$(sed -n '/MARK-BEGIN/,/MARK-END/{ /MARK-BEGIN/d; /MARK-END/d; p; }' "$script_dir/zonal-mark.svg")"
if [[ -z "$geometry" ]]; then
    print -u2 "No geometry found between MARK-BEGIN and MARK-END"
    exit 1
fi

render_template() {
    local template_path="$1"
    local output_path="$2"

    while IFS= read -r line; do
        if [[ "$line" == *"__ZONAL_MARK__"* ]]; then
            print -r -- "$geometry"
        else
            print -r -- "$line"
        fi
    done < "$template_path" > "$output_path"
}

rendered_appicon="$render_dir/zonal-app-icon.svg"
rendered_toolbar="$toolbar_dir/zonal-toolbar-template.svg"
render_template "$script_dir/zonal-app-icon.template.svg" "$rendered_appicon"
cp "$script_dir/zonal-toolbar.template.svg" "$rendered_toolbar"

/usr/bin/qlmanage -t -s 1024 -o "$render_dir" "$rendered_appicon" >/dev/null
source_png="$render_dir/zonal-app-icon.svg.png"

for entry in \
    "16 appicon-16.png" \
    "32 appicon-16@2x.png" \
    "32 appicon-32.png" \
    "64 appicon-32@2x.png" \
    "128 appicon-128.png" \
    "256 appicon-128@2x.png" \
    "256 appicon-256.png" \
    "512 appicon-256@2x.png" \
    "512 appicon-512.png" \
    "1024 appicon-512@2x.png"
do
    size="${entry%% *}"
    filename="${entry#* }"
    /usr/bin/sips -z "$size" "$size" "$source_png" --out "$appicon_dir/$filename" >/dev/null
done
