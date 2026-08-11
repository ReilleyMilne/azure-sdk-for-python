---
description: Analyze failed Azure SDK pull-request pipelines.
on:
  check_suite:
    types: [completed]
  permissions:
    checks: read
  steps:
    - name: Check whether analysis should run
      id: analysis_gate
      uses: actions/github-script@v9.0.0
      with:
        script: |
          if (context.payload.check_suite.pull_requests.length !== 1) {
            core.setFailed("Expected exactly one pull request associated with this suite.");
            return;
          }
          core.setOutput("pr_number", String(context.payload.check_suite.pull_requests[0].number));
          core.setOutput("head_sha", context.payload.check_suite.head_sha);
          const suites = await github.paginate(github.rest.checks.listSuitesForRef, {
            ...context.repo,
            ref: context.payload.check_suite.head_sha,
          });
          if (suites.some(suite => suite.status !== "completed")) core.setFailed("Suites are still running.");
          if (!suites.some(suite => suite.conclusion === "failure")) core.setFailed("No suites failed.");

if: needs.pre_activation.outputs.analysis_gate_result == 'success'

permissions:
  contents: read
  copilot-requests: write
  pull-requests: read

network:
  allowed:
    - defaults
    - github
    - dev.azure.com
    - aka.ms

pre-agent-steps:
  - name: Install Azure SDK MCP server
    shell: pwsh
    run: |
      $installDirectory = Join-Path $HOME "bin"
      ./eng/common/mcp/azure-sdk-mcp.ps1 -InstallDirectory $installDirectory
      Add-Content -Path $env:GITHUB_PATH -Value $installDirectory

tools:
  github:
    toolsets: [pull_requests]

jobs:
  pre-activation:
    outputs:
      pr_number: ${{ steps.analysis_gate.outputs.pr_number }}
      head_sha: ${{ steps.analysis_gate.outputs.head_sha }}

mcp-servers:
  azure-sdk-mcp:
    command: azsdk
    args: [mcp]
    env:
      GH_TOKEN: ${{ github.token }}
      GITHUB_TOKEN: ${{ github.token }}
    allowed:
      - azsdk_analyze_pipeline
      - azsdk_get_failed_test_run_data
      - azsdk_get_failed_test_case_data

safe-outputs:
  noop:
    report-as-issue: false
  add-comment:
    target: ${{ needs.pre_activation.outputs.pr_number }}
  dispatch-workflow:
    workflows:
      - pipeline-analysis-auto-fix
    max: 1
  jobs:
    publish-analysis:
      description: Publish the pipeline analysis and its fixability classification
      runs-on: ubuntu-latest
      needs: safe_outputs
      inputs:
        fixability:
          type: choice
          options: [fixable, non-fixable]
          required: true
        analysis:
          type: string
          required: true
      steps:
        - name: Read analysis
          uses: actions/github-script@v9.0.0
          with:
            script: |
              const fs = require("fs");
              const output = JSON.parse(fs.readFileSync(process.env.GH_AW_AGENT_OUTPUT, "utf8"));
              const item = output.items.find(item => item.type === "publish_analysis");
              if (!item) {
                core.setFailed("No pipeline analysis was produced.");
                return;
              }
---

# Pipeline Analysis Next Steps

## Process

1. Retrieve pull request `${{ needs.pre_activation.outputs.pr_number }}`. If it is not
  open or its current head is not `${{ needs.pre_activation.outputs.head_sha }}`, call `noop` and stop.
2. Read `.github/skills/azsdk-common-pipeline-analysis/SKILL.md` and its
  `references/failure-patterns.md`, then follow their diagnosis guidance.
3. Call `azsdk_analyze_pipeline` with
  `pipelineIdentifier: "https://github.com/${{ github.repository }}/pull/${{ needs.pre_activation.outputs.pr_number }}"`.
4. Inspect every `failed_pipeline_tests` entry returned by the analysis. For each unique
  `artifact_file_path`, call `azsdk_get_failed_test_run_data` exactly once with
  `failedTestRunsPath` set to that path. Use `azsdk_get_failed_test_case_data` only when one
  exact `testCaseTitle` needs targeted follow-up. Never diagnose or classify fixability from
  test titles alone.
5. Group evidence by build, platform, artifact file, and failed test. Preserve platform-specific
  failures when titles overlap, but consolidate failures with one demonstrated root cause.
6. Categorize the failures and determine whether any are fixable by an automated code change.

## Comment format

````markdown
<details>
<summary><strong>[Pilot] PR Pipeline Failure Analysis</strong></summary>

### What failed
<failed pipeline, stage, job, or tests; include Azure DevOps links>

<details>
<summary>Relevant pipeline output</summary>

```text
<short relevant excerpt; replace any triple backticks in the source>
```

</details>
</details>

### Recommended next steps
- <specific action supported by the failure data>
- See https://aka.ms/ci-fix

**Automated fix:** <in progress | not eligible — reason>
````

For infrastructure or authentication failures, explain the failure under `What failed`, include
`azsdk azp analyze https://github.com/${{ github.repository }}/pull/${{ needs.pre_activation.outputs.pr_number }}`
under `Recommended next steps`, and use `**Automated fix:** not eligible — <reason>`.

## Publish

- Retrieve the pull request again. If it is not open or its current head is not `${{ needs.pre_activation.outputs.head_sha }}`, call `noop` and stop without commenting or dispatching.
- Call `publish_analysis` exactly once with the complete analysis and `fixable` if any failure is fixable; otherwise use `non-fixable`.
- Call `add_comment` exactly once with item number `${{ needs.pre_activation.outputs.pr_number }}` and the same complete analysis.
- For `fixable`, use `**Automated fix:** in progress` and call `dispatch_workflow` once with inputs `pr_number: "${{ needs.pre_activation.outputs.pr_number }}"`, `ci_head_sha: "${{ needs.pre_activation.outputs.head_sha }}"`, and `parent_run_id: "${{ github.run_id }}"`.
- For `non-fixable`, use `**Automated fix:** not eligible — <reason>` and do not dispatch a workflow.