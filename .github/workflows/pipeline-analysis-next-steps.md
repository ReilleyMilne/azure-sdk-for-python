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
        required: false
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
    - "*.in.applicationinsights.azure.com"

checkout:
  sparse-checkout: |
    eng
    .github/skills
    .github/hooks

steps:
  - name: Install azsdk CLI
    shell: pwsh
    run: |
      $dir = Join-Path $HOME 'bin'
      ./eng/common/mcp/azure-sdk-mcp.ps1 -InstallDirectory $dir
      Add-Content -Path $env:GITHUB_PATH -Value $dir

  - name: Analyze failed pipeline
    shell: bash
    env:
      GITHUB_TOKEN: ${{ github.token }}
      GITHUB_REPOSITORY: ${{ github.repository }}
      PR_NUMBER: ${{ github.event.inputs.pr_number }}
      PR_HEAD_SHA: ${{ github.event.inputs.ci_head_sha }}
      PR_URL: "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"
    run: |
      set -uo pipefail
      status=0
      azsdk ci analyze "$PR_URL" > pipeline-analysis.txt 2>&1 || status=$?

      # A non-zero exit means either "nothing was failing" or a real auth/network/CLI error.
      # Only the former is an acceptable no-op; anything else must fail loudly instead of
      # letting the agent report "nothing to see here".
      if [ "$status" -ne 0 ] &&
         ! grep -qF "No failed Azure Pipeline builds found" pipeline-analysis.txt; then
        sed 's/^::/ ::/' pipeline-analysis.txt
        echo "::error::azsdk ci analyze failed with exit code $status"
        exit "$status"
      fi

      # azsdk can only read builds from an Azure DevOps organization it is authorised
      # against, so it reports "No failed Azure Pipeline builds found" for any pipeline it
      # cannot see. The Checks API always describes the failures actually present on this
      # pull request, so append it as a second, independent source.
      {
        echo
        echo "===== Failing checks on ${GITHUB_REPOSITORY} PR #${PR_NUMBER} ====="
        gh api "repos/${GITHUB_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs?per_page=100" \
          --jq '.check_runs[]
                | select(.conclusion == "failure")
                | "- \(.name): \(.output.title // "no title")\n  \(.output.summary // "" | gsub("\n"; " "))\n  \(.details_url)"' \
          2>/dev/null || echo "(could not read check runs)"
      } >> pipeline-analysis.txt

      # The file holds pull-request-controlled build output, so prefix anything that looks
      # like a workflow command with a space to log it as plain text.
      sed 's/^::/ ::/' pipeline-analysis.txt

tools:
  github:
    toolsets: [pull_requests, actions]
  bash:
    - "cat"
    - "head"
    - "tail"
    - "wc"
    - "azsdk ci test-results:*"

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

Analyze the failed Azure Pipelines run for pull request
**#${{ github.event.inputs.pr_number }}** and post one concise comment.

## Process

1. Read `pipeline-analysis.txt`. It has two sections: the `azsdk ci analyze` diagnosis, and a
   `Failing checks on ... PR #...` list read from the GitHub Checks API.
2. Use `noop` only if the file is empty or *both* sections report nothing. `No failed Azure
   Pipeline builds found` on its own is not enough: azsdk cannot see pipelines outside the
   Azure DevOps organization it is authorised against, so analyze the failing checks instead
   and say that the detailed build log was unavailable.
3. If `${{ github.event.inputs.ci_head_sha }}` is set, compare it with the PR's current head.
   Use `noop` if the PR has moved.
4. Read `.github/skills/azsdk-common-pipeline-analysis/SKILL.md` and its
   `references/failure-patterns.md` with the `view` tool, and follow their diagnosis guidance.
   Which skills a repository ships differs by language, so if that skill is not present, list
   `.github/skills/` and use any equivalent pipeline analysis or troubleshooting skill it does
   have; if there is none, analyse from `pipeline-analysis.txt` alone rather than stopping.
   Either way, use the comment format below.
5. If the analysis only names a test-result artifact and more detail is needed, run:
   `azsdk ci test-results "https://github.com/${{ github.repository }}/pull/${{ github.event.inputs.pr_number }}"`.
6. Use `add-comment` once.

## Comment format

````markdown
<details>
<summary><strong>[Pilot] PR Pipeline Failure Analysis</strong></summary>

### What failed
<failed pipeline, stage, job, or tests; include Azure DevOps links>

### Recommended next steps
- <specific action supported by the failure data>
- See https://aka.ms/ci-fix

<details>
<summary>Relevant pipeline output</summary>

```text
<short relevant excerpt; replace any triple backticks in the source>
```

</details>
</details>
````

## Rules

- Do not modify code or use GitHub write tools. The comment must use the safe output.
- Ground every claim in the analysis. If the cause is unclear, say so and link to the logs.
- Recommend a rerun for infrastructure failures; recommend code changes only for code failures.
- Do not include real user mentions.
