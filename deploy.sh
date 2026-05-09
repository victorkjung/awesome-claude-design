#!/usr/bin/env bash
# Deploy ./site to here.now using the 3-step publish API.
#
# Usage:
#   HERENOW_API_KEY=hn_xxx ./deploy.sh           # publishes to vkj.here.now
#   HERENOW_API_KEY=hn_xxx ./deploy.sh my-slug   # publishes to my-slug.here.now
#
# Flow: POST /api/v1/publish  ->  PUT presigned URLs  ->  POST /api/v1/publish/:slug/finalize
set -euo pipefail

SLUG="${1:-vkj}"
SITE_DIR="${SITE_DIR:-site}"
API="${HERENOW_API:-https://here.now/api/v1}"

if [[ -z "${HERENOW_API_KEY:-}" ]]; then
  echo "error: set HERENOW_API_KEY (anonymous sites expire in 24h)." >&2
  exit 1
fi
if [[ ! -d "$SITE_DIR" ]]; then
  echo "error: $SITE_DIR not found" >&2
  exit 1
fi
if [[ ! -f "$SITE_DIR/index.html" ]]; then
  echo "error: $SITE_DIR/index.html missing (must be at the site root)" >&2
  exit 1
fi
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "error: '$bin' required" >&2; exit 1; }
done

guess_type() {
  case "${1,,}" in
    *.html|*.htm) echo "text/html; charset=utf-8" ;;
    *.css)        echo "text/css; charset=utf-8" ;;
    *.js|*.mjs)   echo "application/javascript; charset=utf-8" ;;
    *.json)       echo "application/json" ;;
    *.svg)        echo "image/svg+xml" ;;
    *.png)        echo "image/png" ;;
    *.jpg|*.jpeg) echo "image/jpeg" ;;
    *.webp)       echo "image/webp" ;;
    *.gif)        echo "image/gif" ;;
    *.ico)        echo "image/x-icon" ;;
    *.woff2)      echo "font/woff2" ;;
    *.woff)       echo "font/woff" ;;
    *.txt|*.md)   echo "text/plain; charset=utf-8" ;;
    *)            echo "application/octet-stream" ;;
  esac
}

# 1. Build manifest of every file under SITE_DIR.
manifest='[]'
while IFS= read -r -d '' f; do
  rel="${f#$SITE_DIR/}"
  size=$(wc -c < "$f" | tr -d ' ')
  ctype=$(guess_type "$rel")
  manifest=$(jq --arg p "$rel" --argjson s "$size" --arg c "$ctype" \
    '. + [{path:$p, size:$s, contentType:$c}]' <<<"$manifest")
done < <(find "$SITE_DIR" -type f -print0)

count=$(jq 'length' <<<"$manifest")
echo "→ publishing $count file(s) from $SITE_DIR/ to ${SLUG}.here.now"

# 2. Create / update site, get presigned upload URLs.
create_resp=$(curl -fsS -X POST "$API/publish" \
  -H "Authorization: Bearer $HERENOW_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg slug "$SLUG" --argjson files "$manifest" '{slug:$slug, files:$files}')")

# 3. PUT each file to its presigned URL (in parallel).
echo "→ uploading…"
jq -r '.files[] | "\(.path)\t\(.uploadUrl)"' <<<"$create_resp" \
| while IFS=$'\t' read -r path url; do
    ctype=$(guess_type "$path")
    (
      curl -fsS -X PUT "$url" \
        -H "Content-Type: $ctype" \
        --data-binary "@$SITE_DIR/$path" \
      && echo "  ✓ $path"
    ) &
  done
wait

# 4. Finalize -> live site.
final=$(curl -fsS -X POST "$API/publish/$SLUG/finalize" \
  -H "Authorization: Bearer $HERENOW_API_KEY")

url=$(jq -r '.url // "https://'"$SLUG"'.here.now"' <<<"$final")
echo "✅ live: $url"
