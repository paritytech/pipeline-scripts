#!/usr/bin/env bash
#
# Ensure that a PR does not introduce downstream breakages on this project's dependents by
# performing checks using this branch's code. If dependents are specified as companions, they are
# patched to use the code we have in this branch; otherwise, we run the the checks against their
# default branch.

# Companion dependents are extracted from the PR's description when lines conform to the following
# formats:
# [cC]ompanion: https://github.com/org/repo/pull/pr_number
# [cC]ompanion: org/repo#pr_number
# [cC]ompanion: repo#pr_number

echo "

check_dependent_project
========================

This check ensures that this project's dependents do not suffer downstream breakages from new code
changes.

"

set -eu -o pipefail
shopt -s inherit_errexit

die() {
  if [ "${1:-}" ]; then
    >&2 echo "$1"
  fi
  exit 1
}

# valid for 69ab0f76fb851968af8e493061cca84a2f3b1c5b
# FIXME: extract this information from the diener CLI when that is supported
diener_patch_targets=(substrate polkadot cumulus)

org="$1"
this_repo="$2"
this_repo_diener_arg="$3"
dependent_repo="$4"
github_api_token="$5"
update_crates_on_default_branch="$6"
related_companions="$7"

for comp in $related_companions; do
  for patch_target in "${diener_patch_targets[@]}"; do
    if [ "$comp" == "$patch_target" ]; then
      found=true
      break
    fi
  done
  if [ "${found:-}" ]; then
    unset found
  else
    die "Companion $comp is not a valid patch target"
  fi
done

this_repo_dir="$PWD"
companions_dir="$this_repo_dir/companions"
github_api="https://api.github.com"


our_crates=()
our_crates_source="git+https://github.com/$org/$this_repo"
discover_our_crates() {
  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  while IFS= read -r crate; do
    last_line="$crate"
    # for avoiding duplicate entries
    local found
    for our_crate in "${our_crates[@]}"; do
      if [ "$crate" == "$our_crate" ]; then
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      our_crates+=("$crate")
    fi
  # dependencies with {"source": null} are the ones in this project's workspace,
  # hence the getpath($p)==null in the jq script below
  done < <(cargo metadata --quiet --format-version=1 | jq -r '
    . as $in |
    paths |
    select(.[-1]=="source" and . as $p | $in | getpath($p)==null) as $path |
    del($path[-1]) as $path |
    $in | getpath($path + ["name"])
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi
}

match_their_crates() {
  local target_name="$1"
  local crates_not_found=()

  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  # output will be consumed in the format:
  #   crate
  #   source
  #   crate
  #   ...
  local next="crate"
  while IFS= read -r line; do
    last_line="$line"
    case "$next" in
      crate)
        next="source"
        crate="$line"
      ;;
      source)
        next="crate"
        if [ "$line" == "$our_crates_source" ] || [[ "$line" == "$our_crates_source?"* ]]; then
          local found
          for our_crate in "${our_crates[@]}"; do
            if [ "$our_crate" == "$crate" ]; then
              found=true
              break
            fi
          done
          if [ "${found:-}" ]; then
            unset found
          else
            # for avoiding duplicate entries
            for crate_not_found in "${crates_not_found[@]}"; do
              if [ "$crate_not_found" == "$crate" ]; then
                found=true
                break
              fi
            done
            if [ "${found:-}" ]; then
              unset found
            else
              crates_not_found+=("$crate")
            fi
          fi
        fi
      ;;
      *)
        die "ERROR: Unknown state $next"
      ;;
    esac
  done < <(cargo metadata --quiet --format-version=1 | jq -r '
    . as $in |
    paths(select(type=="string")) |
    select(.[-1]=="source") as $source_path |
    del($source_path[-1]) as $path |
    [$in | getpath($path + ["name"]), getpath($path + ["source"])] |
    .[]
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi

  if [ "${crates_not_found[@]}" ]; then
    echo -e "Errors during crate matching\n"
    printf "Failed to detect our crate \"%s\" referenced in $target_name\n" "${crates_not_found[@]}"
    echo -e "\nNote: this error generally happens if you have deleted or renamed a crate and did not update it in $target_name. Consider opening a companion pull request on $target_name and referencing it in this pull request's description like:\n$target_name companion: [your companion PR here]"
    die "Check failed"
  fi
}

companions=()
process_pr_description_line() {
  local companion_expr="$1"
  local source="$2"

  # e.g. https://github.com/paritytech/polkadot/pull/123
  # or   polkadot#123
  if
    [[ "$companion_expr" =~ ^https://github\.com/$org/([^/]+)/pull/([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^$org/([^#]+)#([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^([^#]+)#([[:digit:]]+) ]]
  then
    local repo="${BASH_REMATCH[1]}"
    local pr_number="${BASH_REMATCH[2]}"
    echo "Parsed companion repo=$repo and pr_number=$pr_number in $companion_expr from $source"

    if [ "$this_repo" == "$repo" ]; then
      echo "Skipping $companion_expr as it refers to the repository where this script is currently running"
      return
    fi

    # keep track of duplicated companion references not only to avoid useless
    # work but also to avoid infinite mutual recursion when 2+ PRs reference
    # each other
    for comp in "${companions[@]}"; do
      if [ "$comp" == "$repo" ]; then
        echo "Skipping $companion_expr as the repository $repo has already been registered before"
        return
      fi
    done
    companions+=("$repo")

    # clone the companion and use it to patch dependencies in the future
    git clone --depth=1 "https://github.com/$org/$repo.git" "$companions_dir/$repo"
    pushd "$repo" >/dev/null
    local ref="$(curl \
        -sSL \
        -H "Authorization: token $github_api_token" \
        "$github_api/repos/$org/$repo/pulls/$pr_number" | \
      jq -e -r ".head.ref // error(\"$repo#$pr_number is missing head.ref in the API\"))"
    )"
    git fetch --depth=1 origin "pull/$pr_number/head:$ref"
    git checkout "$ref"
    popd >/dev/null

    # collect also the companions of companions
    process_pr_description "$repo" "$pr_number"
  else
    die "Companion in the PR description of $source had invalid format or did not belong to organization $org: $companion_expr"
  fi
}

process_pr_description() {
  local repo="$1"
  local pr_number="$2"

  if ! [[ "$pr_number" =~ ^[[:digit:]]+$ ]]; then
    return
  fi

  echo "processing pull request $repo#$pr_number"

  local lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done < <(curl \
      -sSL \
      -H "Authorization: token $github_api_token" \
      "$github_api/repos/$org/$this_repo/pulls/$CI_COMMIT_REF_NAME" | \
    jq -e -r ".body"
  )
  # in case the PR has no body, jq should have printed "null" which effectively
  # means lines will always be populated with something
  if [ ! "${lines[@]:-}" ]; then
    die "No lines were read for the description of PR $pr_number (some error probably occurred)"
  fi

  for line in "${lines[@]}"; do
    if [[ "$line" =~ [cC]ompanion:[[:space:]]*([^[:space:]]+) ]]; then
      echo "Detected companion in the PR description of $repo#$pr_number: ${BASH_REMATCH[1]}"
      process_pr_description_line "${BASH_REMATCH[1]}" "$repo#$pr_number"
    fi
  done
}

patch_and_check_dependent() {
  local dependent="$1"

  pushd "$dependent" >/dev/null

  match_their_crates "$dependent"

  # Update the crates to the latest version. This is for example needed if there
  # was a PR to Substrate which only required a Polkadot companion and Cumulus
  # wasn't yet updated to use the latest commit of Polkadot.
  cargo update -p $update_crates_on_default_branch

  for comp in "${companions[@]}"; do
    local found

    for related_comp in $related_companions; do
      if [ "$related_comp" == "$comp" ]; then
        found=true
        break
      fi
    done

    if [ ! "${found:-}" ]; then
      echo "NOTE: Companion $comp was detected but skipped as it is not registered in the related companions (${related_companions:-none})"
      continue
    fi
    unset found

    for diener_target in "${diener_patch_targets[@]}"; do
      if [ "$diener_target" = "$comp" ]; then
        echo "Patching $comp into $dependent"
        diener patch \
          --crates-to-patch "--$diener_target" "$companions_dir/$comp" \
          --path "Cargo.toml"
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      echo "NOTE: Companion $comp was specified but not patched through diener. Either diener does not support it or this script failed to detect its support."
    fi
  done

  diener patch \
    --crates-to-patch "$this_repo_dir" "$this_repo_diener_arg" \
    --path "Cargo.toml"
  eval "${COMPANION_CHECK_COMMAND:-cargo check --all-targets --workspace}"

  popd >/dev/null
}

main() {
  # Set the user name and email to make merging work
  git config --global user.name 'CI system'
  git config --global user.email '<>'
  git config --global pull.rebase false

  discover_our_crates

  # this function calls itself for each discovered companion throughout each
  # discovered PR description, effectively making the script consider the
  # companion references on all PRs
  process_pr_description "$this_repo" "$CI_COMMIT_REF_NAME"

  patch_and_check_dependent "$dependent_repo"
}
main
