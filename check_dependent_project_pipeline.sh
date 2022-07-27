#!/usr/bin/env bash

# This script checks if a PR, for which the dependent pipeline has been run
# before (./check_dependent_project.sh), can be skipped based on data stored on
# Redis.

# We are unable to decide on whether to skip or not based on dependencies'
# commit SHAs alone because their master's HEAD commit SHA is not the same as
# the PRs' commit SHAs using during the patching procedure. Since commit SHAs
# can't be relied upon, we instead compare the dependencies by their file
# contents and permission bits.

# After validating that a pipeline has already passed for this PR, this script
# creates files for each passed job within --artifacts-path. Those files can be
# used within subsequent jobs to hint at if they need to be run again or not.

set -eu -o pipefail

. "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

if [[
  # PRs mirrored to GitLab
  "${CI_COMMIT_REF_NAME:-}" =~ ^[[:digit:]]+$
]]; then
  this_pr_number=$CI_COMMIT_REF_NAME
else
  echo "\$CI_COMMIT_REF_NAME was not recognized as a pull request ref: ${CI_COMMIT_REF_NAME:-}"
  exit 0
fi

get_arg required --artifacts-path "$@"
artifacts_path="$out"

tmp_files=()
cleanup() {
  exit_code=$?
  rm -rf "${tmp_files[@]}"
  exit $exit_code
}
trap cleanup EXIT

git_dir="$PWD/.git"
cloned_repositories="$git_dir/cbs/cloned_repositories"
tmp_files+=("$cloned_repositories")

get_pr_info_field() {
  local prefix="$1"
  local field="$2"
  echo -n "$pr_info" | jq -r --arg prefix "$prefix" ".dependencies | .[\"$prefix\"] | .$field"
}

validate_repository() {
  local repository="$1"
  local current_sha="$2"
  local patched_sha="$3"
  local patched_sha_files="$4"
  local dir="${5:-$PWD}"

  echo "Comparing files of $repository at commit sha $current_sha with what was used during the patching procedure (commit sha $patched_sha merged with master)"

  local patched_items=()
  while IFS= read -r line; do
    if ! [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      die "Line of patched items had unexpected format: $line"
    fi
    local mode="${BASH_REMATCH[1]}"
    local hash="${BASH_REMATCH[2]}"
    local file="${BASH_REMATCH[3]}"
    echo "Parsed mode $mode, hash $hash, file $file from patched files line: $line"

    patched_items+=("$file" "$mode" "$hash")
  done < <(echo "$patched_sha_files")

  while IFS= read -r line; do
    if ! [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      die "Line of current items unexpected format: $line"
    fi
    local mode="${BASH_REMATCH[1]}"
    local hash="${BASH_REMATCH[2]}"
    local file="${BASH_REMATCH[3]}"
    echo "Parsed mode $mode, hash $hash, file $file from current files line: $line"

    local found
    for ((i=0; i < ${#patched_items[@]}; i+=3)); do
      local patched_file="${patched_items[$i]}"
      if [ "$file" != "$patched_file" ]; then
        continue
      fi

      local patched_mode="${patched_items[$((i+1))]}"
      if [ "$patched_mode" != "$mode" ]; then
        die "File changed its mode from $patched_mode to $mode: $file"
      fi

      local patched_hash="${patched_items[$((i+2))]}"
      if [ "$hash" != "$patched_hash" ]; then
        die "File changed its hash from $patched_hash to $hash: $file"
      fi

      found=true
      break
    done

    if [ "${found:-}" ]; then
      unset found
    else
      die "File was not found within the patched files: $file"
    fi
  done < <(hash_git_files "$dir")
}

validate_previous_pipeline() {
  local pr_info="$1"

  validate_repository \
    "$CI_PROJECT_NAME" \
    "$CI_COMMIT_SHA" \
    "$(echo -n "$pr_info" | jq -r ".dependent | .sha")" \
    "$(echo -n "$pr_info" | jq -r ".dependent | .files")"

  local cbs_dependencies_prefixes
  readarray -t cbs_dependencies_prefixes <<< "$(echo -n "$pr_info" | jq -r '.dependencies | keys | .[]')"

  local used_cbs_dependencies_prefixes=()
  local name version source

  local nonpatched_dependencies=()
  local next=name
  while IFS= read -r line; do
    case "$next" in
      name)
        name="$line"
        next=version
      ;;
      version)
        version="$line"
        next=source
      ;;
      source)
        source="$line"
        next=name

        for cbs_dependency_prefix in "${cbs_dependencies_prefixes[@]}"; do
          if [ "${source::${#cbs_dependency_prefix}}" != "$cbs_dependency_prefix"  ]; then
            continue
          fi

          local prefix="$cbs_dependency_prefix"
          local sha="${source:${#cbs_dependency_prefix}}"

          for ((i=0; i < ${#used_cbs_dependencies_prefixes[*]}; i+=2)); do
            local used_prefix="${used_cbs_dependencies_prefixes[$i]}"
            if [ "$used_prefix" == "$prefix" ]; then
              local used_sha="${used_cbs_dependencies_prefixes[$((i+1))]}"
              if [ "$used_sha" != "$sha" ]; then
                die "Dependency sources for prefix \"$prefix\" are different: found one which ends with \"$used_sha\" and another which ends with \"$sha\"."
              fi
            fi
          done

          used_cbs_dependencies_prefixes+=("$prefix" "$sha")
          continue 2
        done

        nonpatched_dependencies+=("$name" "$version" "$source")
      ;;
    esac
  done < <(toml get --toml-path Cargo.lock | \
    jq -r "
      .package |
      .[] |
      [ .name, .version, .source ] |
      .[]
    "
  ) || :

  local next=name
  while IFS= read -r line; do
    case "$next" in
      name)
        name="$line"
        next=version
      ;;
      version)
        version="$line"
        next=source
      ;;
      source)
        source="$line"
        next=name

        for ((i=0; i < ${#used_cbs_dependencies_prefixes[*]}; i+=2)); do
          local prefix="${used_cbs_dependencies_prefixes[$i]}"
          if [ "${source::${#prefix}}" == "$prefix" ]; then
            echo "Dependency $name $version (from $source) will not be matched because its prefix is \"$prefix\", which was used for a dependency patch"
            continue 2
          fi
        done

        local found
        for ((i=0; i < ${#nonpatched_dependencies[*]}; i+=3)); do
          local our_dep_name="${nonpatched_dependencies[$i]}"
          if [ "$our_dep_name" != "$name" ]; then
            continue
          fi

          local our_dep_version="${nonpatched_dependencies[$((i+1))]}"
          if [ "$our_dep_version" != "$version" ]; then
            continue
          fi

          local our_dep_source="${nonpatched_dependencies[$((i+2))]}"
          if [ "$our_dep_source" != "$source" ]; then
            continue
          fi

          found=true
          break
        done

        if [ "${found:-}" ]; then
          unset found
        else
          local msg="The following crate was not found in \$pr_info's packages"
          msg+=$'\n'"Name: $name"
          msg+=$'\n'"Version: $version"
          msg+=$'\n'"Source: $source"
          die "$msg"
        fi
      ;;
    esac
  done < <(echo -n "$pr_info" | \
    jq -r "
      .cargo_lock |
      .package |
      .[] |
      [ .name, .version, .source ] |
      .[]
    "
  ) || :

  for ((i=0; i < ${#used_cbs_dependencies_prefixes[*]}; i+=2)); do
    local prefix="${used_cbs_dependencies_prefixes[$i]}"
    local sha="${used_cbs_dependencies_prefixes[$((i+1))]}"

    local repository
    repository="$(get_pr_info_field "$prefix" repository)"

    local cloned_repository="$cloned_repositories/$repository/$sha"
    if ! [ -e "$cloned_repository" ]; then
      mkdir -p "$cloned_repository"
    fi

    local url
    url="$(get_pr_info_field "$prefix" url)"
    >/dev/null pushd "$cloned_repository"
    curl -sSL "$url" | tar xz --strip=1
    # initialize the downloaded folder as a git repository because GitHub
    # archives don't include the .git folder
    git init --quiet
    git add .
    git commit -q -m "$sha"
    >/dev/null popd

    validate_repository \
      "$repository" \
      "$sha" \
      "$(get_pr_info_field "$prefix" sha)" \
      "$(get_pr_info_field "$prefix" files)" \
      "$cloned_repository"
  done
}

register_success() {
  local pr_info="$1"

  local jobs_url
  jobs_url="$(echo -n "$pr_info" | jq -r ".jobs")"

  local passed_jobs_dir="$artifacts_path/cbs/passed-jobs"
  mkdir -p "$passed_jobs_dir"
  while IFS= read -r passed_job; do
    touch "$passed_jobs_dir/$passed_job"
  done < <(curl -sSL "$jobs_url" | jq -r '.[] | select(.status=="success") | .name')
}

main() {
  if [ "${CI:-}" ]; then
    git config --global user.name "Companion Build System (CBS)"
    git config --global user.email "<>"
    git config --global pull.rebase false
  fi

  local pr_info_key="cbs/$CI_PROJECT_NAME/PR-$this_pr_number"
  echo "Fetching pr_info from $pr_info_key"

  # FIXME: install redis-cli in the CI image directly
  >/dev/null apt-get update -y
  >/dev/null apt-get install -y redis-server
  export REDISCLI_AUTH="$GITLAB_REDIS_AUTH"

  local pr_info
  pr_info="$(timeout 32 redis-cli -u "$GITLAB_REDIS_URI" GET "$pr_info_key")"

  if [ "$pr_info" ]; then
    echo "pr_info: $pr_info"
  else
    die "pr_info is empty"
  fi

  # FIXME: install toml-cli in the CI image directly
  export PIP_ROOT_USER_ACTION=ignore
  python3 -m pip install -q --upgrade pip
  python3 -m pip install -q --upgrade setuptools
  python3 -m pip install -q git+https://github.com/paritytech/toml-cli.git

  validate_previous_pipeline "$pr_info" && register_success "$pr_info"

  export -n REDISCLI_AUTH
}

main
