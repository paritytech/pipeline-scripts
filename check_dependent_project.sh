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

org="$1"
this_repo="$2"
this_repo_diener_arg="$3"
dependent_repo="$4"
github_api_token="$5"
update_crates_on_default_branch="$6"

this_repo_dir="$PWD"
companions_dir="$this_repo_dir/companions"
github_api="https://api.github.com"
org_github_prefix="https://github.com/$org"
org_crates_prefix="git+$org_github_prefix"

our_crates=()
our_crates_source="$org_crates_prefix/$this_repo"
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

dependent_companions=()
match_dependent_crates() {
  local target_name="$1"
  local crates_not_found=()
  dependent_companions=()

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

        for comp in "${companions[@]}"; do
          local companion_crate_source="$org_crates_prefix/$comp"
          if [ "$line" == "$companion_crate_source" ] || [[ "$line" == "$companion_crate_source?"* ]]; then
            # prevent duplicates in dependent_companions
            local found
            for dep_comp in "${dependent_companions[@]}"; do
              if [ "$dep_comp" == "$comp" ]; then
                found=true
                break
              fi
            done
            if [ "${found:-}" ]; then
              unset found
            else
              dependent_companions+=("$comp")
            fi
          fi
        done

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
    echo -e "\nNote: this error generally happens if you have deleted or renamed a crate and did not update it in $target_name. Consider opening a companion pull request on $target_name and referencing it in this PR's description like:\n$target_name companion: [your companion PR here]"
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

    local state closed mergeable ref sha
    read -d '\n' -r state closed mergeable ref sha < <(curl \
        -sSL \
        -H "Authorization: token $github_api_token" \
        "$github_api/repos/$org/$repo/pulls/$pr_number" | \
      jq -e -r "[
        .state,
        .closed,
        .mergeable,
        .head.ref,
        .head.sha
      ] | .[]"
    # https://stackoverflow.com/questions/40547032/bash-read-returns-with-exit-code-1-even-though-it-runs-as-expected
    # ignore the faulty exit code since read still is regardless still reading the values we want
    ) || :

    if [[ "$state" == "closed" || "$closed" == "true" ]]; then
      echo "Skipping $repo#$pr_number because it is closed"
      return
    fi

    if [ "$mergeable" != "true" ]; then
      die "Github API says $repo#$pr_number is not mergeable"
    fi

    companions+=("$repo")

    # Heuristic: assume the companion PR has a common merge ancestor with master
    # in its last N commits.
    local merge_ancestor_max_depth=100

    # Clone the default branch of this companion's target repository (assumed to
    # be named "master")
    git clone \
      --depth=$merge_ancestor_max_depth \
      "https://github.com/$org/$repo.git" \
      "$companions_dir/$repo"
    pushd "$companions_dir/$repo" >/dev/null

    # Show what branches we got after cloning the repository
    git show-ref

    # Clone the companion's branch
    echo "Cloning the companion $repo#$pr_number (branch $ref, SHA $sha)"
    git fetch --depth=$merge_ancestor_max_depth origin "pull/$pr_number/head:$ref"
    git checkout "$ref"

echo "
Attempting to merge $repo#$pr_number with master after fetching its last $merge_ancestor_max_depth commits.

If this step fails, either:

- $repo#$pr_number has conflicts with master

OR

- A common merge ancestor could not be found between master and the last $merge_ancestor_max_depth commits of $repo#$pr_number.

Both cases can be solved by merging master into $repo#$pr_number.
"
    git show-ref origin/master
    git merge origin/master \
      --verbose \
      --no-edit \
      -m "Merge master of $repo into companion $repo#$pr_number"

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

  echo "Processing PR $repo#$pr_number"

  local lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done < <(curl \
      -sSL \
      -H "Authorization: token $github_api_token" \
      "$github_api/repos/$org/$repo/pulls/$pr_number" | \
    jq -e -r ".body"
  )
  # in case the PR has no body, jq should have printed "null" which effectively
  # means lines will always be populated with something
  if ! [ "$lines" ]; then
    die "No lines were read for the description of PR $pr_number (some error probably occurred)"
  fi

  for line in "${lines[@]}"; do
    if [[ "$line" =~ [cC]ompanion:[[:space:]]*([^[:space:]]+) ]]; then
      echo "Detected companion in the PR description of $repo#$pr_number: ${BASH_REMATCH[1]}"
      process_pr_description_line "${BASH_REMATCH[1]}" "$repo#$pr_number"
    fi
  done
}

update_crates() {
  local args=()

  for crate in "$@"; do
    args+=("-p" "$crate")
  done

  cargo update "${args[@]}"
}

patch_and_check_dependent() {
  local dependent="$1"
  local dependent_repo_dir="$2"

  pushd "$dependent_repo_dir" >/dev/null

  # Update the crates to the latest version. This is for example needed if there
  # was a PR to Substrate which only required a Polkadot companion and Cumulus
  # wasn't yet updated to use the latest commit of Polkadot.
  update_crates $update_crates_on_default_branch

  match_dependent_crates "$dependent"

  for comp in "${dependent_companions[@]}"; do
    echo "Patching $this_repo into the $comp companion, which is a dependency of $dependent_repo, assuming $comp also depends on $this_repo. Reasoning: if a companion was referenced in this PR or a companion of this PR, then it probably has a dependency on this PR, since PR descriptions are processed starting from the dependencies."
    diener patch \
      --target "$org_github_prefix/$this_repo" \
      --crates-to-patch "$this_repo_dir" \
      --path "$companions_dir/$comp/Cargo.toml"

    echo "Patching $comp companion into $dependent"
    diener patch \
      --target "$org_github_prefix/$comp" \
      --crates-to-patch "$companions_dir/$comp" \
      --path "Cargo.toml"
  done

  echo "Patching $this_repo into $dependent"
  diener patch \
    --target "$org_github_prefix/$this_repo" \
    --crates-to-patch "$this_repo_dir" \
    --path "Cargo.toml"

  eval "${COMPANION_CHECK_COMMAND:-cargo check --all-targets --workspace}"

  popd >/dev/null
}

main() {
  # Set the user name and email to make merging work
  git config --global user.name 'CI system'
  git config --global user.email '<>'
  git config --global pull.rebase false

  # Merge master into this branch so that we have a better expectation of the
  # integration still working after this PR lands.
  # Since master's HEAD is being merged here, at the start the dependency chain,
  # the same has to be done for all the companions because they might have
  # accompanying changes for the code being brought in.
  git fetch --force origin master
  git show-ref origin/master
  echo "Merge master into $this_repo#$CI_COMMIT_REF_NAME"
  git merge origin/master \
    --verbose \
    --no-edit \
    -m "Merge master into $this_repo#$CI_COMMIT_REF_NAME"

  discover_our_crates

  # process_pr_description calls itself for each companion in the description on
  # each detected companion PR, effectively considering all companion references
  # on all PRs
  process_pr_description "$this_repo" "$CI_COMMIT_REF_NAME"

  local dependent_repo_dir="$companions_dir/$dependent_repo"
  if ! [ -e "$dependent_repo_dir" ]; then
    echo "Cloning $dependent_repo directly as it was not detected as a companion"
    dependent_repo_dir="$this_repo_dir/$dependent_repo"
    git clone --depth=1 "https://github.com/$org/$dependent_repo.git" "$dependent_repo_dir"
  fi

  patch_and_check_dependent "$dependent_repo" "$dependent_repo_dir"
}
main
