#!/bin/bash
# Initially based on https://github.com/paritytech/bench-bot/blob/cd3b2943d911ae29e41fe6204788ef99c19412c3/bench.js

# Most external variables used in this script, such as $GH_CONTRIBUTOR, are
# related to https://github.com/paritytech/try-runtime-bot

# This script relies on $GITHUB_TOKEN which is probably a protected GitLab CI
# variable; if this assumption holds true, it is implied that this script should
# be ran only on protected pipelines

set -eu -o pipefail
shopt -s inherit_errexit

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

cargo_run_benchmarks="cargo +nightly run --quiet --profile=production"
repository="$(basename "$PWD")"

bench_pallet_common_args=(
  --
  benchmark
  pallet
  --steps=50
  --repeat=20
  --extrinsic="*"
  --execution=wasm
  --wasm-execution=compiled
  --heap-pages=4096
)
bench_pallet() {
  local kind="$1"
  local chain="$2"
  local pallet="$3"

  local args
  case "$repository" in
    substrate)
      local pallet_prefix="pallet_"

      local pallet_id
      if [ "${pallet:0:${#pallet_prefix}}" == "$pallet_prefix" ]; then
        pallet_id="$pallet"
      else
        pallet_id="${pallet_prefix}${pallet}"
      fi

      args=(
        --features=runtime-benchmarks
        --manifest-path=bin/node/cli/Cargo.toml
        "${bench_pallet_common_args[@]}"
        "--pallet=$pallet_id"
        "--chain=$chain"
      )

      case "$kind" in
        pallet)
          local output_folder
          if [ "${pallet:0:${#pallet_prefix}}" == "$pallet_prefix" ]; then
            output_folder="${pallet:${#pallet_prefix}}"
          else
            output_folder="$pallet"
          fi
          args+=(
            "--output=./frame/${output_folder}/src/weights.rs"
            --template=./.maintain/frame-weight-template.hbs
          )
        ;;
        *)
          die "Kind $kind is not supported for $repository in bench_pallet"
        ;;
      esac
    ;;
    polkadot)
      args=(
        --features=runtime-benchmarks
        "${bench_pallet_common_args[@]}"
        "--pallet=$pallet"
        "--chain=$chain"
      )

      local chain_directory
      if [ "$chain" == dev ]; then
        chain_directory=polkadot
      elif [[ "$chain" =~ ^(.*)-dev$  ]]; then
        chain_directory="${BASH_REMATCH[1]}"
      else
        die "Could not infer weights directory from $chain"
      fi
      local weights_dir="./runtime/${chain_directory}/src/weights"

      # translates e.g. "pallet_foo::bar" to "pallet_foo_bar"
      local output_file="${pallet//::/_}"

      case "$kind" in
        runtime)
          args+=(
            --header=./file_header.txt
            "--output=${weights_dir}/${output_file}.rs"
          )
        ;;
        xcm)
          args+=(
            --template=./xcm/pallet-xcm-benchmarks/template.hbs
            "--output=${weights_dir}/xcm/${output_file}.rs"
          )
        ;;
        *)
          die "Kind $kind is not supported for $repository in bench_pallet"
        ;;
      esac
    ;;
    cumulus)
      args=(
        --features=runtime-benchmarks
        "${bench_pallet_common_args[@]}"
        "--pallet=$pallet"
        "--chain=${chain}-dev"
      )

      case "$kind" in
        pallet)
          args+=(
            --json
            --header=./file_header.txt
            "--output=./parachains/runtimes/assets/${chain}/src/weights"
          )
        ;;
        *)
          die "Kind $kind is not supported for $repository in bench_pallet"
        ;;
      esac
    ;;
    *)
      die "Repository $repository is not supported in bench_pallet"
    ;;
  esac

  $cargo_run_benchmarks "${args[@]}"
}

process_args() {
  local subcommand="$1"
  shift

  case "$subcommand" in
    runtime|pallet|xcm)
      bench_pallet "$subcommand" "$@"
    ;;
    *)
      die "Invalid subcommand $subcommand to process_args"
    ;;
  esac
}

main() {
  # set the Git user, otherwise Git commands will fail
  git config --global user.name command-bot
  git config --global user.email "<>"

  # Reset the branch to how it was on GitHub when the bot command was issued
  git reset --hard "$GH_HEAD_SHA"

  set -x
  cargo --version
  rustc --version
  cargo +nightly --version
  rustc +nightly --version
  set +x

  # Remove the "github" remote since the same repository might be reused by a
  # GitLab runner, therefore the remote might already exist from a previous run
  # in case it was not cleaned up properly for some reason
  &>/dev/null try git remote remove github

  # Clean up the "github" remote at the end since it contains the $GITHUB_TOKEN
  # secret, which is only available for protected pipelines on GitLab
  cleanup() {
    exit_code=$?
    try git remote remove github
    exit $exit_code
  }
  trap cleanup EXIT

  if [[
    "${UPSTREAM_MERGE:-}" != "n" &&
    ("${GH_OWNER_BRANCH:-}")
  ]]; then
    echo "Merging $GH_OWNER/$GH_OWNER_REPO#$GH_OWNER_BRANCH into $GH_CONTRIBUTOR_BRANCH"
    git remote add \
      github \
      "https://token:${GITHUB_TOKEN}@github.com/${GH_OWNER}/${GH_OWNER_REPO}.git"
    git pull github "$GH_OWNER_BRANCH"
    git remote remove github
  fi

  # https://github.com/paritytech/substrate/pull/10700
  # https://github.com/paritytech/substrate/blob/b511370572ac5689044779584a354a3d4ede1840/utils/wasm-builder/src/wasm_project.rs#L206
  export WASM_BUILD_WORKSPACE_HINT="$PWD"

  set -x
  # Runs the command to generate the weights
  process_args "$@"
  set +x

  # Save the generated weights to GitLab artifacts in case commit+push fails
  echo "Showing weights diff for command"
  git diff -P | tee -a "${ARTIFACTS_DIR}/weights.patch"
  echo "Wrote weights patch to \"${ARTIFACTS_DIR}/weights.patch\""

  # Commits the weights and pushes it
  git add .
  git commit -m "$COMMIT_MESSAGE"

  # Push the results to the target branch
  git remote add \
    github \
    "https://token:${GITHUB_TOKEN}@github.com/${GH_CONTRIBUTOR}/${GH_CONTRIBUTOR_REPO}.git"
  git push github "HEAD:${GH_CONTRIBUTOR_BRANCH}"
}

main "$@"
