#!/usr/bin/env bash

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

set -eu -o pipefail
shopt -s inherit_errexit

cmd_runner_display_rust_toolchain() {
  cargo --version
  rustc --version
  cargo +nightly --version
  rustc +nightly --version
}

cmd_runner_setup() {
  # set the Git user, otherwise Git commands will fail
  git config --global user.name command-bot
  git config --global user.email "<>"

  # Reset the branch to how it was on GitHub when the bot command was issued
  git reset --hard "$GH_HEAD_SHA"

  cmd_runner_display_rust_toolchain

  # https://github.com/paritytech/substrate/pull/10700
  # https://github.com/paritytech/substrate/blob/b511370572ac5689044779584a354a3d4ede1840/utils/wasm-builder/src/wasm_project.rs#L206
  export WASM_BUILD_WORKSPACE_HINT="$PWD"
}

cmd_runner_apply_patches() {
  get_arg optional --setup-dirs-cleanup "$@"
  local setup_cleanup="${out:-}"

  while IFS= read -r line; do
    if ! [[ "$line" =~ ^PATCH_([^=]+)=(.*)$ ]]; then
      continue
    fi
    echo "Matched environment variable for patching: $line"

    local repository="${BASH_REMATCH[1]}"
    local branch="${BASH_REMATCH[2]}"
    local repository_dir=".git/cmd-runner-patch/$repository"

    mkdir -p .git/cmd-runner-patch
    rm -rf "$repository_dir"
    git clone \
      --depth 1 \
      "https://token:${GITHUB_TOKEN}@github.com/${GH_OWNER}/${repository}.git" \
      "$repository_dir"
    tmp_dirs+=("$repository_dir")
    echo "Cloned repository for patching: ${GH_OWNER}/${repository}"

    >/dev/null pushd "$repository_dir"

    local head_sha
    head_sha="$(git rev-parse HEAD)"

    git checkout --quiet "$head_sha"
    2>/dev/null git branch -D to-patch || :

    local ref
    if [[ "$branch" =~ ^[[:digit:]]+$ ]]; then
      ref="pull/$branch/head"
    else
      ref="$branch"
    fi

    git remote add \
      github \
      "https://token:${GITHUB_TOKEN}@github.com/${GH_OWNER}/${repository}.git"
    git fetch github "$ref:to-patch"
    git checkout to-patch
    git remote remove github

    echo "Checked out $ref of repository $repository at commit sha $(git rev-parse HEAD) for patching"

    >/dev/null popd

    diener patch \
      --target "https://github.com/${GH_OWNER}/${GH_OWNER_REPO}" \
      --crates-to-patch "$repository_dir" \
      --path Cargo.toml
  done < <(env)

  if [ "$setup_cleanup" ]; then
    cleanup() {
      exit_code=$?
      rm -rf "${tmp_dirs[@]}"
      exit $exit_code
    }
    trap cleanup EXIT
  fi
}
