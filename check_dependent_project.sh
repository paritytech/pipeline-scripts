#!/usr/bin/env bash

# This script validates that a given PR does not introduce breakages to its
# dependents. The validation revolves around patching the dependencies into the
# dependent targetted by this check ahead of time, as if to simulate how it's
# going to behave after all PRs are merged.
# ---
# First it tries to extract the PRs to be used for this check, a.k.a the
# COMPANIONS, from the PR's description when lines conform to the following
# formats:
# [cC]ompanion: https://github.com/org/repo/pull/pr_number
# [cC]ompanion: org/repo#pr_number
# [cC]ompanion: repo#pr_number
# If no companions are found for the targetted dependents, instead their default
# branch is used.
# ---
# After all dependencies are collected they'll be patched into the dependent,
# which will result in a single branch for which a pipeline will be created on
# GitLab. Should the created pipeline succeed we'll attempt to save the check's
# data to Redis so that it can be leveraged for *potentially* skipping a
# redundant run of the dependent's pipeline in the future
# (./check_dependent_project_pipeline.sh).

echo "

check_dependent_project
========================

This check validates that this project's dependents are not suffering breakages
from this project's pull requests.
"

set -eu -o pipefail
shopt -s inherit_errexit

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
. "$(dirname "${BASH_SOURCE[0]}")/github_graphql.sh"

if [[
  # patched companions sent to GitLab
  "${CI_COMMIT_REF_NAME:-}" =~ ^cbs-.*-CMP([[:digit:]]+)$
]]; then
  this_pr_number=${BASH_REMATCH[1]}
elif [[
  # PRs mirrored to GitLab
  "${CI_COMMIT_REF_NAME:-}" =~ ^[[:digit:]]+$
]]; then
  this_pr_number=$CI_COMMIT_REF_NAME
else
  echo "\$CI_COMMIT_REF_NAME was not recognized as a pull request ref: ${CI_COMMIT_REF_NAME:-}"
  exit 0
fi

# generate a unique name for the patched branch with regards to this project and
# the dependent. $CI_PROJECT_ID needs to be added so it doesn't collide with a
# dependency check from another repository (e.g. both Substrate and Polkadot
# have check-dependent-cumulus).
gitlab_dependent_branch_name="cbs-$CI_PROJECT_ID-PR$this_pr_number"

get_arg required --org "$@"
org="$out"

get_arg required --dependent-repo "$@"
dependent="$out"

get_arg required --gitlab-url "$@"
gitlab_url="$out"
if [[ "$gitlab_url" =~ ^([a-zA-Z]+://)(.*) ]]; then
  gitlab_url_prefix="${BASH_REMATCH[1]}"
  gitlab_domain="${BASH_REMATCH[2]}"
else
  gitlab_url_prefix="https://"
  gitlab_domain="$gitlab_url"
fi

get_arg required --gitlab-dependent-path "$@"
gitlab_dependent_path="$out"

# gitlab_dependent_token needs `api` and `write_repository` scopes
# - `write_repository` so that we'll be able to push the patched dependent
#   branch to GitLab
# - `api` so that we'll be able to create a pipeline for the patched dependent
#   branch
get_arg required --gitlab-dependent-token "$@"
gitlab_dependent_token="$out"

get_arg required --github-api-token "$@"
github_api_token="$out"

get_arg optional --extra-dependencies "$@"
extra_dependencies="${out:-}"

get_arg optional-many --companion-overrides "$@"
companion_overrides=("${out[@]}")

set -x
this_repo_dir="$PWD"
this_repo="$(basename "$this_repo_dir")"
companions_dir="$this_repo_dir/.git/companions"
extra_dependencies_dir="$this_repo_dir/.git/extra_dependencies"
github_api="https://api.github.com"
github_graphql_api="https://api.github.com/graphql"
org_github_prefix="https://github.com/$org"
org_crates_prefix="git+$org_github_prefix"
set +x

dependent_git_history_depth=100

cleanup() {
  rm -rf "$companions_dir" "$extra_dependencies_dir"
}
cleanup
trap cleanup EXIT

our_crates=()
discover_our_crates() {
  local dir="$1"

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
  done < <(cargo metadata \
    --quiet \
    --format-version=1 \
    --manifest-path "$dir/Cargo.toml" | jq -r '
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
          "${line::$(( ${#our_crates_source} + 1 ))}" == "${our_crates_source}?"
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

    local state closed
    read -d '\n' -r state closed < <(curl \
        -sSL \
        -H "Authorization: token $github_api_token" \
        "$github_api/repos/$org/$repo/pulls/$pr_number" | \
      jq -e -r "[
        .state,
        .closed
      ] | .[]"
    # https://stackoverflow.com/questions/40547032/bash-read-returns-with-exit-code-1-even-though-it-runs-as-expected
    # ignore the faulty exit code since read still is regardless still reading the values we want
    ) || :

    if [[ "$state" == "closed" || "$closed" == "true" ]]; then
      echo "Skipping $repo#$pr_number because it is closed"
      return
    fi

    companions+=("$repo")

    git clone \
      --depth=$dependent_git_history_depth \
      "$org_github_prefix/$repo.git" \
      "$companions_dir/$repo"

    pushd "$companions_dir/$repo" >/dev/null

    local branch_name="PR-$pr_number"
    git fetch --depth=$dependent_git_history_depth origin "pull/$pr_number/head:$branch_name"
    git checkout "$branch_name"

    local head_sha
    head_sha="$(git rev-parse HEAD)"
    branch_name="$head_sha"
    git branch -m "$branch_name"

    echo "Cloned companion $repo#$pr_number at commit $head_sha"

    >/dev/null popd

    merge_upstream "$repo" "$companions_dir/$repo"

    if [ "$repo" == "$dependent" ]; then
      dependent_pr="$pr_number"
    fi

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

update_local_crates() {
  local gitlab_destination="$1"

  local last_line
  local crates=()
  while IFS= read -r crate; do
    last_line="$crate"
    if [ "${crate: -5}" == ":null" ]; then
      continue
    fi
    # for avoiding duplicate entries
    local found
    for found_crate in "${crates[@]}"; do
      if [ "$crate" == "$found_crate" ]; then
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      crates+=("$crate")
    fi
  # dependencies with {"source": null} are the ones in this project's workspace,
  # hence the getpath($p)==null in the jq script below
  done < <(cargo metadata --quiet --format-version=1 | jq -r '
    . as $in |
    paths |
    select(.[-1]=="source" and . as $p | $in | getpath($p)==null) as $path |
    del($path[-1]) as $path |
    $in | "\(getpath($path + ["name"])):\(getpath($path + ["version"]))"
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi

  local update_args=()
  for crate in "${crates[@]}"; do
    update_args+=("-p" "$crate")
  done
  set -x
  cat Cargo.toml
  cargo update "${update_args[@]}"
  set +x

  # remove crates which weren't used in the crate graph. this is required for
  # cargo commands which use the "--locked" flag since unused patches makes
  # Cargo.lock become unstable.
  local unused_dependencies
  readarray -t unused_dependencies < <(toml \
    get \
    --toml-path Cargo.lock patch | \
    jq -r '.unused | .[] | .name'
  )
  toml unset --toml-path Cargo.lock 'patch'

  while IFS= read -r patched_repository; do
    while IFS= read -r patched_dependency; do
      for unused_dependency in "${unused_dependencies[@]}"; do
        if [ "$unused_dependency" == "$patched_dependency" ]; then
          toml unset --toml-path Cargo.toml patch "$patched_repository" "$patched_dependency"
          continue 2
        fi
      done
    done < <(toml get --toml-path Cargo.toml patch "$patched_repository" | jq -r 'keys | .[]')
  done < <(toml get --toml-path Cargo.toml patch | jq -r 'keys | .[]')
}

replace_project_with() {
  local source="$1"
  local destination="$PWD"

  # shellcheck disable=SC2012
  ls -A "$destination" | while IFS= read -r file; do
    if [ "$file" != ".git" ]; then
      if [ -d "$file" ]; then
        rm -rf "$file"
      else
        rm -f "$file"
      fi
    fi
  done

  >/dev/null pushd "$source"
  # shellcheck disable=SC2012
  ls -A "$source" | while IFS= read -r file; do
    if [ "$file" != ".git" ]; then
      if [ -d "$file" ]; then
        cp -r "$file" "$destination"
      else
        cp "$file" "$destination"
      fi
    fi
  done
  >/dev/null popd
}

detect_dependencies_among_companions() {
  local dir="${1:-$PWD}"

  dependencies_among_companions=()

  local org_crates_prefix_with_slash="${org_crates_prefix}/"

  # in the past we've used cargo metadata to detect dependencies but it was
  # finnicky since it could fail depending on the patching order
  # see https://github.com/paritytech/pipeline-scripts/issues/49
  while IFS= read -r line; do
    # match git+https://github.com/org/repo?branch=master#dea1e3f5d9
    if [ "${line::${#org_crates_prefix_with_slash}}" != "$org_crates_prefix_with_slash" ]; then
      continue
    fi

    local after_org_prefix="${line:${#org_crates_prefix_with_slash}}"

    for companion in "${companions[@]}"; do
      # match repo?branch=master#dea1e3f5d9
      if [ "${after_org_prefix::$(( ${#companion} + 1 ))}" == "${companion}?" ]; then
        local found
        for dependency_among_companions in "${dependencies_among_companions[@]}"; do
          if [ "$dependency_among_companions" == "$companion" ]; then
            found=true
            break
          fi
        done
        if [ "${found:-}" ]; then
          unset found
        else
          dependencies_among_companions+=("$companion")
        fi
        continue 2
      fi
    done
  done < <(toml get --toml-path "$dir/Cargo.lock" | \
    jq -r '
      . as $in |
      paths(select(type=="string")) |
      select(.[-1]=="source") as $source_path |
      $in |
      getpath($source_path)
    '
  )
}

register_used_org_dep() {
  local hashed_files="$1"
  local repository="$2"
  local commit_sha="$3"
  patched_org_deps+=(
    "$org_crates_prefix/$repository?branch=master#"
    "$org_github_prefix/$repository/archive/$commit_sha.tar.gz"
    "$hashed_files"
    "$repository"
    "$commit_sha"
  )
}

register_success() {
  local dependent_repo_dir="$1"
  local dependent_pr="$2"
  local dependent_commit_sha="$3"
  local jobs_url="$4"
  local dependent_files="$5"

  local cargo_lock_json
  cargo_lock_json="$(toml get --toml-path "$dependent_repo_dir/Cargo.lock")"

  local dependencies_json='{'
  if [ ${#patched_org_deps[*]} -gt 0 ]; then
    for ((i=0; i < ${#patched_org_deps[*]}; i+=5)); do
      local prefix="${patched_org_deps[$i]}"
      local url="${patched_org_deps[$((i+1))]}"
      local files="${patched_org_deps[$((i+2))]}"
      local repository="${patched_org_deps[$((i+3))]}"
      local commit_sha="${patched_org_deps[$((i+4))]}"
      dependencies_json+="$(echo -n "$prefix" | jq -sRr @json): {
        \"url\": $(echo -n "$url" | jq -sRr @json),
        \"files\": $(echo -n "$files" | jq -sRr @json),
        \"repository\": $(echo -n "$repository" | jq -sRr @json),
        \"sha\": $(echo -n "$commit_sha" | jq -sRr @json)
      },"
    done
    dependencies_json="${dependencies_json:: -1}"
  fi
  dependencies_json+='}'

  local dependent_json
  dependent_json="{
    \"files\": $(echo -n "$dependent_files" | jq -sRr @json),
    \"sha\": $(echo -n "$dependent_commit_sha" | jq -sRr @json)
  }"

  local jobs_json
  jobs_json="$(echo -n "$jobs_url" | jq -sRr @json)"

  local payload="{
    \"cargo_lock\": $cargo_lock_json,
    \"dependencies\": $dependencies_json,
    \"dependent\": $dependent_json,
    \"jobs\": $jobs_json 
  }"
  echo "Sending payload to Redis:"$'\n'"$payload"

  local key="cbs/$dependent/PR-$dependent_pr"
  echo "Uploading payload to key $key"

  # FIXME: install redis-cli in the CI image directly
  >/dev/null apt-get update -y
  >/dev/null apt-get install -y redis-server
  export REDISCLI_AUTH="$GITLAB_REDIS_AUTH"
  echo -n "$payload" | timeout 32 redis-cli \
    -u "$GITLAB_REDIS_URI" \
    -x SET "$key"
  export -n REDISCLI_AUTH
  unset REDISCLI_AUTH
}

merge_upstream() {
  local repo="$1"
  local dir="${2:-PWD}"

  local repo_url="$org_github_prefix/$repo"

  >/dev/null pushd "$dir"

  echo "Merging master of $repo_url into $repo"
  &>/dev/null git remote remove github || :
  git remote add github "$repo_url"
  git fetch --force github master
  git show-ref github/master
  if ! git merge github/master \
    --verbose \
    --no-edit \
    -m "Merge master into $repo"
  then
    die "Unable to merge master into $repo. If Git is complaining about the commit history, it probably means that the branch is more than $dependent_git_history_depth commits behind master."
  fi
  git remote remove github

  >/dev/null popd
}

# this function creates a Git branch with the dependent's source code patched to
# the previously-detected dependencies, then pushes that branch to GitLab so that
# a pipeline can be created for it
patch_and_check_dependent() {
  local dependent_repo_dir="$1"
  local this_pr_number="$2"
  local has_overridden_dependent_ref="$3"

  # Throughout this function each dependency will be saved to a separate commit
  # to be pushed to GitLab so that we'll be able to refer to them via the commit
  # hashes, as opposed to jamming all the source code into a single directory
  # and using relative paths. We've tried the latter, but it didn't work because
  # Cargo considers that all relative path dependencies within a directory
  # belong to the same workspace, which made the dependencies' Cargo.lock file
  # become ignored.
  # The intent is to build an orphan branch where each commit will contain the
  # source code of a dependency used for this check. after the branch is built,
  # it'll be pushed to gitlab so that a pipeline can be created for it, the same
  # way that a pipeline would be created for a pull request's branch after it's
  # mirrored via push.

  # Throughout this function we need to use BOTH `diener patch` as well as
  # `diener update` since Cargo doesn't always respect patches.
  # - https://github.com/rust-lang/cargo/issues/6204#issuecomment-432260143
  # - https://github.com/rust-lang/cargo/issues/6204#issuecomment-433596787
  # > [patch] simply augments a source, it doesn't force a candidate to be used
  # This is also corroborated by
  # https://gitlab.parity.io/parity/mirrors/polkadot/-/jobs/1664187#L754 which
  # shows that using [patch] alone doesn't work properly.

  # First of all we need to merge master into all branches involved in this
  # procedure. This is not only for the sake of having a more robust integration
  # which takes master's code into account, but also for making it so file
  # contents can be leveraged for knowing if the dependents' CIs can be skipped
  # during the companion merge sequence, as it'll be detailed below.
  # ---
  # For dependencies:
  # After a PR is merged into master its commit SHA will change unpredictably,
  # therefore we can't use the commit SHA to tell if the dependencies have
  # changed. Knowing if dependencies have changed is relevant for clearing one
  # of the criteria required for skipping CIs (see ./check_dependent_project_pipeline.sh)
  # throughout the merge chain in case since, if a given repository's source -
  # that is, not only its own source code, but also the source of its
  # dependencies - has been tested before as a byproduct of this check, in which
  # case it would be wasteful to run the whole CI all over again. Since the
  # commit SHA can't be used for that comparison, as a workaround we'll compare
  # the dependencies' source code by file contents instead. Herein lies another
  # problem: after the dependencies' PR lands into master, their files' contents
  # might change as a result of the merge, and those changes would get in the
  # way of our comparison. By merging master into the dependencies we'll have a
  # better guarantee that file content changes will happen less often, if at
  # all, as a result of the PR being merged into master.
  # ---
  # For the dependent:
  # processbot merges master into the companions before pushing their lockfile
  # updates, so we expect the file contents to be aligned with master by the
  # time the skip check is run
  if [ "${IS_DEPENDENT_PIPELINE:-}" ]; then
    echo "Skipping master merge as this is a dependent pipeline, therefore master should already have been merged into the relevant branches"
  elif [ "$has_overridden_dependent_ref" ]; then
    echo "Skipping master merge as the dependent repository's ref has been overridden"
  else
    merge_upstream "$this_repo" "$this_repo_dir"
  fi

  # hash repository contents before doing any patching since the patching
  # procedure modifies the files
  # note: the repository should've been merged with upstream at this point,
  # otherwise the files' hashes won't correspond to the hashes in master after
  # the PR is merged
  local this_repo_files
  this_repo_files="$(hash_git_files "$this_repo_dir")"

  # hash repository contents before doing any patching since the patching
  # procedure modifies the files
  # note: the repository should've been merged with upstream at this point,
  # otherwise the files' hashes won't correspond to the hashes in master after
  # the PR is merged
  local dependent_files
  dependent_files="$(hash_git_files "$dependent_repo_dir")"

  local patched_org_deps=()

  # Start by creating the orphan branch which will be used to run the pipeline
  # on GitLab
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  pushd "$tmp_dir" >/dev/null

  local branch_name
  if [ "${dependent_pr:-}" ]; then
    # add the PR number at the end so that check_dependent_project can also be
    # run for the dependent's PR after it's patched and sent to GitLab
    branch_name="$gitlab_dependent_branch_name-CMP$dependent_pr"
  else
    branch_name="$gitlab_dependent_branch_name"
  fi

  git init
  touch init
  git add .
  git commit -q -m "initial commit for job $CI_JOB_URL"
  git branch -m "$branch_name"
  git remote add gitlab \
    "${gitlab_url_prefix}token:${gitlab_dependent_token}@${gitlab_domain}/${gitlab_dependent_path}.git"
  local gitlab_destination="${gitlab_url_prefix}${gitlab_domain}/${gitlab_dependent_path}.git"

  # discover all the crates that we have in the current repository so that we'll
  # be able to detect if the dependent is referencing them correctly, e.g. the
  # dependent might be incorrectly referencing a deleted crate
  discover_our_crates "$this_repo_dir"

  # Detect the companions which are a dependency of dependent; e.g. when we're
  # running this script in Substrate and the dependent for this job is Cumulus,
  # a Polkadot companion should be patched inside of this dependent since
  # Cumulus depends on Polkadot
  echo "Detected companions: ${companions[*]}"
  detect_dependencies_among_companions "$dependent_repo_dir"
  echo "Detected dependencies among companions: ${dependencies_among_companions[*]}"

  if [ "${IS_DEPENDENT_PIPELINE:-}" ]; then
    echo "Skipping extra_dependencies ($extra_dependencies) as this is a dependent pipeline, therefore this branch should already be patched"
  elif [ "$has_overridden_dependent_ref" ]; then
    echo "Skipping extra_dependencies ($extra_dependencies) as the dependent repository's ref has been overridden"
  else
    # Why is $extra_dependencies necessary? For the following explanations,
    # consider the following relationship of "dependency -> dependent":
    #     Substrate -> Polkadot -> Cumulus
    # ---
    # Reason 1 is about compatibility. When a Substrate PR has a Polkadot
    # companion, but no Cumulus companion, Cumulus' master will be used; and
    # since Polkadot is a dependency of Cumulus, the Polkadot companion is
    # patched into Cumulus' master. Therefore we'd test the following
    # integration:
    #     Substrate PR + Polkadot PR + Cumulus master
    # By doing that we're confirming that the Substrate PR is compatible with
    # Cumulus' master *with* the Polkadot PR, but it *might* not be compatible
    # without it. Let's consider the case where it isn't. After the Polkadot
    # companion is merged, Cumulus' Polkadot dependency will not be updated
    # because there was no Cumulus companion; that becomes a problem because
    # Cumulus master only is compatible with Substrate because of that Polkadot
    # PR, but it was not updated to reflect that. To solve that situation we
    # should specify Polkadot as an "extra dependency" of Cumulus so that we'll
    # default to using Polkadot's master when patching, which is assumed to be
    # compatible with Substrate, instead of whatever is set in Cumulus lockfile,
    # which might not be compatible with Substrate master after a Substrate PR
    # with Polkadot companion and no Cumulus companion was merged, as explained
    # above.
    # ---
    # Reason 2 is about merge sequences. The merge sequence for our
    # "Substrate -> Polkadot -> Cumulus" dependency chain is as follows:
    #     1. Merge Substrate
    #     2. Update Substrate reference of Polkadot companion
    #     3. Merge Polkadot companion
    #     4. Update Substrate + Polkadot references of Cumulus companion
    #     5. Merge Cumulus companion
    # Let's consider that we are transitioning from Step 2 to Step 3. After
    # updating the Substrate reference, a commit will be pushed to the Polkadot
    # companion, which will make its CI run again, and therefore this script's
    # would run for the companion's "Polkadot -> Cumulus" integration job
    # (currently called check-dependent-cumulus). Since on Step 2 we have not
    # yet updated the Substrate references of the Cumulus companion (as that
    # only happens on Step 4), the Cumulus companion *might* not be compatible
    # with the Polkadot companion because its Substrate reference is outdated.
    # To solve that situation we should specify Substrate as an "extra
    # dependency" of Cumulus so that we'll default to using Substrate master
    # when patching, which is assumed to be compatible with the Polkadot
    # companion used in that job.
    for extra_dependency in $extra_dependencies; do
      if [ "$extra_dependency" = "$this_repo" ]; then
        echo "Skipping extra dependency $extra_dependency because this branch (also $this_repo) will be patched into the dependent $dependent"
        continue
      fi

      if [ "$extra_dependency" = "$dependent" ]; then
        echo "Skipping extra dependency $extra_dependency because it's being targeted as a dependent for this script"
        continue
      fi

      # check if a repository specified in $extra_dependencies but is also
      # specified as a companion, e.g. a Substrate PR whose
      # check-dependent-cumulus job specifies `EXTRA_DEPENDENCIES: polkadot` and
      # also a `polkadot companion: something` in its description; in that case
      # skip this step because that repository will be patched later
      for companion in "${dependencies_among_companions[@]}"; do
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

      >/dev/null pushd "$extra_dependencies_dir/$extra_dependency"
      local upstream_extra_dependency_commit_sha
      upstream_extra_dependency_commit_sha="$(git rev-parse HEAD)"
      >/dev/null popd
      register_used_org_dep \
        "$(hash_git_files "$extra_dependencies_dir/$extra_dependency")" \
        "$extra_dependency" \
        "$upstream_extra_dependency_commit_sha"

      replace_project_with "$extra_dependencies_dir/$extra_dependency"
      git add .
      git commit \
        -q \
        -m "commit extra dependency $extra_dependency (default branch, $upstream_extra_dependency_commit_sha)"
      local extra_dependency_commit_sha
      extra_dependency_commit_sha="$(git rev-parse HEAD)"
      echo "Pushing extra dependency $extra_dependency as commit $extra_dependency_commit_sha"
      git push --force -o ci.skip gitlab HEAD

      echo "Patching extra dependency $extra_dependency into $this_repo_dir"
      diener update \
        "--$extra_dependency" \
        --git "$gitlab_destination" \
        --rev "$extra_dependency_commit_sha" \
        --path "$this_repo_dir"
      diener patch \
        --target "$org_github_prefix/$extra_dependency" \
        --point-to-git "$gitlab_destination" \
        --point-to-git-commit "$extra_dependency_commit_sha" \
        --crates-to-patch "$extra_dependencies_dir/$extra_dependency" \
        --path "$this_repo_dir/Cargo.toml"

      echo "Patching extra dependency $extra_dependency into $dependent_repo_dir"
      diener update \
        "--$extra_dependency" \
        --git "$gitlab_destination" \
        --rev "$extra_dependency_commit_sha" \
        --path "$dependent_repo_dir"
      diener patch \
        --target "$org_github_prefix/$extra_dependency" \
        --point-to-git "$gitlab_destination" \
        --point-to-git-commit "$extra_dependency_commit_sha" \
        --crates-to-patch "$extra_dependencies_dir/$extra_dependency" \
        --path "$dependent_repo_dir/Cargo.toml"
    done
  fi

  replace_project_with "$this_repo_dir"
  git add .
  git commit -q -m "commit dependency $this_repo (PR $this_pr_number, upstream commit $CI_COMMIT_SHA)"
  local this_repo_commit_sha
  this_repo_commit_sha="$(git rev-parse HEAD)"
  echo "Pushing $this_repo as commit $this_repo_commit_sha"
  git push --force -o ci.skip gitlab HEAD

  # Patch this repository (the dependency) into the dependent for the sake of
  # being able to test how the dependency graph will behave after the merge
  echo "Patching $this_repo into $dependent"
  diener update \
    "--$this_repo" \
    --git "$gitlab_destination" \
    --rev "$this_repo_commit_sha" \
    --path "$dependent_repo_dir"
  diener patch \
    --target "$org_github_prefix/$this_repo" \
    --point-to-git "$gitlab_destination" \
    --point-to-git-commit "$this_repo_commit_sha" \
    --crates-to-patch "$this_repo_dir" \
    --path "$dependent_repo_dir/Cargo.toml"
  register_used_org_dep \
    "$this_repo_files" \
    "$this_repo" \
    "$CI_COMMIT_SHA"

  # Each companion dependency is also patched into the dependent so that the
  # dependency graph becomes how it should end up after all PRs are merged.
  for comp in "${dependencies_among_companions[@]}"; do
    if [ "$comp" = "$dependent" ]; then
      continue
    fi

    >/dev/null pushd "$companions_dir/$comp"
    local upstream_companion_commit_sha
    upstream_companion_commit_sha="$(git symbolic-ref --short HEAD)"
    >/dev/null popd
    register_used_org_dep \
      "$(hash_git_files "$companions_dir/$comp")" \
      "$comp" \
      "$upstream_companion_commit_sha"

    echo "Patching $this_repo into the $comp companion, which could be a dependency of $dependent, assuming that $comp also depends on $this_repo. Reasoning: if a companion was referenced in this PR or a companion of this PR, then it probably has a dependency on this PR, since PR descriptions are processed starting from the dependencies."
    diener update \
      "--$this_repo" \
      --git "$gitlab_destination" \
      --rev "$this_repo_commit_sha" \
      --path "$companions_dir/$comp"
    diener patch \
      --target "$org_github_prefix/$this_repo" \
      --point-to-git "$gitlab_destination" \
      --point-to-git-commit "$this_repo_commit_sha" \
      --crates-to-patch "$this_repo_dir" \
      --path "$companions_dir/$comp/Cargo.toml"

    replace_project_with "$companions_dir/$comp"
    git add .
    git commit \
      -q \
      -m "commit companion $comp (upstream commit $upstream_companion_commit_sha)"
    local companion_commit_sha
    companion_commit_sha="$(git rev-parse HEAD)"
    echo "Pushing companion $companion as commit $companion_commit_sha"
    git push --force -o ci.skip gitlab HEAD

    echo "Patching $comp companion into $dependent"
    diener update \
      "--$comp" \
      --git "$gitlab_destination" \
      --rev "$companion_commit_sha" \
      --path "$dependent_repo_dir"
    diener patch \
      --target "$org_github_prefix/$comp" \
      --point-to-git "$gitlab_destination" \
      --point-to-git-commit "$companion_commit_sha" \
      --crates-to-patch "$companions_dir/$comp" \
      --path "$dependent_repo_dir/Cargo.toml"
  done

  replace_project_with "$dependent_repo_dir"

  # Match the crates *AFTER* patching for verifying that dependencies which are
  # removed in this pull request have been pruned properly from the dependent.
  # It does not make sense to do this before patching because the dependency
  # graph then doesn't match it'll end up after merge.
  match_dependent_crates "$dependent"

  echo "Updating local crates after patching"
  update_local_crates "$gitlab_destination"

  >/dev/null pushd "$dependent_repo_dir"
  local upstream_dependent_commit_sha
  upstream_dependent_commit_sha="$(git symbolic-ref --short HEAD)"
  >/dev/null popd

  git add .
  git commit \
    -q \
    -m "commit dependent $dependent (upstream commit $upstream_dependent_commit_sha)"
  echo "Pushing dependent $dependent to GitLab as the last commit"
  git push --force -o ci.skip gitlab HEAD

  printf -v gitlab_dependent_path_encoded %s "$(echo -n "$gitlab_dependent_path" | jq -sRr @uri)"

  local gitlab_projects_api="${gitlab_url_prefix}${gitlab_domain}/api/v4/projects"

  # SKIP_DEPENDENTS: the companions detected in this PR will be tested within
  # the pipeline for this job, therefore it doesn't make sense to also test
  # inside of each dependent pipeline
  # IS_DEPENDENT_PIPELINE: signal that this job belongs to a dependent pipeline,
  # which skips some of the steps in the patching procedure in that pipeline's
  # branch is already is patched
  local pipeline_creation_payload
  pipeline_creation_payload="{
    \"ref\": $(echo -n "$branch_name" | jq -sRr @json),
    \"variables\": [
      { \"key\": \"SKIP_DEPENDENTS\", \"value\": \"${companions[*]}\" },
      { \"key\": \"IS_DEPENDENT_PIPELINE\", \"value\": \"true\" }
    ]
  }"
  echo "pipeline_creation_payload: $pipeline_creation_payload"

  local pipeline_id project_id
  local pipeline_creation_url="$gitlab_projects_api/$gitlab_dependent_path_encoded/pipeline"
  IFS=$'\n' read -d '\n' -r pipeline_id project_id < <(logged_curl \
    "$pipeline_creation_url" \
    -sSL \
    -H "PRIVATE-TOKEN: $gitlab_dependent_token" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -X POST \
    -d "$pipeline_creation_payload" | \
    jq -e -r ".id, .project_id"
  ) || :
  if [ "${pipeline_id:-null}" == null ]; then
    die "Failed to fetch pipeline id from $pipeline_creation_url"
  fi
  if [ "${project_id:-null}" == null ]; then
    die "Failed to fetch project id from $pipeline_creation_url"
  fi

  local pipeline_poll_errors=0
  local pipeline_poll_error_limit=2
  local pipeline_poll_url="$gitlab_projects_api/$project_id/pipelines/$pipeline_id"
  local pipeline_poll_delay=60
  while true; do
    IFS= read -r pipeline_status < <(logged_curl \
      "$pipeline_poll_url" \
      -sSL \
      -H "PRIVATE-TOKEN: $gitlab_dependent_token" | \
      jq -e -r ".status"
    ) || :
    if [ "$pipeline_status" ]; then
      pipeline_poll_errors=0
      case "$pipeline_status" in
        success)
          echo "Pipeline $pipeline_poll_url succeeded with status: $pipeline_status"
          if [ "${dependent_pr:-}" ]; then
            # failures are ignored for this command because we shouldn't fail
            # the job in case some external problem happens, e.g. Redis being
            # down, as the purpose of this step is merely optimization
            # TODO: connect failures here to some error reporting system so that
            # we'll be aware of this command's failures
            register_success \
              "$dependent_repo_dir" \
              "$dependent_pr" \
              "$upstream_dependent_commit_sha" \
              "$pipeline_poll_url/jobs" \
              "$dependent_files" || :
          fi
          exit 0
        ;;
        skipped|canceled|failed)
          die "Pipeline $pipeline_poll_url failed with status: $pipeline_status"
        ;;
        *)
          echo "Current pipeline status is: $pipeline_status"
        ;;
      esac
    else
      ((pipeline_poll_errors++))
      if [ "$pipeline_poll_errors" -gt $pipeline_poll_error_limit ]; then
        die "Request to $pipeline_poll_url failed more than $pipeline_poll_error_limit times"
      fi
    fi
    echo "Requesting $pipeline_poll_url again in $pipeline_poll_delay seconds..."
    sleep $pipeline_poll_delay
  done

  >/dev/null popd
}

main() {
  for skipped_dependent in ${SKIP_DEPENDENTS:-}; do
    if [ "$skipped_dependent" == "$dependent" ]; then
      echo "Skipping $dependent since it was found in \$SKIP_DEPENDENTS ($SKIP_DEPENDENTS)"
      exit 0
    fi
  done

  # Set the user name and email to make merging work
  if [ "${CI:-}" ]; then
    git config --global user.name "Companion Build System (CBS)"
    git config --global user.email "<>"
    git config --global pull.rebase false
  fi

  # process_pr_description calls itself for each companion in the description on
  # each detected companion PR, effectively considering all companion references
  # on all PRs
  process_pr_description "$this_repo" "$this_pr_number"

  local has_overridden_dependent_ref
  local dependent_repo_dir="$companions_dir/$dependent"
  if ! [ -e "$dependent_repo_dir" ]; then
    local dependent_clone_options=(
      --depth="$dependent_git_history_depth"
    )

    if [ "${pr_target_branch[$this_repo]}" == "master" ]; then
      echo "Cloning dependent $dependent directly as it was not detected as a companion"
    elif [ "${companion_branch_override[$dependent]:-}" ]; then
      echo "Cloning dependent $dependent with branch ${companion_branch_override[$dependent]} from manual override"
      dependent_clone_options+=("--branch" "${companion_branch_override[$dependent]}")
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
          elif [[ "$line" =~ ^[[:space:]]*$dependent:[[:space:]]*(.*) ]]; then
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

        echo "Detected override $this_repo_override for $this_repo and override $dependent_repo_override for $dependent"

        local base_ref_prefix="${this_repo_override_prefix:-$this_repo_override}"
        if [ "${pr_target_branch[$this_repo]::${#base_ref_prefix}}" != "$base_ref_prefix" ]; then
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

          echo "Checking if $branch_name exists in $dependent"
          local response_code
          response_code="$(curl \
            -o /dev/null \
            -sSL \
            -H "Authorization: token $github_api_token" \
            -w '%{response_code}' \
            "$github_api/repos/$org/$dependent/branches/$branch_name"
          )"

          # Sometimes the target branch found via override does not *yet* exist
          # in the companion's repository because their release processes work
          # differently; e.g. a release-v0.9.20 Polkadot branch might have a
          # polkadot-v0.9.20 matching branch (notice the version) on Substrate,
          # but not yet on Cumulus because their release approach is different.
          # When that happens, the script has no choice other than *guess* the
          # a replacement branch to be used for the inexistent branch.
          if [ "$response_code" -eq 200 ]; then
            echo "Branch $branch_name exists in $dependent. Proceeding..."
          else
            echo "Branch $branch_name doesn't exist in $dependent (status code $response_code)"
            echo "Fetching the list of branches in $dependent to find a suitable replacement..."

            # The guessing for a replacement branch works by taking the most
            # recently updated branch (ordered by commit date) which follows the
            # pattern we've matched for the branch name. For example, if
            # polkadot-v0.9.20 does not exist, instead use the latest (by commit
            # date) branch following a "polkadot-v*" pattern, which happens to
            # be polkadot-v0.9.19 as of this writing.
            local replacement_branch_name
            while IFS= read -r line; do
              echo "Got candidate branch $line in $dependent's refs"
              if [ "${line::${#dependent_repo_override_prefix}}" == "$dependent_repo_override_prefix" ]; then
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
                  "$dependent" \
                  "$dependent_repo_override_prefix"
              )" | jq -r '.data.repository.refs.edges[].node.name'
            )

            if [ "${replacement_branch_name:-}" ]; then
              echo "Choosing branch $line as a replacement for $branch_name"
              branch_name="$replacement_branch_name"
              unset replacement_branch_name
            else
              die "Unable to find the replacement for inexistent branch $branch_name of $dependent"
            fi
          fi
        else
          branch_name="$dependent_repo_override"
        fi
        dependent_clone_options+=("$branch_name")

        echo "Setting up the clone of $dependent with options: ${dependent_clone_options[*]}"
        has_overridden_dependent_ref=true

        break
      done
    fi

    git clone \
      "${dependent_clone_options[@]}" \
      "$org_github_prefix/$dependent.git" \
      "$dependent_repo_dir"

    >/dev/null pushd "$dependent_repo_dir"
    local head_sha
    head_sha="$(git rev-parse HEAD)"
    git branch -m "$head_sha"
    echo "Cloned dependent $dependent's default branch at commit $head_sha"
    >/dev/null popd

    merge_upstream "$dependent" "$dependent_repo_dir"
  fi

  # FIXME: install toml-cli in the CI image directly
  export PIP_ROOT_USER_ACTION=ignore
  python3 -m pip install -q --upgrade pip
  python3 -m pip install -q --upgrade setuptools
  python3 -m pip install -q git+https://github.com/paritytech/toml-cli.git

  patch_and_check_dependent \
    "$dependent_repo_dir" \
    "$this_pr_number" \
    "${has_overridden_dependent_ref:-}"
}
main
