---
# Pipeline Analysis - Auto Fix (agentic workflow)
#
# Companion to `pipeline-analysis-next-steps.md`. Where that workflow only *explains* a failing
# Azure DevOps CI run, this one attempts to *fix* it.
#
# Delivery model: the fix is NOT pushed onto the contributor's branch. The agent's changes are
# published to a separate `copilot-pipeline-fix/*` branch and offered as a draft pull request whose
# base is the original PR's head branch. The PR author reviews it and merges it into their own PR
# if they want it. Nothing lands without a human merge.
#
# Fork PRs are skipped by the dispatcher: the head branch lives in the fork, so a base-repo
# workflow cannot push a branch there or open a PR against it.
#
# Branches created here are cleaned up after 7 days by
# `pipeline-analysis-fix-branch-cleanup.yml`, and the draft PR auto-closes via `expires: 7`.
#
# After editing this file, run 'gh aw compile pipeline-analysis-auto-fix' to regenerate the
# lock file.
description: "Attempt an automated fix for a pull request's failing Azure DevOps pipeline and publish it as a draft PR targeting the original PR's branch."

on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull request number whose failing pipeline should be fixed"
        required: true
        type: string
      pr_head_ref:
        description: "Head branch of that pull request; the fix PR targets this branch"
        required: true
        type: string
      ci_head_sha:
        description: "Head SHA of the completed PR-CI check run, for stale-commit detection"
        required: false
        type: string

if: ${{ github.event_name == 'workflow_dispatch' }}

engine: copilot

permissions:
  contents: read
  pull-requests: read
  actions: read
  checks: read
  copilot-requests: write

network:
  allowed:
    - defaults
    - github
    - dev.azure.com
    - aka.ms
    - "*.in.applicationinsights.azure.com"

# Full checkout of the PR's head branch: unlike the analysis workflow, this agent must read and
# modify the PR's actual code.
checkout:
  ref: ${{ github.event.inputs.pr_head_ref }}

steps:
  - name: Install azsdk CLI
    shell: pwsh
    run: |
      $dir = Join-Path $HOME 'bin'
      ./eng/common/mcp/azure-sdk-mcp.ps1 -InstallDirectory $dir
      Add-Content -Path $env:GITHUB_PATH -Value $dir
  - name: Analyze failing pipeline
    shell: bash
    env:
      GITHUB_TOKEN: ${{ github.token }}
      PR_URL: "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      PR_HEAD_SHA: ${{ github.event.inputs.ci_head_sha }}
      # Fork-harness escape hatch. `azsdk ci analyze` resolves builds against the hardcoded
      # `https://dev.azure.com/azure-sdk` organization, so in a personal fork whose pipelines live
      # in a different DevOps org it can never see them and always reports "No failed Azure
      # Pipeline builds found". Setting the `PIPELINE_ANALYSIS_SOURCE_PR` repository variable to an
      # upstream PR URL points the *analysis* at a real failing Azure build while every write - the
      # checkout, the fix branch, the pull request - still happens in this repository.
      # Leave the variable unset in production: analysis then targets this repo's own PR.
      ANALYSIS_SOURCE_PR: ${{ vars.PIPELINE_ANALYSIS_SOURCE_PR }}
    run: |
      set -uo pipefail
      analysis_url="${ANALYSIS_SOURCE_PR:-$PR_URL}"
      if [ "$analysis_url" != "$PR_URL" ]; then
        echo "::notice::Harness mode - sourcing pipeline analysis from $analysis_url instead of $PR_URL."
      fi
      exit_code=0
      azsdk ci analyze "$analysis_url" > "$GITHUB_WORKSPACE/pipeline-analysis.txt" 2>&1 || exit_code=$?
      echo "azsdk ci analyze exit code: $exit_code"
      sed 's/^::/ ::/' "$GITHUB_WORKSPACE/pipeline-analysis.txt"
      if [ "$exit_code" -ne 0 ] && ! grep -qF "No failed Azure Pipeline builds found" "$GITHUB_WORKSPACE/pipeline-analysis.txt"; then
        echo "::error::azsdk ci analyze failed (exit $exit_code); failing the step."
        exit "$exit_code"
      fi

      # This repository's own failing checks, read from the GitHub Checks API rather than from
      # Azure DevOps. This works regardless of which DevOps organization the build ran in, so in
      # harness mode it is the only signal that describes a failure actually present in this
      # checkout. Appended as a clearly separated section so the agent can tell the two apart.
      {
        echo
        echo "===== Failing checks on ${GITHUB_REPOSITORY} PR #${PR_NUMBER} ====="
        gh api "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs?per_page=100" \
          --jq '.check_runs[]
                | select(.conclusion == "failure")
                | "- \(.name): \(.output.title // "no title")\n  \(.output.summary // "" | gsub("\n"; " "))\n  \(.details_url)"' \
          2>/dev/null || echo "(could not read check runs)"
      } >> "$GITHUB_WORKSPACE/pipeline-analysis.txt"

tools:
  github:
    toolsets: [context, repos, pull_requests, actions]
  edit:
  # Read commands plus the artifact download and the repo's own check runner, so the agent can
  # both diagnose and verify a formatting/lint fix before proposing it.
  bash:
    - "cat"
    - "ls"
    - "head"
    - "tail"
    - "wc"
    - "find"
    - "grep"
    - "git diff:*"
    - "git status:*"
    - "azsdk ci test-results:*"
    - "azpysdk:*"

safe-outputs:
  create-pull-request:
    title-prefix: "[pipeline-fix] "
    labels: [automated, pipeline-fix]
    draft: true
    max: 1
    # The fix PR targets the original PR's branch, so merging it lands the fix in that PR.
    base-branch: ${{ github.event.inputs.pr_head_ref }}
    # Keep generated branches under one prefix so the 7-day cleanup workflow can find them.
    allowed-branches:
      - "copilot-pipeline-fix/*"
    expires: 7
    if-no-changes: "ignore"
    fallback-as-issue: false
  noop:
    report-as-issue: false
  missing-tool:
    create-issue: false
  missing-data:
    create-issue: false
  report-incomplete:
    create-issue: false
  report-failure-as-issue: false

timeout-minutes: 30
concurrency: pipeline-analysis-auto-fix-${{ github.event.inputs.pr_number }}
---

# Pipeline Analysis - Auto Fix

You are the Azure SDK Tools **pipeline auto-fix** agent for `${{ github.repository }}`.

A CI pipeline failed on pull request **#${{ github.event.inputs.pr_number }}**. That PR's head
branch (`${{ github.event.inputs.pr_head_ref }}`) is checked out in your workspace, and a setup
step has already written the failure analysis to **`pipeline-analysis.txt`**.

Your job is to attempt a **narrow, high-confidence fix** and publish it as a draft pull request
targeting that branch. You are not merging anything - the PR author decides.

## Step 0 - Read the analysis and decide whether to act

1. Read `pipeline-analysis.txt`. It has up to two parts: the `azsdk ci analyze` output, and a
   trailing `===== Failing checks on <repo> PR #<n> =====` section listing this PR's own failing
   checks from the GitHub Checks API.
   - **Harness mode.** If the run log said `Harness mode - sourcing pipeline analysis from ...`,
     the `azsdk` part describes a build in a *different* repository, because `azsdk` can only read
     the `dev.azure.com/azure-sdk` organization. Treat it as reference material only. Fix it **only
     if the identical defect demonstrably exists in this checkout** - verify by opening the file
     before changing it. Otherwise base your fix on the trailing local-checks section, which is the
     part that describes this repository.
   - **In harness mode you must still produce a fix.** The local-checks section is authoritative.
     Do **not** `noop` merely because the upstream `azsdk` defect is absent from this checkout -
     that is the expected case. Find the local cause and fix it. Concretely: if a stage named
     `Analyze` failed and a file named `ci-fail-marker.txt` exists at the repository root, that
     marker file *is* the failure (`test-trigger-pipeline.yml` fails the stage whenever it is
     present) - delete it and publish that as the fix.
2. If it is empty, contains `No failed Azure Pipeline builds found` with no usable local-checks
   section, or shows no real failure, use the `noop` safe output and stop. In harness mode, treat
   `noop` as a last resort: only take it if you genuinely cannot identify any local cause.
3. Stale-commit guard: if `${{ github.event.inputs.ci_head_sha }}` is non-empty, compare it with
   the PR's current head SHA. If they differ, the run is for a superseded commit - `noop` and stop.
4. **Only proceed if the failure is deterministically fixable from the repository itself** -
   formatting, linting, a changelog or README validation error, a spelling failure, a missing
   import, a stale snippet. If the failure is a flaky test, an infrastructure/auth error, a live
   test, or anything whose root cause you cannot see in the code, use `noop` and stop. A wrong fix
   is worse than none.

## Step 1 - Understand the failure

Consult the repository's skills before changing anything. **Read every `SKILL.md` with the `view`
tool, not with `cat`** - the Copilot `PostToolUse` telemetry hook only recognizes skill invocations
from the `view`/`read_file` tools, so a shell read is not counted.

- Read `.github/skills/azsdk-common-pipeline-analysis/SKILL.md` and its
  `references/failure-patterns.md` for the failure categories and pattern-to-fix mappings.
- If a skill under `.github/skills/` describes how to fix this specific failure, read its
  `SKILL.md` with `view` and follow it.
- If `pipeline-analysis.txt` only names artifacts and you need their contents, run:
  `azsdk ci test-results "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"`
- If `${{ github.repository }}` is `Azure/azure-rest-api-specs`, also read
  `documentation/ci-fix.md` and prefer its documented local commands. It does not exist in other
  repositories - skip it there.

## Step 2 - Make the smallest fix that addresses the reported failure

- Change only what the failure requires. Do not reformat unrelated files, bump versions, or
  refactor.
- Never modify CI configuration, pipeline YAML, or `eng/` tooling to make a check pass.
- Where the repo offers a deterministic fixer, prefer it over hand-editing (for example
  `azpysdk black <target>` for Python formatting).
- Verify your change where you cheaply can (re-run the same lint/format command) and say in the PR
  body exactly what you ran and what it reported. If you could not verify locally, say that
  plainly instead of implying it is proven.

## Step 3 - Publish the fix

Emit exactly one `create-pull-request` safe output.

- Use a source branch named `copilot-pipeline-fix/pr-${{ github.event.inputs.pr_number }}`.
- Title: a one-line summary of the fix.
- Body must contain:
  - which pipeline check failed, with the Azure DevOps build link from the analysis;
  - the root cause in one or two sentences;
  - what you changed and why it addresses that specific failure;
  - what you ran to verify, or an explicit statement that it is unverified;
  - a closing note that this PR targets `${{ github.event.inputs.pr_head_ref }}` and that merging
    it applies the fix to PR #${{ github.event.inputs.pr_number }}.

## Constraints (non-negotiable)

1. **One PR, targeting the contributor's branch.** Never push directly to
   `${{ github.event.inputs.pr_head_ref }}`, and never open a PR against the default branch.
2. **No speculative fixes.** If you are not confident the change addresses the reported failure,
   `noop`. Silence is an acceptable outcome; a plausible-looking wrong patch is not.
3. **Ground every claim in `pipeline-analysis.txt` or in output you actually produced.** Do not
   assert that a check now passes unless you ran it and saw it pass.
4. **Do not touch** CI/pipeline definitions, `eng/`, secrets, or dependency lock files to force a
   check green.
5. Do not use `gh` or GitHub write APIs directly - publishing happens only through the
   `create-pull-request` safe output.
