#!/usr/bin/env bash

set -eu -o pipefail
shopt -s inherit_errexit

. "$(dirname "${BASH_SOURCE[0]}")/cmd_runner.sh"

main() {
  cmd_runner_setup

  cmd_runner_apply_patches --setup-cleanup true

  local preset_args=(
    run
    # Requirement: always run the command in release mode.
    # See https://github.com/paritytech/command-bot/issues/26#issue-1049555966
    --release
    # "--quiet" should be kept so that the output doesn't get polluted
    # with a bunch of compilation stuff
    --quiet
    --features=try-runtime
    try-runtime
  )

  set -x
  export RUST_LOG="${RUST_LOG:-remote-ext=debug,runtime=trace}"
  cargo "${preset_args[@]}" -- "$@"
}

main "$@"
