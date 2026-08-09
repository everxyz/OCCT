#!/usr/bin/env bash
# Creates the release for the current tag if absent, then uploads one asset to it.
#
# Uses the REST API directly rather than an action, because this repository's
# Actions policy allows only everxyz-owned actions. Requires GH_TOKEN,
# GITHUB_REPOSITORY and GITHUB_REF_NAME in the environment.
set -euo pipefail

asset="${1:?usage: upload-release-asset.sh <file>}"
[ -f "$asset" ] || { echo "No such file: $asset" >&2; exit 1; }

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"

PY=$(command -v python3 || command -v python)
api="https://api.github.com/repos/${GITHUB_REPOSITORY}"
auth=(-H "Authorization: Bearer ${GH_TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

jqp() { "$PY" -c "$1" 2>/dev/null || true; }

# --- find or create the release -------------------------------------------
release_id=$(curl -sS "${auth[@]}" "${api}/releases/tags/${GITHUB_REF_NAME}" \
  | jqp 'import json,sys
d=json.load(sys.stdin)
print(d.get("id","") if isinstance(d,dict) else "")')

if [ -z "$release_id" ]; then
  echo "Creating release ${GITHUB_REF_NAME}"
  # everxyz-dev-* tags are pre-releases; everxyz-release-* are full releases.
  case "$GITHUB_REF_NAME" in
    everxyz-dev-*) prerelease=true ;;
    *)             prerelease=false ;;
  esac

  release_id=$(curl -sS -X POST "${auth[@]}" "${api}/releases" \
    -d "{\"tag_name\":\"${GITHUB_REF_NAME}\",\"name\":\"${GITHUB_REF_NAME}\",\"prerelease\":${prerelease},\"generate_release_notes\":true}" \
    | jqp 'import json,sys
d=json.load(sys.stdin)
print(d.get("id","") if isinstance(d,dict) else "")')
fi

[ -n "$release_id" ] || { echo "Could not resolve a release id for ${GITHUB_REF_NAME}" >&2; exit 1; }

# --- replace any existing asset of the same name (makes re-runs idempotent) --
name=$(basename "$asset")
old_id=$(curl -sS "${auth[@]}" "${api}/releases/${release_id}/assets?per_page=100" \
  | NAME="$name" jqp 'import json,os,sys
for a in json.load(sys.stdin):
    if a.get("name") == os.environ["NAME"]:
        print(a["id"]); break')

if [ -n "$old_id" ]; then
  echo "Replacing existing asset ${name}"
  curl -fsS -X DELETE "${auth[@]}" "${api}/releases/assets/${old_id}" >/dev/null
fi

# --- upload ----------------------------------------------------------------
echo "Uploading ${name} ($(du -h "$asset" | cut -f1))"
curl -fsS -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Content-Type: application/gzip" \
  --data-binary @"$asset" \
  "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?name=${name}" \
  >/dev/null

echo "Uploaded ${name} to release ${GITHUB_REF_NAME}"
