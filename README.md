# Introduction

This repository hosts reusable scripts (that is, scripts which are useful for
many repositories) for our CI pipelines.

# TOC

- [check_dependent_project](#check_dependent_project)
  - [Usage](#check_dependent_project-usage)
  - [Explanation](#check_dependent_project-explanation)
  - [Implementation](#check_dependent_project-implementation)

# check_dependent_project <a name="check_dependent_project"></a>

## Usage <a name="check_dependent_project-usage"></a>

Specify companions in the description of a pull request. For example, if you
have a pull request which needs a Polkadot companion, say:

```
polkadot companion: [link]
```

The above tells the integration checks to test the pull request's branch with
the specified PR rather than the default branch for that companion's repository.

---

On pull requests **which don't target master** you're able to specify the
companion's branch in their description:

```
polkadot companion branch: [branch]
```

The above tells the script to use the specified branch in `${ORG}/polkadot`
rather than the default branch for that companion's repository.

Alternatively, you can also specify a permanent override configuration through
`--companion-overrides`. Suppose the following:

```bash
check_dependent_project.sh \
  --companion-overrides "
    substrate: polkadot-v*
    polkadot: release-v*
  "
```

The above configures the script to use, for example, the `release-v1.2` Polkadot
branch for the companion in case the Substrate pull request is **targetting**
the `polkadot-v1.2` branch - note how the suffix captured from the wildcard
pattern, namely `1.2` from the pattern `*`, is correlated between those refs.
This feature exists for release engineering purposes (more context in
[issue 32](https://github.com/paritytech/pipeline-scripts/issues/32)).

## Explanation <a name="check_dependent_project-explanation"></a>

[check_dependent_project](./check_dependent_project.sh) implements the
[Companion Build System](https://github.com/paritytech/parity-processbot/issues/327)'s
cross-repository integration checks as a CI status. Currently the checks are
limited to API breakages by `cargo check`, although that is
[known to be insufficient](https://github.com/paritytech/ci_cd/issues/234).

[parity-processbot](https://github.com/paritytech/parity-processbot) takes the
status of this check into account in order to go forward (in case of success) or
stop (in case of failure) the merge process.

Although both check_dependent_project and parity-processbot play a role in the
[Companion Build System](https://github.com/paritytech/parity-processbot/issues/327),
they are not coupled to each other: check_dependent_project's status is not
treated specially. Although it is
[required](https://github.com/paritytech/parity-processbot#1-required), it is as
relevant as any other status of equal importance; i.e. parity-procesbot does not
differentiate statuses individually, but by their overall priority. Effectively
it means that even if check_dependent_project's would be removed or refactored,
parity-processbot's internal logic would not be affected because
check_dependent_project is merely yet another CI check.

## Implementation <a name="check_dependent_project-implementation"></a>

### Step 1: Set a dependent repository to be targeted for the current job

Received as a CLI input named
[`$dependent_repo`](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L36).

### Step 2: Detect all dependents

[Start by detecting all dependents in the current pull request](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L385-L388).
For each dependent PR found,
[also search their descriptions](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L277)
for more dependents. Note: The script does some
[internal bookkeeping](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L203)
for avoiding potentially-cyclic references.

It is important that all dependents are collected from all PR descriptions for
the sake of patching **all** of their dependencies before the check starts. For
instance, suppose that you specify a Polkadot companion in a Substrate PR and a
Cumulus companion in that Polkadot companion (Substrate -> Polkadot -> Cumulus).
If the scripts were to consider **only** companions referenced **directly** in
the Substrate PR, the dependency chain would be inferred as follows (observe
that the "Substrate -> Cumulus" link is missing because it is not referenced
directly):

- Substrate -> Polkadot
- Polkadot -> Cumulus

If that were to happen the "Substrate -> Cumulus" integration would fail because
Cumulus' reference would not be detected (it is not a **direct** reference) and
therefore it would not be patched properly before the check (it depends on the
Polkadot PR, hence why it is a companion in the first place). In other words,
even indirect dependencies, which are on referenced on other pull requests,
should be taken into account.

### Step 3: Resolve the target from `$dependent_repo`

From the dependents detected in the previous step, find those which come from
`$dependent_repo`.
[If it is found, clone it](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L250);
otherwise,
[clone the current `master` of the `$dependent_repo`](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L392) -
this comes from the understanding that if the PR does not specify a companion,
it should be compatible with the current `master` of `$dependent_repo`, whatever
that is at the time.

### Step 4: Patch everything

The patching method replaces, in the companions, all references to the PR's
repository with references to the PR's branch where the check is running.

For each direct dependent (that is, ones which match `$dependent_repo`),
[first patch its dependencies](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L339),
otherwise they might not build (and that is another reason why it's important to
consider all companions in the description, not only the ones from
`$dependent_repo`). After patching the dependencies,
[patch the dependent itself](https://github.com/paritytech/pipeline-scripts/blob/f84c9cc35a2db11b1b77c21ff9a49f47ec31b298/check_dependent_project.sh#L353).

### Step 5: Execute the check

By this point all dependents (and their dependencies) have been patched already,
therefore the check should at the very least guarantee that there aren't API
incompatibilities between the current branch and `$dependent_repo`, otherwise
typechecking would fail.

The check is currently limited to `cargo check` but optimally it should
[entail the whole CI pipeline of `$dependent_repo`](https://github.com/paritytech/ci_cd/issues/234).
