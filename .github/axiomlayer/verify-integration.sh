#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
pins="$script_dir/pins.json"
candidate_sha=${1:-HEAD}
active_worktree=""

fail() {
  printf 'axiomlayer npm integration: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

expect_equal() {
  local label=$1
  local actual=$2
  local expected=$3
  [[ "$actual" == "$expected" ]] || fail "$label: expected $expected, got $actual"
}

download_verified() {
  local label=$1
  local url=$2
  local expected=$3
  local destination=$4
  curl --fail --silent --show-error --location --retry 3 --output "$destination" "$url"
  expect_equal "$label SHA-256" "$(sha256_file "$destination")" "$expected"
}

[[ -f "$pins" ]] || fail "missing $pins"
jq -e '
  .schema == "axiomlayer-npm-node-integration-v1" and
  (.npm.commit | test("^[0-9a-f]{40}$")) and
  (.node.commit | test("^[0-9a-f]{40}$")) and
  (.nixpkgs.commit | test("^[0-9a-f]{40}$")) and
  ([.node.assets[].sha256, .node.assets[].binarySha256, .node.assets[].npmTreeSha256][] |
    test("^[0-9a-f]{64}$"))
' "$pins" >/dev/null || fail "invalid pin schema"

while IFS= read -r action; do
  [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "action is not pinned to a full SHA: $action"
done < <(sed -En 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*/\1/p' \
  "$repo_root/.github/workflows/axiomlayer-integration.yml")

retired_gate='codex''_security_gate'
if rg --hidden -n -g '!.git/**' "$retired_gate" "$repo_root"; then
  fail "the retired security gate is present"
fi

if rg -n '(environment:|secrets\.|npm[[:space:]]+publish|id-token:[[:space:]]*write)' \
  "$script_dir/pins.json" \
  "$script_dir/npm-tree-digest.mjs" \
  "$script_dir/shell.nix" \
  "$repo_root/.github/workflows/axiomlayer-integration.yml"; then
  fail "integration lane contains a forbidden environment, secret, publisher, or retired gate"
fi

for guarded_workflow in backport.yml create-node-pr.yml release.yml release-integration.yml; do
  rg -q "github\.repository_owner == 'npm'" "$repo_root/.github/workflows/$guarded_workflow" ||
    fail "$guarded_workflow is not inert outside the npm organization"
done

case "$candidate_sha" in
  HEAD) candidate_sha=$(git -C "$repo_root" rev-parse HEAD) ;;
esac
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || fail "candidate must resolve to a full commit SHA"

tmp_parent=${TMPDIR:-/tmp}
work=$(mktemp -d "$tmp_parent/axiomlayer-npm-integration.XXXXXX")
cleanup() {
  if [[ -n "$active_worktree" ]]; then
    git -C "$repo_root" worktree remove --force "$active_worktree" >/dev/null 2>&1 || true
  fi
  chmod -R u+w "$work" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

download_verified \
  "nixpkgs source archive" \
  "$(jq -er '.nixpkgs.archiveUrl' "$pins")" \
  "$(jq -er '.nixpkgs.archiveSha256' "$pins")" \
  "$work/nixpkgs.tar.gz"

npm_commit=$(jq -er '.npm.commit' "$pins")
npm_tag=$(jq -er '.npm.tag' "$pins")
npm_version=$(jq -er '.npm.version' "$pins")
node_commit=$(jq -er '.node.commit' "$pins")
node_version=$(jq -er '.node.version' "$pins")
node_base_url=$(jq -er '.node.distributionBaseUrl' "$pins")

git -C "$repo_root" cat-file -e "$npm_commit^{commit}" || fail "pinned npm commit is absent from the fork"
git -C "$repo_root" cat-file -e "$candidate_sha^{commit}" || fail "candidate npm commit is absent from the fork"
expect_equal "npm tag" "$(git -C "$repo_root" rev-parse "$npm_tag^{commit}")" "$npm_commit"

download_verified \
  "pinned npm source archive" \
  "$(jq -er '.npm.sourceArchive.url' "$pins")" \
  "$(jq -er '.npm.sourceArchive.sha256' "$pins")" \
  "$work/npm-source.tar.gz"
download_verified \
  "pinned npm package.json" \
  "$(jq -er '.npm.packageJson.url' "$pins")" \
  "$(jq -er '.npm.packageJson.sha256' "$pins")" \
  "$work/npm-package.json"
expect_equal "pinned npm package version" "$(jq -er '.version' "$work/npm-package.json")" "$npm_version"

download_verified \
  "pinned Node version header" \
  "$(jq -er '.node.versionHeader.url' "$pins")" \
  "$(jq -er '.node.versionHeader.sha256' "$pins")" \
  "$work/node-version.h"
rg -q '^#define NODE_MAJOR_VERSION 24$' "$work/node-version.h" || fail "Node major version evidence mismatch"
rg -q '^#define NODE_MINOR_VERSION 21$' "$work/node-version.h" || fail "Node minor version evidence mismatch"
rg -q '^#define NODE_PATCH_VERSION 0$' "$work/node-version.h" || fail "Node patch version evidence mismatch"

download_verified \
  "Node-bundled npm package.json" \
  "$(jq -er '.node.bundledNpmPackageJson.url' "$pins")" \
  "$(jq -er '.node.bundledNpmPackageJson.sha256' "$pins")" \
  "$work/node-npm-package.json"
expect_equal "Node-bundled npm version" "$(jq -er '.version' "$work/node-npm-package.json")" "$npm_version"
cmp "$work/npm-package.json" "$work/node-npm-package.json" >/dev/null ||
  fail "npm source and Node-bundled package identities differ"

shasums_file=$(jq -er '.node.shasums.file' "$pins")
download_verified \
  "Node release checksum manifest" \
  "$node_base_url/$shasums_file" \
  "$(jq -er '.node.shasums.sha256' "$pins")" \
  "$work/$shasums_file"

while IFS=$'\t' read -r platform filename expected; do
  actual=$(awk -v filename="$filename" '$2 == filename { print $1 }' "$work/$shasums_file")
  [[ -n "$actual" ]] || fail "$platform is absent from $shasums_file"
  expect_equal "$platform release manifest" "$actual" "$expected"
done < <(jq -r '.node.assets | to_entries[] | [.key, .value.file, .value.sha256] | @tsv' "$pins")

case "$(uname -s):$(uname -m)" in
  Darwin:arm64) runtime_platform=darwin-aarch64 ;;
  Darwin:x86_64) runtime_platform=darwin-x86_64 ;;
  Linux:aarch64 | Linux:arm64) runtime_platform=linux-aarch64 ;;
  Linux:x86_64) runtime_platform=linux-x86_64 ;;
  *) fail "unsupported build host $(uname -s)/$(uname -m)" ;;
esac

runtime_file=$(jq -er --arg platform "$runtime_platform" '.node.assets[$platform].file' "$pins")
runtime_archive="$work/$runtime_file"
download_verified \
  "$runtime_platform Node archive" \
  "$node_base_url/$runtime_file" \
  "$(jq -er --arg platform "$runtime_platform" '.node.assets[$platform].sha256' "$pins")" \
  "$runtime_archive"
mkdir "$work/node"
tar -xzf "$runtime_archive" -C "$work/node" --strip-components=1

node_bin="$work/node/bin/node"
npm_cli="$work/node/lib/node_modules/npm/bin/npm-cli.js"
expect_equal \
  "$runtime_platform Node binary" \
  "$(sha256_file "$node_bin")" \
  "$(jq -er --arg platform "$runtime_platform" '.node.assets[$platform].binarySha256' "$pins")"
expect_equal "Node runtime version" "$($node_bin --version)" "v$node_version"
expect_equal "bundled npm runtime version" "$($node_bin "$npm_cli" --version)" "$npm_version"
expect_equal \
  "$runtime_platform npm tree" \
  "$($node_bin "$script_dir/npm-tree-digest.mjs" "$work/node/lib/node_modules/npm")" \
  "$(jq -er --arg platform "$runtime_platform" '.node.assets[$platform].npmTreeSha256' "$pins")"

windows_platform=windows-x86_64
windows_file=$(jq -er --arg platform "$windows_platform" '.node.assets[$platform].file' "$pins")
download_verified \
  "$windows_platform Node archive" \
  "$node_base_url/$windows_file" \
  "$(jq -er --arg platform "$windows_platform" '.node.assets[$platform].sha256' "$pins")" \
  "$work/$windows_file"
mkdir "$work/windows"
unzip -q "$work/$windows_file" -d "$work/windows"
windows_root="$work/windows/${windows_file%.zip}"
expect_equal \
  "$windows_platform Node binary" \
  "$(sha256_file "$windows_root/node.exe")" \
  "$(jq -er --arg platform "$windows_platform" '.node.assets[$platform].binarySha256' "$pins")"
expect_equal "Windows-bundled npm version" "$(jq -er '.version' "$windows_root/node_modules/npm/package.json")" "$npm_version"
expect_equal \
  "$windows_platform npm tree" \
  "$($node_bin "$script_dir/npm-tree-digest.mjs" "$windows_root/node_modules/npm")" \
  "$(jq -er --arg platform "$windows_platform" '.node.assets[$platform].npmTreeSha256' "$pins")"

empty_user_config="$work/empty-user-npmrc"
empty_global_config="$work/empty-global-npmrc"
: > "$empty_user_config"
: > "$empty_global_config"
export PATH="$work/node/bin:$PATH"
export CI=true
export NO_UPDATE_NOTIFIER=1

verify_source() {
  local label=$1
  local commit=$2
  local expected_version=$3
  local source_dir="$work/source-$label"
  local cache_dir="$work/cache-$label"
  local pack_dir="$work/pack-$label"

  git -C "$repo_root" worktree add --detach --quiet "$source_dir" "$commit"
  active_worktree="$source_dir"
  expect_equal "$label package version" "$(jq -er '.version' "$source_dir/package.json")" "$expected_version"

  mkdir "$cache_dir" "$pack_dir"
  (
    cd "$source_dir"
    env -u NODE_AUTH_TOKEN -u NPM_TOKEN \
      NPM_CONFIG_USERCONFIG="$empty_user_config" \
      NPM_CONFIG_GLOBALCONFIG="$empty_global_config" \
      npm_config_cache="$cache_dir" \
      npm_config_audit=false \
      npm_config_fund=false \
      npm_config_update_notifier=false \
      "$node_bin" "$npm_cli" ci --ignore-scripts --no-audit --no-fund
    expect_equal "$label executable version" "$($node_bin . --version)" "$expected_version"
    env -u NODE_AUTH_TOKEN -u NPM_TOKEN \
      "$node_bin" . test --ignore-scripts
    env -u NODE_AUTH_TOKEN -u NPM_TOKEN \
      NPM_CONFIG_USERCONFIG="$empty_user_config" \
      NPM_CONFIG_GLOBALCONFIG="$empty_global_config" \
      npm_config_cache="$cache_dir" \
      npm_config_audit=false \
      npm_config_fund=false \
      npm_config_update_notifier=false \
      "$node_bin" . pack --ignore-scripts --json --pack-destination "$pack_dir" > "$work/pack-$label.json"
  )

  pack_file=$(jq -er '
    if type == "array" and length == 1 then
      .[0].filename
    elif type == "object" and length == 1 then
      to_entries[0].value.filename
    else
      error("expected one pack result")
    end
  ' "$work/pack-$label.json")
  expect_equal "$label package filename" "$pack_file" "npm-$expected_version.tgz"
  [[ -f "$pack_dir/$pack_file" ]] || fail "$label package was not created"
  printf '%s source %s (%s), package SHA-256 %s\n' \
    "$label" "$commit" "$expected_version" "$(sha256_file "$pack_dir/$pack_file")"

  git -C "$repo_root" worktree remove --force "$source_dir"
  active_worktree=""
}

verify_source pinned "$npm_commit" "$npm_version"

if [[ "$candidate_sha" != "$npm_commit" ]]; then
  candidate_version=$(git -C "$repo_root" show "$candidate_sha:package.json" | jq -er '.version')
  verify_source candidate "$candidate_sha" "$candidate_version"
fi

printf 'verified npm %s at %s with Node %s at %s; candidate %s\n' \
  "$npm_version" "$npm_commit" "$node_version" "$node_commit" "$candidate_sha"
