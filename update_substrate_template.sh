#!/bin/bash

# This is an automation for updating Substrate Node Template
# https://github.com/substrate-developer-hub/substrate-node-template
# Triggered on push of new branch on polkadot release (i.e polkadot-v0.9.26) on substrate repo
#
# TODO: If any step fails => send a notification to some channel
#
# Usage:
# Update Cumulus -> Substrate Parachain Template
# ./pipeline-scripts/update_substrate_template.sh
#        --repo-name substrate-parachain-template
#        --template-path "parachain-template"
#        --github-api-token "$GITHUB_TOKEN"
#        --polkadot-branch "$CI_COMMIT_REF_NAME"
#
# Update Substrate -> Substrate Node Template
# ./pipeline-scripts/update_substrate_template.sh
#        --repo-name substrate-node-template
#        --template-path "bin/node-template"
#        --github-api-token "$GITHUB_TOKEN"
#        --polkadot-branch "$CI_COMMIT_REF_NAME"

set -eu -o pipefail

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# substrate-parachain-template or substrate-node-template
get_arg required --repo-name "$@"
target_repo_name="$out"

# "bin/node-template" or "parachain-template"
get_arg required --template-path "$@"
template_path="$out"

# GITHUB_TOKEN or other
get_arg required --github-api-token "$@"
github_api_token="$out"

# $CI_COMMIT_REF_NAME
get_arg required --polkadot-branch "$@"
polkadot_branch="$out"

target_org="substrate-developer-hub"
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
default_branch=main
working_directory="$PWD"
working_repo="$(basename $PWD)"
source_template_path="$working_directory/$template_path"
dest_template_path="$working_directory/$target_repo_name"
template_branch="autoupdate_${polkadot_branch}_${timestamp}"
repo_url_with_token="https://$github_api_token@github.com/$target_org/$target_repo_name.git"

echo "working_repo - $working_repo"
echo "working_directory - $working_directory"
echo "source_template_path - $source_template_path"
echo "dest_template_path - $dest_template_path"
echo "template_branch - $template_branch"

# Step 1) clone substrate-node-template repo as destination
echo "Cleaning existing $dest_template_path"
rm -rf "$dest_template_path"
git clone "$repo_url_with_token" "$dest_template_path"

# Step 2) copy files from ./bin/node-template to substrate-*-template
echo "Copying fresh template $source_template_path to $dest_template_path"
cp -a "$source_template_path/." "$dest_template_path"

# Step 3) replace references to pallets from local (relative) to remote (git + branch)
echo "Change directory to $dest_template_path"
cd "$dest_template_path"

# stings like 'path = "../../../../frame/system"'
# but avoid "local" dependencies (from parent folder), like 'path = "../runtime"'
query_pattern='path = "\.\.\/\.[^"]*"'
# should be replaced with 'git = "https://github.com/paritytech/substrate.git", branch = "polkadot-v0.9.26"' (or cumulus)
replace_ref="git = \"https:\/\/github.com\/paritytech\/$working_repo.git\", branch = \"${polkadot_branch}\""

# find all .toml files and replace relative paths to github repo with polkadot branch
echo "Replacing <$query_pattern> with <$replace_ref> in .toml files"
find . -type f -name '*.toml'
find . -type f -name '*.toml' -exec sed -i -E "s/$query_pattern/$replace_ref/g" {} \;

# update substrate deps which may point to master to $polkadot_branch (could be in cumulus)
diener update --substrate --branch "$polkadot_branch"

# Step 4)
echo "Run <cargo generate-lockfile> to update replaced references in root Cargo.lock"
cargo generate-lockfile

# Step 5) commit & push to https://github.com/substrate-developer-hub/substrate-*-template
git config --global user.name substrate-developer-hub
git config --global user.email "devops-team@parity.io"
git remote -v
git checkout -b "$template_branch"
git add .
commit_message="Auto-Update $target_repo_name from $polkadot_branch"
git commit -m "$commit_message"
git push origin HEAD

# Step 6) create a pull-request
curl \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: token $github_api_token" \
  https://api.github.com/repos/$target_org/$target_repo_name/pulls \
  -d '{"title":"'"$commit_message"'","body":"'"$commit_message"'","head":"'"$template_branch"'","base":"'"$default_branch"'"}'
