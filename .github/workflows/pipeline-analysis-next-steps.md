---
# Pipeline Analysis - Next Steps (agentic workflow)
#
# When a pull request's Azure DevOps CI fails, `pipeline-analysis-next-steps-trigger.yml`
# dispatches this workflow with the PR number. A deterministic setup step runs the existing `azsdk ci analyze` tool to produce structured failure data; the Copilot
# agent then turns that into a concise, human-readable "Pipeline Analysis Next Steps" comment on the PR.
#
# Copilot runs on the built-in token via `copilot-requests: write` (billed to the org) # The agent job is read-only; the comment is posted by a separate
# gh-aw safe-outputs job.
#
# After editing this file, run 'gh aw compile pipeline-analysis-next-steps' to regenerate the
# lock file.
description: "Analyze a pull request's failing Azure DevOps pipeline with the azsdk analyze tool and post a Copilot-authored 'Pipeline Analysis Next Steps' comment."

on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: "Pull request number whose failing pipeline should be analyzed"
        required: true
        type: string
      ci_conclusion:
        description: "Conclusion of the completed azure-pipelines PR-CI check run (e.g. failure) for CI-triggered runs"
        required: false
        type: string
      ci_head_sha:
        description: "Head SHA of the completed PR-CI check run, for stale-commit detection on CI-triggered runs"
        required: false
        type: string

# The workflow is always dispatched (by the trigger workflow or manually); never runs off the
# repository-associated PR of its own ref.
if: ${{ github.event_name == 'workflow_dispatch' }}

engine: copilot

# Agent job runs read-only; copilot-requests:write bills the Copilot CLI usage to the org. The
# separate safe-outputs job receives the pull-requests:write scope it needs to post the comment.
permissions:
  contents: read
  pull-requests: read
  actions: read
  checks: read
  copilot-requests: write

# network.allowed also governs content sanitization: dev.azure.com and aka.ms must be allowed
# so the Azure DevOps build links and the CI-fix link in the analysis survive in the comment.
network:
  allowed:
    - defaults
    - github
    - dev.azure.com
    - aka.ms

# Only the base-branch `eng/` tree is needed to install the azsdk CLI. No PR code is checked
# out or executed; the analysis works entirely off the PR/build data fetched by the tool.
# `documentation/` is included so that in `Azure/azure-rest-api-specs` the agent can read that
# repository's `ci-fix.md` troubleshooting guide; the pattern matches nothing elsewhere.
checkout:
  sparse-checkout: |
    eng
    documentation

# Deterministic pre-agent steps: install the azsdk CLI (the analyze tool is a plain stdio MCP
# server that gh-aw's MCP Gateway cannot host, so we drive its CLI surface) and run the
# analysis into a workspace file for the agent to read.
steps:
  - name: Install azsdk CLI
    shell: pwsh
    run: |
      $dir = Join-Path $env:RUNNER_TEMP 'azsdk-cli'
      ./eng/common/mcp/azure-sdk-mcp.ps1 -InstallDirectory $dir
      Add-Content -Path $env:GITHUB_PATH -Value $dir
  - name: Analyze failing pipeline
    shell: bash
    env:
      GITHUB_TOKEN: ${{ github.token }}
      PR_URL: "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      PR_HEAD_SHA: ${{ github.event.inputs.ci_head_sha }}
      # Fork-harness escape hatch; see pipeline-analysis-auto-fix.md for the full rationale.
      # `azsdk ci analyze` only resolves builds in the hardcoded `dev.azure.com/azure-sdk` org, so
      # a fork whose pipelines live elsewhere gets "No failed Azure Pipeline builds found". Setting
      # the `PIPELINE_ANALYSIS_SOURCE_PR` repository variable sources the analysis from an upstream
      # PR instead; the comment is still posted on this repository's PR. Unset in production.
      ANALYSIS_SOURCE_PR: ${{ vars.PIPELINE_ANALYSIS_SOURCE_PR }}
    run: |
      set -uo pipefail
      analysis_url="${ANALYSIS_SOURCE_PR:-$PR_URL}"
      if [ "$analysis_url" != "$PR_URL" ]; then
        echo "::notice::Harness mode - sourcing pipeline analysis from $analysis_url instead of $PR_URL."
      fi
      # `azsdk ci analyze` exits non-zero both when it finds no failing builds (it sets a
      # "No failed Azure Pipeline builds found ..." response error) and on real auth/network/CLI
      # errors. Only the former is an acceptable no-op; every other non-zero exit must fail this
      # step so the run surfaces the problem instead of the agent silently treating an error as
      # "nothing to report" and finishing green.
      exit_code=0
      # Record the URL the analysis was actually sourced from. The agent needs it verbatim to
      # fetch artifact contents later, and in harness mode it is not this repository's PR URL.
      echo "===== Analysis source: $analysis_url =====" > "$GITHUB_WORKSPACE/pipeline-analysis.txt"
      azsdk ci analyze "$analysis_url" >> "$GITHUB_WORKSPACE/pipeline-analysis.txt" 2>&1 || exit_code=$?
      echo "azsdk ci analyze exit code: $exit_code"
      echo "----- pipeline-analysis.txt -----"
      # The file holds PR-controlled build output. Prefix any line that looks like a GitHub
      # Actions workflow command (starts with `::`) with a space so it is logged as plain text
      # instead of being interpreted.
      sed 's/^::/ ::/' "$GITHUB_WORKSPACE/pipeline-analysis.txt"
      if [ "$exit_code" -ne 0 ]; then
        if grep -qF "No failed Azure Pipeline builds found" "$GITHUB_WORKSPACE/pipeline-analysis.txt"; then
          echo "No failing Azure Pipeline builds resolved for this PR; the agent will no-op."
        else
          echo "::error::azsdk ci analyze failed (exit $exit_code) with an unexpected error; failing the step."
          exit "$exit_code"
        fi
      fi

      # This repository's own failing checks, read from the GitHub Checks API rather than from
      # Azure DevOps. This works regardless of which DevOps organization the build ran in, so in
      # harness mode it is the only signal describing a failure actually present on this PR.
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
  # Read-only apart from `azsdk ci test-results`, which fetches pipeline artifact contents.
  bash: ["cat", "ls", "head", "tail", "wc", "azsdk ci test-results:*"]

safe-outputs:
  # A single, self-updating "Pipeline Analysis Next Steps" comment on the PR. hide-older-comments
  # collapses this workflow's previous comments so only the latest analysis stays visible.
  add-comment:
    max: 1
    target: "${{ github.event.inputs.pr_number }}"
    hide-older-comments: true
  # Let the agent cleanly do nothing when the tool reports no failing builds. report-as-issue:
  # false stops gh-aw's default of opening/updating an "[aw] No-Op Runs" tracking issue on every
  # stale/no-failure run.
  noop:
    report-as-issue: false
  # Failures surface on the PR/run; do not open tracking issues.
  missing-tool:
    create-issue: false
  missing-data:
    create-issue: false
  report-incomplete:
    create-issue: false
  report-failure-as-issue: false

timeout-minutes: 20
concurrency: pipeline-analysis-next-steps-${{ github.event.inputs.pr_number }}
---

# Pipeline Analysis - Next Steps

You are the Azure SDK Tools **pipeline next-steps** agent for `${{ github.repository }}`.

A CI pipeline failed on pull request **#${{ github.event.inputs.pr_number }}**. A deterministic
setup step already ran the azsdk pipeline analyze tool
(`azsdk ci analyze <pr>`) and wrote its full output to **`pipeline-analysis.txt`** in the
workspace root. Your job is to turn that raw tool output into one concise, actionable
**"Pipeline Analysis Next Steps"** comment on the PR.

## Step 0 - Read the analysis and validate

1. Read `pipeline-analysis.txt` (it is in the current working directory). It opens with an
   `===== Analysis source: <url> =====` line, then has up to two parts:
   the `azsdk ci analyze` output, and a trailing
   `===== Failing checks on <repo> PR #<n> =====` section listing this PR's own failing checks
   read from the GitHub Checks API.
   - **Harness mode.** If the run log said `Harness mode - sourcing pipeline analysis from ...`,
     the `azsdk` part describes a build in a *different* repository, because `azsdk` can only read
     the `dev.azure.com/azure-sdk` organization. Do **not** present it as this PR's failure. Base
     the comment on the trailing local-checks section, and say plainly which build you are
     describing.
2. If the file is empty, or contains `No failed Azure Pipeline builds found` with no usable
   local-checks section, or otherwise
   shows no real pipeline/test failures, then there is nothing to report: use the `noop` safe
   output and stop. Do **not** post a comment in that case.
3. Stale-commit guard: if `${{ github.event.inputs.ci_head_sha }}` is non-empty, fetch
   the PR's current head SHA. If they differ, the completed run is for a superseded commit -
   use `noop` and stop rather than posting stale analysis.

## Step 1 - Analyze the failures

From the tool output, determine what failed and the most likely cause(s):

- Group the failures (by pipeline/stage/job, failed build task, and/or failed tests).
- Categorize each failure as one of: **test** (assertion/test-case failure), **build**
  (compilation error), **validation** (lint/format/analyzer/spec violation), or
  **infrastructure** (network timeout, agent crash/disconnect, throttling, image/tooling
  outage). Note when several failures share one root cause.
- Identify concrete signals (compiler/build errors, failed test names, timeouts, missing
  files, lint/format violations, etc.). Rely **only** on what the tool output actually shows -
  do not invent failures or speculate beyond the evidence. If the cause is unclear, say so.
- For **infrastructure** failures, recommend re-running the pipeline rather than changing code;
  only recommend code changes for test/build/validation failures.
- Preserve any Azure DevOps build URLs from the output so reviewers can jump to the logs.

### Getting more detail when the analysis is thin

`azsdk ci analyze` reports the *names* of the artifacts a failing build published, not their
contents. When the named artifacts are what you need to explain the failure, fetch them:

```
azsdk ci test-results "<the URL from the 'Analysis source' line>"
```

Use the URL from the `===== Analysis source: =====` line verbatim - in harness mode the analyzed
build belongs to a different repository, so this PR's URL will not resolve. Ground the comment in
what the artifacts actually say; if the command fails or returns nothing usable, carry on with
the analysis you already have and do not speculate about the contents.

If `${{ github.repository }}` is `Azure/azure-rest-api-specs`, also read `documentation/ci-fix.md`
from the workspace. It maps that repository's CI failures to their documented local fix commands,
so prefer the commands it names when recommending next steps. The file does not exist in other
repositories - skip it there.

## Step 2 - Compose the "Pipeline Analysis Next Steps" comment

Post exactly one comment using the `add-comment` safe output, in this shape:

````markdown
<details>
<summary><strong>[Pilot] PR Pipeline Failure Analysis</strong></summary>

A CI pipeline failed on this pull request. Here is an automated analysis of what went wrong
and how to get the build green.

### What failed
<one short paragraph or a few bullets: the failing pipeline(s)/stage(s) and the most likely
root cause, with Azure DevOps build links where available>

### Recommended next steps
- <specific, actionable step tied to the failure above>
- <additional steps as needed>
- See the CI troubleshooting guide: https://aka.ms/ci-fix
- Push new commits to address the failures; this comment updates automatically on the next
  failing run.

<details>
<summary>Raw pipeline analysis (azsdk ci analyze)</summary>

```
<the relevant portion of pipeline-analysis.txt, trimmed if very long>
```

</details>

</details>

> Copilot detected the failing pipeline and generated the analysis above. To have it attempt a
> fix automatically, reply with `@copilot please fix the failing pipeline on this PR`.
````

## Constraints (non-negotiable)

1. **Read-only.** Do not check out, build, run, or modify PR code. Your only external action is
   posting the single comment via the `add-comment` safe output. Do not use `gh`, the GitHub
   MCP write tools, or direct API calls to comment.
2. **One comment.** Emit at most one `add-comment`. Keep it concise and skimmable; put the raw
   tool output inside the collapsible `<details>` block, trimming it if it is very long.
3. **The `@copilot` line is an example only.** Write it in backticks exactly as shown so it does
   not ping anyone. Do not @-mention any real user.
4. **Ground every claim in the tool output.** If `pipeline-analysis.txt` does not support a
   conclusion, do not state it. When failures are ambiguous, point reviewers at the linked
   build logs instead of guessing.
5. If there is nothing meaningful to report (see Step 0), use `noop` and post nothing.
