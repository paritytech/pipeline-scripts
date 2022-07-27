# Companion Build System Dependent Check V2

**Demonstrations**

Cumulus integration
  - check-dependent-cumulus: https://gitlab.parity.io/parity/mirrors/substrate/-/jobs/1701832
  - Patched branch: https://gitlab.parity.io/parity/mirrors/cumulus/-/commits/3f68bccfbbc22a5b1ef7d047739da784b6ddf4c2/
  - Pipeline: https://gitlab.parity.io/parity/mirrors/cumulus/-/pipelines/204815

Polkadot integration
  - check-dependent-polkadot: https://gitlab.parity.io/parity/mirrors/substrate/-/jobs/1701831
  - Patched branch: https://gitlab.parity.io/parity/mirrors/polkadot/-/commits/52f1f7a0803dd85b52cdce14ad30f8943b3f4f59/
  - Pipeline: https://gitlab.parity.io/parity/mirrors/polkadot/-/pipelines/204813

# TOC

- [Introduction](#introduction)
- [Summary](#summary)
  - [Patched code](#summary-patched-code)
  - [What is tested by the check](#summary-what-is-tested)
- [Example scenario: Substrate -> Polkadot -> Cumulus](#s-p-c-example)
  - [Walkthrough](#s-p-c-example-walkthrough)
    - [Old](#s-p-c-example-walkthrough-old)
    - [New](#s-p-c-example-walkthrough-new)
  - [Aftermath](#s-p-c-example-aftermath)
- [Setup](#setup)
- [Future work](#future-work)

# Introduction <a name="introduction"></a>

This document focuses on the "how", but not the "why", behind the upcoming
changes to the Companion Build System Dependent Check (namely
`./check_dependent_project.sh`).

We suggest to start by this document to gain an understanding of the system's
intended behavior - the "how". The code itself has comments explaining the
decision-making behind its features - the "why".

Note: The scope for the upcoming changes was built according to the plan of
"Deliverable 1" and "Deliverable 2" of
https://github.com/paritytech/ci_cd/issues/234#issuecomment-1160141699.

# Summary <a name="summary"></a>

The system has the same goals as the previous one, but it differs how the
patched code is used and what is tested by the check.

To know how it's supposed to work in practice read both the
([example scenario](#substrate-polkadot-cumulus-example)) as well as its
([aftermath](#substrate-polkadot-cumulus-aftermath)). The intention of this document is not to explain the decision behind how it works

### Patched code <a name="summary-patched-code"></a>

**Before** we `cargo check` for the patched code directly inside of the CI job.

**Now** we'll instead commit the patched code to a branch which will be pushed
to GitLab for running the full pipeline for a given dependent.

---

A noteworthy side-effect of this change is that **before** we were cloning all
the projects into a single local directory, which resulted in them being patched
as relative *path dependencies*. This transformation unintentionally made all
projects become part of the same workspace for Cargo, as described in
https://doc.rust-lang.org/cargo/reference/workspaces.html#the-workspace-section.

> All path dependencies residing in the workspace directory automatically become members.

That Cargo feature made the Cargo.lock of some projects be disregarded since
only one Cargo.lock is considered per workspace. This behavior sometimes
obscured problem which wouldn't be caught easily until the merge went through.

**Now** we're referring to each dependency by their commit hashes, which means
that all Cargo.lock files used within the patching procedure are properly
considered and should be valid in tandem.

### What is tested by the check <a name="summary-what-is-tested"></a>

Before we were limited to `cargo check`

# Example scenario: Substrate -> Polkadot -> Cumulus <a name="s-p-c-example"></a>

## Walkthrough <a name="s-p-c-example-walkthrough"></a>

This scenario is triggered when a Substrate PR refers to Polkadot and Cumulus
companions in its description, e.g.

```
polkadot companion: polkadot#123
cumulus companion: cumulus#123
```

Conditions:

- The check is running for a Substrate PR
- The Substrate PR has a Polkadot companion: `polkadot#123`
- The Substrate PR has a Cumulus companion: `cumulus#123`
- The CI job we're running is `check-dependent-cumulus`, i.e. we're testing the
  *direct* integration between Substrate and Cumulus; however, since a Polkadot
  companion is specified, and Polkadot is a dependency of Cumulus, the Polkadot
  companion is taken into account for this check

The above conditions constitute the most complex scenario we have available
currently. Simpler scenarios follow the same flow as this one, but with less
steps.

## Old <a name="s-p-c-example-walkthrough-old"></a>

1. Detect companions from PR description
  - 1.1. Detect Polkadot companion
    - 1.1.1. Clone Polkadot companion
    - 1.1.2. Merge master into Polkadot companion
  - 1.2. Detect Cumulus PR
    - 1.2.1. Clone Cumulus companion
    - 1.2.2. Merge master into Cumulus companion
2. By this point we've either cloned the dependents' repositories from the
  companion PRs or the default branches in case companions aren't found
3. Patch the dependencies into the dependents
  - 3.1. Patch Substrate into Polkadot
  - 3.2. Patch Polkadot into Cumulus
4. Run `cargo check`

## New <a name="s-p-c-example-walkthrough-new"></a>

1. Detect companions from PR description
  - 1.1. Detect Polkadot companion
    - 1.1.1. Clone Polkadot companion
    - 1.1.2. Merge master into Polkadot companion
  - 1.2. Detect Cumulus PR
    - 1.2.1. Clone Cumulus companion
    - 1.2.2. Merge master into Cumulus companion
2. By this point we've either cloned the dependents' repositories by companion
  PRs or the default branches in case companions aren't found
3. [NEW] Start branch for the dependent's patched code (which will be later
  pushed to GitLab)
4. [CHANGED] Patch the dependencies into the dependents
  ([example](https://gitlab.parity.io/parity/mirrors/cumulus/-/commits/cbs-145-PR11765-CMP1408))
  - 4.1. Create commit for Substrate
  - 4.2. Patch Substrate (commit from Step 4.1) into Polkadot
  - 4.3. Create commit for Polkadot
  - 4.4. Patch Polkadot (commit from Step 4.3) into Cumulus
  - 4.4. Create commit for Cumulus
5. [NEW] Push the patched branch to GitLab and create a pipeline for it
  ([example](https://gitlab.parity.io/parity/mirrors/cumulus/-/pipelines/204815))
6. [NEW] Wait for the created pipeline to finish
  - 6.1. In case the pipeline succeeds, save the check's data to Redis so that it
  can be leveraged to potentially skip the companion's pipelines after they're
  merged
  ([example](https://gitlab.parity.io/parity/mirrors/cumulus/-/jobs/1699311/artifacts/browse/artifacts/cbs/passed-jobs)).
7. [NEW] The job succeeds in case the the created pipeline succeeded, otherwise
  it fails

## Aftermath <a name="s-p-c-example-aftermath"></a>

Continuing from Step 6.1 of [the new walkthrough](#s-p-c-walkthrough-new), what
happens after the dependents' pipelines succeed? The answer is that their
corresponding job on Substrate, which created the pipeline, will succeed, which
leads into the Substrate PR becoming ready to merge. After that, if we say `bot
merge` on the Substrate PR:

1. Substrate PR is merged
2. A commit is pushed to update the companion's reference to the master of
  Substrate, **which makes CI run again**

Note that we've already run the companion's CI once during the Substrate
pipeline, in Step 5 of [the new walkthrough](#s-p-c-walkthrough-new). For that
reason it's desirable to rely on heuristics for *potentially* avoiding a second
redundant run of the pipeline in case the source code resulting from the
patching procedure remains the same after the companion is updated. It's
important to emphasize that this idea is an **optimization** and not essential
to the quality or functionality of the check.

Because the dependencies' master HEAD SHA changes after the dependencies' PRs
are merged into master, we're unable to rely on a straightforward commit SHA
comparison based on the companions' updated Cargo.lock references. For this
reason the heuristics for skipping the pipeline should rely on file contents
rather than the referenced commit SHAs.

# Setup <a name="setup"></a>

Each dependent will require a GitLab Access Token, to be provided through
`--gitlab_dependent_token`, with the following scopes:

- `write_repository` so that the dependency's job is able push the patched
  branch before creating the dependent's pipeline
- `api` so that the dependency's job can create pipelines

This token should have access to the repositories where the branches will be
pushed to, i.e. the dependent's repositories.

We recommend the following procedures for the token

- Create it only for the repositories in which the token needs to be used, i.e.
  one per project instead of one per group
- Create it with the minimal role which is able to push branches to
  the repository where it's used; as of this writing it's the `Developer` role.
- Restrict pushes to important branches in the project to the `Maintainer` role
  such that the `Developer` token won't be able to push to them.

# Future work <a name="future-work"></a>

- Take care of TODOs in the code
- Improve failure awareness for the pipeline skipping optimizations, as it can
  fail for the wrong reasons
- Design the integration of this approach with pre-merge pipelines
  - Is it worthwhile to do this?
    https://forum.parity.io/t/companion-build-system-cbs-vs-cargo-unleash-development-wise/1041
    might be of interest to this question
