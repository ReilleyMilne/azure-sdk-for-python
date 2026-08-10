---
description: Analyze a failed Azure SDK pull-request pipeline and post actionable next steps.
run-name: "Pipeline Analysis / PR #${{ github.event.inputs.pr_number }} / ${{ github.event.inputs.ci_head_sha }}"

on:
  workflow_dispatch:
    inputs:
      pr_number:
        description: Pull request number to analyze
        required: true
        type: string
      ci_head_sha:
        description: Failed pull request commit
        required: true
        type: string

if: ${{ github.event_name == 'workflow_dispatch' }}
engine: copilot

permissions:
  actions: read
  checks: read
  contents: read
  copilot-requests: write
  pull-requests: read

network:
  allowed:
    - defaults
    - github
    - dev.azure.com
    - aka.ms
    - containers

checkout:
  sparse-checkout: |
    eng
    .github/skills

steps:
  - name: Install azsdk CLI
    shell: pwsh
    run: |
      $dir = Join-Path $HOME 'bin'
      ./eng/common/mcp/azure-sdk-mcp.ps1 -InstallDirectory $dir
      Add-Content -Path $env:GITHUB_PATH -Value $dir

      $mcpDir = Join-Path $env:RUNNER_TEMP 'azsdk-mcp'
      New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null
      $mcpExecutable = Join-Path $mcpDir 'azsdk'
      Copy-Item (Join-Path $dir 'azsdk') $mcpExecutable
      chmod +x $mcpExecutable
      if ($LASTEXITCODE) {
        throw "Failed to mark the Azure SDK MCP executable."
      }

  - name: Collect fallback check context
    shell: bash
    env:
      GH_TOKEN: ${{ github.token }}
      GITHUB_TOKEN: ${{ github.token }}
      GITHUB_REPOSITORY: ${{ github.repository }}
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      PR_HEAD_SHA: ${{ github.event.inputs.ci_head_sha }}
    run: |
      set -euo pipefail
      echo "===== Failing checks on ${GITHUB_REPOSITORY} PR #${PR_NUMBER} =====" \
        > pipeline-analysis.txt
      gh api --paginate \
        "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs?per_page=100" \
        --jq '.check_runs[]
              | select(.app.slug == "azure-pipelines")
              | select(.conclusion == "failure" or .conclusion == "timed_out")
              | "- \(.name) [\(.conclusion)]: \(.output.title // "no title")\n  \(.output.summary // "" | gsub("\n"; " "))\n  \(.details_url)"' \
        >> pipeline-analysis.txt

      # Build output is pull-request-controlled; log workflow commands in it as plain text.
      sed 's/^::/ ::/' pipeline-analysis.txt

tools:
  github:
    toolsets: [pull_requests, actions]
  bash:
    - "cat"
    - "head"
    - "tail"
    - "wc"

mcp-servers:
  azure-sdk-mcp:
    type: stdio
    container: "mcr.microsoft.com/dotnet/runtime-deps:8.0-noble"
    args:
      - "-v"
      - "${RUNNER_TEMP}/azsdk-mcp/azsdk:/usr/local/bin/azsdk:ro"
    entrypoint: "/usr/local/bin/azsdk"
    entrypointArgs: ["mcp"]
    env:
      GH_TOKEN: "${{ github.token }}"
      GITHUB_TOKEN: "${{ github.token }}"
    allowed:
      - azsdk_analyze_pipeline
      - azsdk_get_failed_test_run_data
      - azsdk_get_failed_test_case_data

safe-outputs:
  mentions: false
  allowed-github-references: []
  add-comment:
    max: 1
    target: "${{ github.event.inputs.pr_number }}"
    hide-older-comments: true
  noop:
    report-as-issue: false
  missing-tool:
    create-issue: false
  missing-data:
    create-issue: false
  report-incomplete:
    create-issue: false
  report-failure-as-issue: false

timeout-minutes: 20
concurrency: pipeline-analysis-${{ github.event.inputs.pr_number }}
---

# Pipeline Analysis

<!-- After editing this file, run 'gh aw compile pipeline-analysis-next-steps' to regenerate the lock file -->

Analyze the failed Azure Pipelines run for pull request
**#${{ github.event.inputs.pr_number }}** and post one concise comment.

## Process

1. If `${{ github.event.inputs.ci_head_sha }}` is set, compare it with the PR's current head.
   Use `noop` if the PR has moved.
2. Read `.github/skills/azsdk-common-pipeline-analysis/SKILL.md` and its
   `references/failure-patterns.md` with the `view` tool and follow their diagnosis guidance.
   This job is dispatched on, and checks out, the default branch, so `.github/skills/` is trusted.
   If that skill is absent, list `.github/skills/` and use any equivalent pipeline analysis or
   troubleshooting skill.
3. Call `azsdk_analyze_pipeline` with
   `pipelineIdentifier: "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"`.
   Treat `pipeline-analysis.txt` as fallback context only if the MCP analysis is missing data.
4. Inspect every `failed_pipeline_tests` entry returned by the analysis. For each unique
   `artifact_file_path`, call `azsdk_get_failed_test_run_data` exactly once with
   `failedTestRunsPath` set to that path. Use `azsdk_get_failed_test_case_data` only when one
   exact `testCaseTitle` needs targeted follow-up. Never diagnose or classify fixability from
   test titles alone.
5. Group evidence by build, platform, artifact file, and failed test. Preserve platform-specific
   failures even when titles overlap, but consolidate failures that share one demonstrated root
   cause.
6. Use `noop` only if the MCP analysis and fallback check context both report no failures.
7. Immediately before using `add-comment`, verify again that the PR is open and its current head
   is `${{ github.event.inputs.ci_head_sha }}`. Use `noop` if it moved or closed.
8. Use `add-comment` once.

## Comment format

````markdown
<details>
<summary><strong>[Pilot] PR Pipeline Failure Analysis</strong></summary>

### What failed
<failed pipeline, stage, job, or tests; include Azure DevOps links>

### Recommended next steps
- <specific action supported by the failure data>
- See https://aka.ms/ci-fix

**Automated fix:** <eligible | not eligible — reason>

<details>
<summary>Relevant pipeline output</summary>

```text
<short relevant excerpt; replace any triple backticks in the source>
```

</details>
</details>
````

## Rules

- The `[Pilot] PR Pipeline Failure Analysis` summary heading and the `**Automated fix:**` line are
  parsed by `eng/scripts/Invoke-PipelineAnalysis.ps1`. Emit both verbatim, emit the
  `**Automated fix:**` line exactly once, and keep it between `### Recommended next steps` and the
  next `<details>`. Do not use an HTML comment as a marker: the compiler strips HTML comments out
  of this file, so one would never reach you.
- Do not modify code or use GitHub write tools. The comment must use the safe output.
- Ground every claim in the analysis. If the cause is unclear, say so and link to the logs.
- Recommend a rerun for infrastructure failures; recommend code changes only for code failures.
- Write exactly `**Automated fix:** eligible` only for a deterministic, high-confidence code
  failure that can be fixed under `sdk/` and is supported by task errors with file/line evidence
  or detailed test error/stack data. For incomplete artifacts, non-completed builds,
  infrastructure, authentication, DNS/429, agent failures, timeout, flaky, live-test, ambiguous,
  or out-of-scope failures, write
  `**Automated fix:** not eligible — <brief reason>`.
- Do not include real user mentions.
