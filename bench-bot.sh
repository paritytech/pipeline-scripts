#!/bin/bash
# Initially based on https://github.com/paritytech/bench-bot/blob/cd3b2943d911ae29e41fe6204788ef99c19412c3/bench.js

# Most external variables used in this script, such as $GH_CONTRIBUTOR, are
# related to https://github.com/paritytech/try-runtime-bot

# This script relies on $GITHUB_TOKEN which is probably a protected GitLab CI
# variable; if this assumption holds true, it is implied that this script should
# be ran only on protected pipelines

set -eu -o pipefail

cargo_run_benchmarks="cargo +nightly run --quiet --profile=production"
repository="$(basename "$PWD")"

die() {
  if [ "${1:-}" ]; then
    >&2 echo "$1"
  fi
  exit 1
}

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

  # translates e.g. "pallet_foo::bar" to "pallet_foo_bar"
  local output_file="${pallet//::/_}"

  local args
  case "$repository" in
    substrate)
      args=(
        --features=runtime-benchmarks
        --manifest-path=bin/node/cli/Cargo.toml
        "${bench_pallet_common_args[@]}"
        "--pallet=${pallet}"
        "--chain=${chain}"
      )

      case "$kind" in
        runtime)
          # replaces all the '_' in the pallet name with '-'
          local pallet_folder="${pallet//_/-}"
          args+=(
            "--output=./frame/${pallet_folder}/src/weights.rs"
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
        "--pallet=${pallet}"
        "--chain=${chain}"
      )

      if ! [[ "$chain" =~ ^(.*)-dev$  ]]; then
        die "Could not infer weights directory from $chain"
      fi
      local weights_dir="./runtime/${BASH_REMATCH[1]}/src/weights"

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
    runtime|xcm)
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
  git reset .gitlab-ci.yml

  git commit -m "$COMMIT_MESSAGE"

  git remote add \
    github \
    "https://token:${GITHUB_TOKEN}@github.com/${GH_CONTRIBUTOR}/${GH_CONTRIBUTOR_REPO}.git"
  git push github "HEAD:${GH_CONTRIBUTOR_BRANCH}"
}

main "$@"
