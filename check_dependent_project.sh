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

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
. "$(dirname "${BASH_SOURCE[0]}")/github_graphql.sh"

get_arg required --org "$@"
org="$out"

get_arg required --dependent-repo "$@"
dependent_repo="$out"

get_arg required --github-api-token "$@"
github_api_token="$out"

get_arg optional --extra-dependencies "$@"
extra_dependencies="${out:-}"

get_arg optional-many --companion-overrides "$@"
companion_overrides=("${out[@]}")

set -x
this_repo_dir="$PWD"
this_repo="$(basename "$this_repo_dir")"
companions_dir="$this_repo_dir/companions"
extra_dependencies_dir="$this_repo_dir/extra_dependencies"
github_api="https://api.github.com"
github_graphql_api="https://api.github.com/graphql"
org_github_prefix="https://github.com/$org"
org_crates_prefix="git+$org_github_prefix"
set +x

our_crates=()
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

match_dependent_crates() {
  local target_name="$1"
  local crates_not_found=()

  local our_crates_source="$org_crates_prefix/$this_repo"

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

        if [[
          # git+https://github.com/$org/$repo
          "$line" == "$our_crates_source" ||
          # git+https://github.com/$org/$repo?branch=master
          "${line:0:$(( ${#our_crates_source} + 1 ))}" == "${our_crates_source}?"
        ]]; then
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
    printf "Failed to detect our crates \"%s\" referenced in $target_name\n" "${crates_not_found[@]}"
    echo -e "\nNote: this error generally happens if you have deleted or renamed a crate and did not update it in $target_name. Consider opening a companion pull request on $target_name and referencing it in this PR's description like:\n$target_name companion: [companion PR link]"
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
      "$org_github_prefix/$repo.git" \
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

declare -A companion_branch_override
companion_branch_override=()
detect_companion_branch_override() {
  local line="$1"
  # detects the form "[repository] companion branch: [branch]"
  if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+companion[[:space:]]+branch:[[:space:]]*([^[:space:]]+) ]]; then
    companion_branch_override["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  fi
}

declare -A pr_target_branch
pr_target_branch=()
process_pr_description() {
  local repo="$1"
  local pr_number="$2"

  echo "Processing PR $repo#$pr_number"

  local base_ref
  local lines=()
  while IFS= read -r line; do
    if [ "${base_ref:-}" ]; then
      lines+=("$line")
      detect_companion_branch_override "$line"
    else
      base_ref="$line"
    fi
  done < <(curl \
      -sSL \
      -H "Authorization: token $github_api_token" \
      "$github_api/repos/$org/$repo/pulls/$pr_number" | \
    jq -e -r ".base.ref, .body"
  )
  # in case the PR has no body, jq should have printed "null" which effectively
  # means lines will always be populated with something
  # shellcheck disable=SC2128
  if ! [ "$lines" ]; then
    die "No lines were read for the description of PR $pr_number (some error probably occurred)"
  fi

  pr_target_branch["$repo"]="$base_ref"

  for line in "${lines[@]}"; do
    if [[ "$line" =~ ^[[:space:]]*[^[:space:]]+[[:space:]]+[cC]ompanion:[[:space:]]*([^[:space:]]+) ]]; then
      echo "Detected companion in the PR description of $repo#$pr_number: ${BASH_REMATCH[1]}"
      process_pr_description_line "${BASH_REMATCH[1]}" "$repo#$pr_number"
    fi
  done
}

patch_and_check_dependent() {
  local dependent="$1"
  local dependent_repo_dir="$2"

  pushd "$dependent_repo_dir" >/dev/null

  if [ "${has_overridden_dependent_ref:-}" ]; then
    echo "Skipping extra_dependencies ($extra_dependencies) as the dependent repository's ref has been overridden"
  else
    # It is necessary to patch in extra dependencies which have already been
    # merged in previous steps of the Companion Build System's dependency chain.
    # For instance, consider the following dependency chain:
    #     Substrate -> Polkadot -> Cumulus
    # When this script is running for Cumulus as the dependent, on Polkadot's
    # pipeline, it is necessary to patch the master of Substrate into this
    # script's branches because Substrate's master will contain the pull request
    # which was part of the dependency chain for this PR and was merged before
    # this script gets to run for the last time (after lockfile updates and before
    # merge).
    for extra_dependency in $extra_dependencies; do
      if [ "$extra_dependency" = "$this_repo" ]; then
        echo "Skipping extra dependency $extra_dependency because this branch (also $this_repo) will be patched into the dependent $dependent"
        continue
      fi

      # check if a repository specified in $extra_dependencies but is also
      # specified as a companion (e.g. a Substrate PR whose
      # check-dependent-cumulus job specifies `EXTRA_DEPENDENCIES: polkadot` but
      # also a `polkadot companion: something` in its description); in that case
      # skip this step because that repository will be patched later
      for companion in "${companions[@]}"; do
        if [ "$companion" = "$extra_dependency" ]; then
          echo "Skipping extra dependency $extra_dependency because it was specified as a companion"
          continue 2
        fi
      done

      echo "Cloning extra dependency $extra_dependency to patch its default branch into $this_repo and $dependent"
      git clone \
        --depth=1 \
        "$org_github_prefix/$extra_dependency.git" \
        "$extra_dependencies_dir/$extra_dependency"

      echo "Patching extra dependency $extra_dependency into $this_repo_dir"
      diener patch \
        --target "$org_github_prefix/$extra_dependency" \
        --crates-to-patch "$extra_dependencies_dir/$extra_dependency" \
        --path "$this_repo_dir/Cargo.toml"

      echo "Patching extra dependency $extra_dependency into $dependent_repo_dir"
      diener patch \
        --target "$org_github_prefix/$extra_dependency" \
        --crates-to-patch "$extra_dependencies_dir/$extra_dependency" \
        --path Cargo.toml
    done
  fi

  # Patch this repository (the dependency) into the dependent for the sake of
  # being able to test how the dependency graph will behave after the merge
  echo "Patching $this_repo into $dependent"
  diener patch \
    --target "$org_github_prefix/$this_repo" \
    --crates-to-patch "$this_repo_dir" \
    --path Cargo.toml

  # The next step naturally only makes sense if a companion PR was specified for
  # the dependent being targeted by this check, because then processbot will be
  # able to push the lockfile updates to that PR while taking into account
  # dependencies among companions; without a companion PR for the dependent,
  # the dependent's lockfile would not be updated at the end of the merge chain
  # due to the lack of a companion PR (which those lockfile updates would be
  # pushed to), thus leaving the dependent's repository desynchronized.
  # The above problem can be worked around by specifying a dependency in
  # $EXTRA_DEPENDENCIES which takes care of using a dependency's master branch
  # in place of a companion in case a companion for that dependency was not
  # specified, as described in
  # https://github.com/paritytech/substrate/pull/11280#issue-1214392074.

  # Each companion dependency is also patched into the dependent so that the
  # dependency graph becomes how it should end up after all PRs are merged.
  for companion in "${companions[@]}"; do
    echo "Patching $this_repo into the $comp companion, which could be a dependency of $dependent, assuming that $companion also depends on $this_repo. Reasoning: if a companion was referenced in this PR or a companion of this PR, then it probably has a dependency on this PR, since PR descriptions are processed starting from the dependencies."
    diener patch \
      --target "$org_github_prefix/$this_repo" \
      --crates-to-patch "$this_repo_dir" \
      --path "$companions_dir/$comp/Cargo.toml"

    echo "Patching $comp companion into $dependent"
    diener patch \
      --target "$org_github_prefix/$comp" \
      --crates-to-patch "$companions_dir/$comp" \
      --path Cargo.toml
  done

  # Match the crates *AFTER* patching for verifying that dependencies which are
  # removed in this pull request have been pruned properly from the dependent.
  # It does not make sense to do this before patching since the dependency graph
  # would not yet how be how it should become after all merges are finished.
  match_dependent_crates "$dependent"

  eval "${COMPANION_CHECK_COMMAND:-cargo check --all-targets --workspace}"

  popd >/dev/null
}

main() {
  if ! [[ "$CI_COMMIT_REF_NAME" =~ ^[[:digit:]]+$ ]]; then
    die "\"$CI_COMMIT_REF_NAME\" was not recognized as a pull request ref"
  fi

  # Set the user name and email to make merging work
  git config --global user.name 'CI system'
  git config --global user.email '<>'
  git config --global pull.rebase false

  # process_pr_description calls itself for each companion in the description on
  # each detected companion PR, effectively considering all companion references
  # on all PRs
  process_pr_description "$this_repo" "$CI_COMMIT_REF_NAME"

  # This PR might be targetting a custom ref (i.e. not master) through companion
  # overrides from --companion-overrides or the PR's description, in which case
  # it won't be proper to merge master (since it's not targetting master) before
  # performing the companion checks
  local dependent_repo_dir="$companions_dir/$dependent_repo"
  if ! [ -e "$dependent_repo_dir" ]; then
    local dependent_clone_options=(
      --depth=1
    )

    if [ "${pr_target_branch[$this_repo]}" == "master" ]; then
      echo "Cloning dependent $dependent_repo directly as it was not detected as a companion"
    elif [ "${companion_branch_override[$dependent_repo]:-}" ]; then
      echo "Cloning dependent $dependent_repo with branch ${companion_branch_override[$dependent_repo]} from manual override"
      dependent_clone_options+=("--branch" "${companion_branch_override[$dependent_repo]}")
      has_overridden_dependent_ref=true
    else
      for override in "${companion_overrides[@]}"; do
        echo "Processing companion override $override"

        local this_repo_override this_repo_override_prefix dependent_repo_override dependent_repo_override_prefix
        while IFS= read -r line; do
          if [[ "$line" =~ ^[[:space:]]*$this_repo:[[:space:]]*(.*) ]]; then
            this_repo_override="${BASH_REMATCH[1]}"
            if [[ "$this_repo_override" =~ ^(.*)\* ]]; then
              this_repo_override_prefix="${BASH_REMATCH[1]}"
            fi
          elif [[ "$line" =~ ^[[:space:]]*$dependent_repo:[[:space:]]*(.*) ]]; then
            dependent_repo_override="${BASH_REMATCH[1]}"
            if [[ "$dependent_repo_override" =~ ^(.*)\* ]]; then
              dependent_repo_override_prefix="${BASH_REMATCH[1]}"
            fi
          fi
        done < <(echo "$override")

        if [[
          ! ("${this_repo_override:-}") ||
          ! ("${dependent_repo_override:-}")
        ]]; then
          continue
        fi

        echo "Detected override $this_repo_override for $this_repo and override $dependent_repo_override for $dependent_repo"

        local base_ref_prefix="${this_repo_override_prefix:-$this_repo_override}"
        if [ "${pr_target_branch[$this_repo]:0:${#base_ref_prefix}}" != "$base_ref_prefix" ]; then
          continue
        fi

        local this_repo_override_suffix
        if [ "${this_repo_override_prefix:-}" ]; then
          this_repo_override_suffix="${pr_target_branch[$this_repo]:${#this_repo_override_prefix}}"
        fi

        dependent_clone_options+=("--branch")
        local branch_name
        if [[
          ("${dependent_repo_override_prefix:-}") &&
          ("${this_repo_override_suffix:-}")
        ]]; then
          branch_name="${dependent_repo_override_prefix}${this_repo_override_suffix}"

          echo "Checking if $branch_name exists in $dependent_repo"
          local response_code
          response_code="$(curl \
            -o /dev/null \
            -sSL \
            -H "Authorization: token $github_api_token" \
            -w '%{response_code}' \
            "$github_api/repos/$org/$dependent_repo/branches/$branch_name"
          )"

          # Sometimes the target branch found via override does not *yet* exist
          # in the companion's repository because their release processes work
          # differently; e.g. a release-v0.9.20 Polkadot branch might have a
          # polkadot-v0.9.20 matching branch (notice the version) on Substrate,
          # but not yet on Cumulus because their release approach is different.
          # When that happens, the script has no choice other than *guess* the
          # a replacement branch to be used for the inexistent branch.
          if [ "$response_code" -eq 200 ]; then
            echo "Branch $branch_name exists in $dependent_repo. Proceeding..."
          else
            echo "Branch $branch_name doesn't exist in $dependent_repo (status code $response_code)"
            echo "Fetching the list of branches in $dependent_repo to find a suitable replacement..."

            # The guessing for a replacement branch works by taking the most
            # recently updated branch (ordered by commit date) which follows the
            # pattern we've matched for the branch name. For example, if
            # polkadot-v0.9.20 does not exist, instead use the latest (by commit
            # date) branch following a "polkadot-v*" pattern, which happens to
            # be polkadot-v0.9.19 as of this writing.
            local replacement_branch_name
            while IFS= read -r line; do
              echo "Got candidate branch $line in $dependent_repo's refs"
              if [ "${line:0:${#dependent_repo_override_prefix}}" == "$dependent_repo_override_prefix" ]; then
                echo "Found candidate branch $line as the replacement of $branch_name"
                replacement_branch_name="$line"
                break
              fi
            done < <(ghgql_post \
              "$github_graphql_api" \
              "$github_api_token" \
              "$(
                ghgql_most_recent_branches_query \
                  "$org" \
                  "$dependent_repo" \
                  "$dependent_repo_override_prefix"
              )" | jq -r '.data.repository.refs.edges[].node.name'
            )

            if [ "${replacement_branch_name:-}" ]; then
              echo "Choosing branch $line as a replacement for $branch_name"
              branch_name="$replacement_branch_name"
              unset replacement_branch_name
            else
              die "Unable to find the replacement for inexistent branch $branch_name of $dependent_repo"
            fi
          fi
        else
          branch_name="$dependent_repo_override"
        fi
        dependent_clone_options+=("$branch_name")

        echo "Setting up the clone of $dependent_repo with options: ${dependent_clone_options[*]}"
        has_overridden_dependent_ref=true

        break
      done
    fi

    dependent_repo_dir="$this_repo_dir/$dependent_repo"
    # shellcheck disable=SC2068
    git clone \
      ${dependent_clone_options[@]} \
      "$org_github_prefix/$dependent_repo.git" \
      "$dependent_repo_dir"
  fi

  if [ "${has_overridden_dependent_ref:-}" ]; then
    echo "Skipping master merge of $this_repo as the dependent repository's ref has been overridden"
  else
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
  fi

  discover_our_crates

  patch_and_check_dependent "$dependent_repo" "$dependent_repo_dir"
}
main
