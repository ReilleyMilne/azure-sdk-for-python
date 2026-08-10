[CmdletBinding()]
param(
    [ValidateSet('Dispatch', 'CloseCheck', 'CreateFixPr', 'ReportFixAndDispatchValidation', 'Validate', 'Cleanup')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Required environment variable '$Name' is empty." }
    return $value
}

function Get-OptionalEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name)
}

function Assert-Repository {
    param([Parameter(Mandatory)][string]$Repository)
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository '$Repository'." }
    return $Repository
}

function Assert-Number {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -notmatch '^[1-9][0-9]*$') { throw "Invalid $Name '$Value'." }
    return $Value
}

function Assert-Sha {
    param([Parameter(Mandatory)][string]$Sha)
    if ($Sha -notmatch '^[0-9a-f]{40}$') { throw "Invalid SHA '$Sha'." }
    return $Sha
}

function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed: $($result -join [Environment]::NewLine)" }
    return ($result -join [Environment]::NewLine)
}

function Try-Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($result -join [Environment]::NewLine)
}

function Invoke-GhInput {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$InputText)
    $result = $InputText | & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed: $($result -join [Environment]::NewLine)" }
    return ($result -join [Environment]::NewLine)
}

function Invoke-GhWithTextFile {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Text)
    $path = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
        return Invoke-Gh ($Arguments + $path)
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-GhJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Expected JSON from gh, but received no output.' }
    try { $value = $Text | ConvertFrom-Json -Depth 100 } catch { throw "Invalid JSON from gh: $($_.Exception.Message)" }
    if ($null -eq $value) { throw 'Expected a JSON value from gh.' }
    return ,$value
}

function ConvertFrom-GhJsonArray {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    try { $value = $Text | ConvertFrom-Json -Depth 100 } catch { throw "Invalid JSON from gh: $($_.Exception.Message)" }
    return @($value)
}

function Get-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Expected JSON property '$Name'." }
    return $property.Value
}

# ConvertFrom-Json turns ISO-8601 timestamps into [DateTime], and comparing one of those against a
# string coerces the string through the *local* time zone. On any runner that is not set to UTC the
# result is wrong by the UTC offset, which would let a comment posted before the dispatch look
# newer than it is. Normalise both sides to UTC before comparing.
function ConvertTo-UtcTime {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTime]) {
        $time = [DateTime]$Value
        if ($time.Kind -eq [DateTimeKind]::Local) { return $time.ToUniversalTime() }
        return [DateTime]::SpecifyKind($time, [DateTimeKind]::Utc)
    }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Get-ApiObject {
    param([Parameter(Mandatory)][string]$Path)
    return ConvertFrom-GhJson (Invoke-Gh @('api', $Path))
}

function Get-ApiArray {
    param([Parameter(Mandatory)][string]$Path)
    $pages = ConvertFrom-GhJson (Invoke-Gh @('api', '--paginate', '--slurp', $Path))
    $items = @()
    foreach ($page in $pages) { $items += @($page) }
    return $items
}

function Write-GithubOutput {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $path = Get-RequiredEnvironmentVariable 'GITHUB_OUTPUT'
    [System.IO.File]::AppendAllText($path, "$Name=$Value`n", [System.Text.UTF8Encoding]::new($false))
}

function Get-PullRequest {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Number, [Parameter(Mandatory)][string[]]$Fields)
    $Number = Assert-Number $Number 'pull request number'
    return ConvertFrom-GhJson (Invoke-Gh (@('pr', 'view', $Number, '--repo', $Repository, '--json') + ($Fields -join ',')))
}

function Test-AzureSuiteStatusesComplete {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Suites)
    return $Suites.Count -gt 0 -and @($Suites | Where-Object { (Get-JsonProperty $_ 'status') -ne 'completed' }).Count -eq 0
}

function Get-AzureSuites {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Sha)
    $pages = ConvertFrom-GhJson (Invoke-Gh @(
        'api', '--paginate', '--slurp', "repos/$Repository/commits/$Sha/check-suites?per_page=100"
    ))
    $suites = foreach ($page in $pages) { @(Get-JsonProperty $page 'check_suites') }
    return @($suites | Where-Object { (Get-JsonProperty (Get-JsonProperty $_ 'app') 'slug') -eq 'azure-pipelines' })
}

function Test-SuitesComplete {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Sha)
    return Test-AzureSuiteStatusesComplete @(Get-AzureSuites $Repository $Sha)
}

function Test-FixRollupsSuccessful {
    param([Parameter(Mandatory)][object[]]$Rollups)
    return $Rollups.Count -gt 0 -and @($Rollups | Where-Object { (Get-JsonProperty $_ 'status') -ne 'completed' -or (Get-JsonProperty $_ 'conclusion') -ne 'success' }).Count -eq 0
}

function Get-AzureRollups {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Sha)
    $pages = ConvertFrom-GhJson (Invoke-Gh @(
        'api', '--paginate', '--slurp', "repos/$Repository/commits/$Sha/check-runs?per_page=100"
    ))
    # Azure Pipelines publishes one rollup check run per pipeline plus one check run per job,
    # and only the job-level names carry a ' (<job>)' suffix. This suffix is the only signal the
    # checks API exposes, so a pipeline whose display name contains ' (' would be misread as a job.
    $runs = foreach ($page in $pages) { @(Get-JsonProperty $page 'check_runs') }
    return @($runs | Where-Object {
        $app = Get-JsonProperty $_ 'app'
        (Get-JsonProperty $app 'slug') -eq 'azure-pipelines' -and -not (Get-JsonProperty $_ 'name').Contains(' (')
    })
}

function Get-CheckRuns {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Sha)
    $pages = ConvertFrom-GhJson (Invoke-Gh @(
        'api', '--paginate', '--slurp', "repos/$Repository/commits/$Sha/check-runs?per_page=100"
    ))
    $runs = foreach ($page in $pages) { @(Get-JsonProperty $page 'check_runs') }
    return @($runs)
}

function Test-ContainsAnyMarker {
    param([Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string[]]$Markers)
    foreach ($marker in $Markers) {
        if ($marker -and $Body.Contains($marker)) { return $true }
    }
    return $false
}

# The HTML marker is the precise handle, but it is emitted by the agent and could in principle be
# stripped by output sanitisation, so the human-readable heading is accepted as a fallback.
function Get-AnalysisMarkers {
    $markers = @(Get-RequiredEnvironmentVariable 'ANALYSIS_MARKER')
    $fallback = Get-OptionalEnvironmentVariable 'ANALYSIS_MARKER_FALLBACK'
    if (-not [string]::IsNullOrWhiteSpace($fallback)) { $markers += $fallback }
    # Callers assign this directly rather than collecting it with @(), so the comma is required to
    # keep a single marker an array. Do not add @() at a call site without removing the comma.
    return ,$markers
}

function Get-LatestAnalysisComment {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$OriginalPr,
        [Parameter(Mandatory)][string[]]$Markers,
        [string]$RequiredText = ''
    )
    $comments = Get-ApiArray "repos/$Repository/issues/$OriginalPr/comments?per_page=100"
    return @($comments | Where-Object {
        $body = [string](Get-JsonProperty $_ 'body')
        (Get-JsonProperty (Get-JsonProperty $_ 'user') 'login') -eq 'github-actions[bot]' -and
        (Test-ContainsAnyMarker $body $Markers) -and
        (-not $RequiredText -or $body.Contains($RequiredText))
    } | Sort-Object { Get-JsonProperty $_ 'created_at' } -Descending | Select-Object -First 1)
}

# Tolerant lookup used by the dispatch polling loop: a transient API failure yields an empty
# result so the caller keeps polling instead of aborting the run.
function Get-AnalysisCommentsSince {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$OriginalPr,
        [Parameter(Mandatory)][string[]]$Markers,
        [Parameter(Mandatory)][string]$Since
    )
    $output = Try-Invoke-Gh @(
        'api', '--paginate', '--slurp', "repos/$Repository/issues/$OriginalPr/comments?per_page=100"
    )
    if ($null -eq $output) { return @() }
    $pages = ConvertFrom-GhJson $output
    $comments = foreach ($page in $pages) { @($page) }
    $since = ConvertTo-UtcTime $Since
    return @($comments | Where-Object {
        (Get-JsonProperty (Get-JsonProperty $_ 'user') 'login') -eq 'github-actions[bot]' -and
        (ConvertTo-UtcTime (Get-JsonProperty $_ 'created_at')) -gt $since -and
        (Test-ContainsAnyMarker ([string](Get-JsonProperty $_ 'body')) $Markers)
    } | Sort-Object { ConvertTo-UtcTime (Get-JsonProperty $_ 'created_at') } -Descending)
}

function Update-AnalysisComment {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$Comment,
        [Parameter(Mandatory)][string]$Addition,
        [Parameter(Mandatory)][string]$FixMarker
    )
    $id = [string](Get-JsonProperty $Comment 'id')
    $body = [string](Get-JsonProperty $Comment 'body')
    $updated = Get-ReplacedFixSection $body $Addition $FixMarker
    if ($updated -eq $body) { return }
    $payload = @{ body = $updated } | ConvertTo-Json -Compress
    Invoke-GhInput @('api', '-X', 'PATCH', "repos/$Repository/issues/comments/$id", '--input', '-') $payload | Out-Null
    Write-Host "  updated analysis comment $id."
}

function Get-ReplacedFixSection {
    param([Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string]$Addition, [Parameter(Mandatory)][string]$Marker)
    $index = $Body.IndexOf($Marker, [System.StringComparison]::Ordinal)
    if ($index -ge 0) { return $Body.Substring(0, $index) + $Addition }
    if ($Body.EndsWith("`n", [System.StringComparison]::Ordinal)) { return $Body + $Addition }
    return $Body + "`n" + $Addition
}

function Test-FixableAnalysisComment {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$FixableMarker
    )
    $heading = '### Recommended next steps'
    $start = $Body.IndexOf($heading, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { return $false }
    $start += $heading.Length

    $end = $Body.IndexOf('<details>', $start, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { return $false }

    $classifications = @(
        $Body.Substring($start, $end - $start) -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.StartsWith('**Automated fix:**', [System.StringComparison]::Ordinal) }
    )
    if ($classifications.Count -ne 1) { return $false }
    $classification = $classifications[0]
    return $classification -ceq $FixableMarker -or
        $classification.StartsWith("$FixableMarker ", [System.StringComparison]::Ordinal)
}

function Set-FixSection {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$OriginalPr,
        [Parameter(Mandatory)][string[]]$Markers,
        [Parameter(Mandatory)][string]$FixMarker,
        [Parameter(Mandatory)][string]$Addition,
        [string]$RequiredText = ''
    )
    $comment = @(Get-LatestAnalysisComment $Repository $OriginalPr $Markers $RequiredText)
    if ($comment.Count -eq 0) {
        if ($RequiredText) {
            Write-Host "  no analysis comment referencing '$RequiredText' remains on PR #$OriginalPr."
            return
        }
        if ($Addition.Length -gt 0) {
            $body = "$($Markers[0])`n`n$Addition"
            Invoke-GhWithTextFile @(
                'pr', 'comment', $OriginalPr, '--repo', $Repository, '--body-file'
            ) $body | Out-Null
            Write-Host "  posted a new comment on PR #$OriginalPr."
        }
        return
    }
    $comment = $comment[0]
    Update-AnalysisComment $Repository $comment $Addition $FixMarker
}

function Get-FixBranchContext {
    param([Parameter(Mandatory)][string]$Branch)
    if ($Branch -notmatch '^copilot-pipeline-fix/pr-([0-9]+)-([0-9a-f]{40})/') { return $null }
    return [pscustomobject]@{ OriginalPr = $Matches[1]; OriginalSha = $Matches[2] }
}

# `gh workflow run` does not return the id of the run it queues, so dispatched runs are correlated
# by their unique run-name. Scope the query to workflow_dispatch runs created on or after the
# dispatch day so unrelated history cannot fill the 100-run window, then take the newest match.
function Get-DispatchedRun {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$SinceDate,
        [Parameter(Mandatory)][string[]]$Fields
    )
    $output = Try-Invoke-Gh @(
        'run', 'list', '--repo', $Repository, '--workflow', $Workflow,
        '--event', 'workflow_dispatch', '--created', ">=$SinceDate",
        '--limit', '100', '--json', ($Fields -join ',')
    )
    if ($null -eq $output) { return @() }
    return @(ConvertFrom-GhJsonArray $output |
        Where-Object { (Get-JsonProperty $_ 'displayTitle') -eq $Title } |
        Select-Object -First 1)
}

# The dispatch job can be cancelled or hit its timeout while the check run it opened is still
# in_progress, which would strand the check on the pull request forever. Record the id so a
# cancellation-only step can close it.
function Get-CheckRunIdPath {
    $root = [Environment]::GetEnvironmentVariable('RUNNER_TEMP')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return Join-Path $root 'pipeline-analysis-check-run-id.txt'
}

function Test-GeneratedFixPaths {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths)
    return @($Paths | Where-Object { -not $_.StartsWith('sdk/', [System.StringComparison]::Ordinal) }).Count -eq 0
}

# The compare API caps `files` at 300 entries and offers no way to page past it, so a containment
# check over a truncated list could pass while an out-of-scope path sat beyond the cap. Return
# $null in that case and let callers refuse to act rather than trust a partial answer.
function Get-ComparisonFilePaths {
    param([Parameter(Mandatory)]$Comparison)
    # Assign in statement form: `$x = if (...) { @() }` collapses an empty array to $null.
    $files = @()
    $property = $Comparison.PSObject.Properties['files']
    if ($null -ne $property -and $null -ne $property.Value) { $files = @($property.Value) }
    if ($files.Count -ge 300) { return $null }
    # Callers assign this directly and test for $null to detect truncation, so the comma is required
    # to keep an empty result distinguishable from $null. Do not add @() at a call site.
    return ,@($files | ForEach-Object { [string](Get-JsonProperty $_ 'filename') })
}

function New-FixAddition {
    param([string]$FixNumber, [string]$FixUrl, [ValidateSet('pending', 'failed', 'stale', 'validated')][string]$State, [string]$DefaultBranch, [string[]]$Pipelines)
    $header = "<!-- pipeline-analysis-fix -->`n`n---`n`n### Attempted Copilot Fix`n`n"
    if ($State -eq 'pending') {
        $target = if ($DefaultBranch) { "``$DefaultBranch``" } else { 'the default branch' }
        return $header + "PR: [#$FixNumber]($FixUrl) attempted to fix the pipeline failures found by the analysis.`n`n**Next steps:** Its pipelines are still running and this note will be updated once they finish. The draft temporarily targets $target so Azure Pipelines runs; wait for validation and retargeting before merging.`n"
    }
    if ($State -eq 'failed') {
        return $header + "PR: [#$FixNumber]($FixUrl) attempted to fix the pipeline failures found by the analysis, but failed.`n`n**Next steps:** Review the analysis above, or comment ``@copilot fix the pipeline failures`` on this pull request to have Copilot try again.`n"
    }
    if ($State -eq 'stale') {
        return $header + "PR: [#$FixNumber]($FixUrl) was closed because the original pull request moved or closed while the fix was being validated.`n`n**Next steps:** Use the analysis for the latest commit instead.`n"
    }
    $list = (($Pipelines | ForEach-Object { "- ``$_``" }) -join "`n")
    return $header + "PR: [#$FixNumber]($FixUrl) attempted to fix the pipeline failures found by the analysis. It successfully fixed the following pipelines:`n`n$list`n`n**Next steps:** Review the change and merge it into this branch to pick up the fix.`n"
}

function Invoke-Dispatch {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY')
    $defaultBranch = Get-RequiredEnvironmentVariable 'DEFAULT_BRANCH'
    $headSha = Assert-Sha (Get-RequiredEnvironmentVariable 'HEAD_SHA')
    $prNumber = Get-OptionalEnvironmentVariable 'PR_NUMBER'
    $checkName = Get-RequiredEnvironmentVariable 'CHECK_NAME'
    $analysisMarkers = Get-AnalysisMarkers
    $fixableMarker = Get-RequiredEnvironmentVariable 'FIXABLE_MARKER'
    $fixMarker = Get-RequiredEnvironmentVariable 'FIX_SECTION_MARKER'

    if ([string]::IsNullOrWhiteSpace($prNumber)) {
        $pulls = Get-ApiArray "repos/$repository/pulls?state=open&per_page=100"
        $match = @($pulls | Where-Object { (Get-JsonProperty (Get-JsonProperty $_ 'head') 'sha') -eq $headSha } | Sort-Object { Get-JsonProperty $_ 'updated_at' } -Descending | Select-Object -First 1)
        if ($match.Count -eq 0) { Write-Host "No open pull request found for $headSha."; return }
        $prNumber = [string](Get-JsonProperty $match[0] 'number')
    }
    $prNumber = Assert-Number $prNumber 'pull request number'
    $pr = Get-PullRequest $repository $prNumber @('baseRefName', 'headRefName', 'headRefOid', 'isCrossRepository', 'isDraft')
    if ((Get-JsonProperty $pr 'headRefOid') -ne $headSha) { Write-Host "Skipping stale failure for PR #$prNumber."; return }
    $headRef = [string](Get-JsonProperty $pr 'headRefName')
    if ($headRef.StartsWith('copilot-pipeline-fix/', [System.StringComparison]::Ordinal)) { Write-Host "Skipping generated fix PR #$prNumber."; return }

    $complete = $false
    for ($i = 1; $i -le 20; $i++) {
        if (Test-SuitesComplete $repository $headSha) { $complete = $true; break }
        Start-Sleep -Seconds 30
    }
    if (-not $complete) { Write-Host "Azure Pipelines is still registering or running checks for $headSha."; return }
    $failedRollups = @(Get-AzureRollups $repository $headSha | Where-Object { $conclusion = Get-JsonProperty $_ 'conclusion'; $conclusion -eq 'failure' -or $conclusion -eq 'timed_out' })
    if ($failedRollups.Count -eq 0) { Write-Host "All completed Azure Pipelines rollups passed for $headSha."; return }

    $completed = @(Get-CheckRuns $repository $headSha | Where-Object {
        (Get-JsonProperty $_ 'name') -eq $checkName -and
        (Get-JsonProperty $_ 'status') -eq 'completed' -and
        (Get-JsonProperty $_ 'conclusion') -eq 'success'
    })
    if ($completed.Count -gt 0) { Write-Host "PR #$prNumber has already been analysed at $headSha."; return }
    $context = "{`"item_type`":`"pull_request`",`"item_number`":$prNumber}"
    $runTitle = "Pipeline Analysis / PR #$prNumber / $headSha"
    $runUrl = "$(if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL } else { 'https://github.com' })/$repository/actions/runs/$(Get-RequiredEnvironmentVariable 'GITHUB_RUN_ID')"
    $checkResponse = ConvertFrom-GhJson (Invoke-Gh @('api', '-X', 'POST', "repos/$repository/check-runs", '-f', "name=$checkName", '-f', "head_sha=$headSha", '-f', 'status=in_progress', '-f', "details_url=$runUrl", '-f', 'output[title]=Analysing the failed pipeline', '-f', "output[summary]=See $runUrl"))
    $checkId = [string](Get-JsonProperty $checkResponse 'id')
    [System.IO.File]::WriteAllText((Get-CheckRunIdPath), $checkId, [System.Text.UTF8Encoding]::new($false))
    $checkConclusion = 'neutral'; $checkTitle = 'Analysis did not complete'; $checkSummary = "See $runUrl"
    try {
        $dispatchedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $dispatchedDate = $dispatchedAt.Substring(0, 10)
        Invoke-Gh @('workflow', 'run', 'pipeline-analysis-next-steps.lock.yml', '--repo', $repository, '--ref', $defaultBranch, '-f', "aw_context=$context", '-f', "pr_number=$prNumber", '-f', "ci_head_sha=$headSha") | Out-Null
        Write-Host "Dispatched analysis for PR #$prNumber."
        $checkTitle = 'Analysis dispatched'
        $skipAutoFix = [bool](Get-JsonProperty $pr 'isDraft') -or
            [bool](Get-JsonProperty $pr 'isCrossRepository')

        Write-Host "Waiting for the analysis comment on PR #$prNumber..."
        $analysed = $false; $fixable = $false; $analysisStatus = ''; $analysisConclusion = ''
        $analysisComments = @(); $sawAnalysisRun = $false
        for ($i = 1; $i -le 255; $i++) {
            Start-Sleep -Seconds 20
            $analysisComments = @(Get-AnalysisCommentsSince $repository $prNumber $analysisMarkers $dispatchedAt)
            if ($analysisComments.Count -gt 0) { $analysed = $true; break }
            $run = @(Get-DispatchedRun $repository 'pipeline-analysis-next-steps.lock.yml' $runTitle $dispatchedDate @('conclusion', 'status', 'displayTitle'))
            if ($run.Count -gt 0) { $sawAnalysisRun = $true; $analysisStatus = [string](Get-JsonProperty $run[0] 'status'); $analysisConclusion = [string](Get-JsonProperty $run[0] 'conclusion') }
            if ($analysisStatus -eq 'completed') {
                # The comment is posted by a job inside the run, so it can land moments before the
                # run reports completion. Without this second look a valid analysis - and the
                # auto-fix it authorises - would be discarded as "no actionable failure".
                Start-Sleep -Seconds 20
                $analysisComments = @(Get-AnalysisCommentsSince $repository $prNumber $analysisMarkers $dispatchedAt)
                if ($analysisComments.Count -gt 0) { $analysed = $true }
                break
            }
        }
        if ($analysed) {
            $fixable = Test-FixableAnalysisComment `
                ([string](Get-JsonProperty $analysisComments[0] 'body')) `
                $fixableMarker
        }
        if (-not $analysed) {
            if ($analysisStatus -eq 'completed' -and $analysisConclusion -eq 'success') { $checkConclusion = 'success'; $checkTitle = 'No actionable pipeline failure found'; Write-Host "Analysis reported no actionable failure for PR #$prNumber." }
            elseif (-not $sawAnalysisRun) {
                # Runs are correlated by run-name. If none ever matched, the dispatched workflow's
                # lock file is most likely missing or out of date with respect to its run-name.
                $checkTitle = 'Analysis run could not be correlated'
                $checkSummary = "No workflow_dispatch run titled '$runTitle' was found. Confirm the analysis lock file is compiled and its run-name matches. See $runUrl"
                Write-Host "Never correlated a run titled '$runTitle'."
            }
            else { $checkTitle = 'Analysis incomplete; a pipeline rerun can retry'; $checkSummary = "The analysis workflow ended with status '$analysisStatus' and conclusion '$analysisConclusion'. See $runUrl"; Write-Host "Analysis did not complete successfully for PR #$prNumber." }
            return
        }
        $freshPr = Get-PullRequest $repository $prNumber @('headRefOid', 'state')
        if ((Get-JsonProperty $freshPr 'state') -ne 'OPEN' -or
            (Get-JsonProperty $freshPr 'headRefOid') -ne $headSha) {
            $staleCommentId = [string](Get-JsonProperty $analysisComments[0] 'id')
            Invoke-Gh @('api', '-X', 'DELETE', "repos/$repository/issues/comments/$staleCommentId") | Out-Null
            $checkTitle = 'Stale analysis removed after the PR changed'
            Write-Host "PR #$prNumber moved or closed; removed stale analysis comment $staleCommentId."
            return
        }
        $checkConclusion = 'success'; $checkTitle = 'Analysis posted'; $checkSummary = "Next steps posted on PR #$prNumber. See $runUrl"
        if (-not $fixable) {
            $checkTitle = 'Analysis posted; automated fix not applicable'
            Write-Host "Analysis did not classify PR #$prNumber as eligible for automated fixing."
            return
        }
        if ($skipAutoFix) {
            $checkTitle = 'Analysis posted; auto-fix skipped for draft or fork'
            Write-Host "Skipping auto-fix for draft or fork PR #$prNumber."
            return
        }
        $freshPr = Get-PullRequest $repository $prNumber @('headRefOid', 'isCrossRepository', 'isDraft', 'state')
        if ((Get-JsonProperty $freshPr 'state') -ne 'OPEN' -or
            (Get-JsonProperty $freshPr 'headRefOid') -ne $headSha) {
            $staleCommentId = [string](Get-JsonProperty $analysisComments[0] 'id')
            Invoke-Gh @('api', '-X', 'DELETE', "repos/$repository/issues/comments/$staleCommentId") | Out-Null
            $checkTitle = 'Analysis posted; auto-fix skipped because the PR changed'
            Write-Host "PR #$prNumber moved or closed; removed stale analysis comment $staleCommentId."
            return
        }
        if ([bool](Get-JsonProperty $freshPr 'isDraft') -or
            [bool](Get-JsonProperty $freshPr 'isCrossRepository')) {
            $checkTitle = 'Analysis posted; auto-fix skipped for draft or fork'
            Write-Host "PR #$prNumber became a draft or cross-repository PR; skipping auto-fix."
            return
        }
        Invoke-Gh @('workflow', 'run', 'pipeline-analysis-auto-fix.lock.yml', '--repo', $repository, '--ref', $defaultBranch, '-f', "aw_context=$context", '-f', "pr_number=$prNumber", '-f', "ci_head_sha=$headSha", '-f', "parent_run_id=$(Get-RequiredEnvironmentVariable 'GITHUB_RUN_ID')") | Out-Null
        Write-Host "Dispatched auto-fix for PR #$prNumber."

        Write-Host 'Waiting for the auto-fix pull request...'
        $fixTitle = "Pipeline Auto Fix / PR #$prNumber / $headSha / Parent $(Get-RequiredEnvironmentVariable 'GITHUB_RUN_ID')"
        $fix = @(); $fixRunId = ''
        for ($i = 1; $i -le 285; $i++) {
            Start-Sleep -Seconds 20
            $run = @(Get-DispatchedRun $repository 'pipeline-analysis-auto-fix.lock.yml' $fixTitle $dispatchedDate @('conclusion', 'databaseId', 'status', 'displayTitle'))
            if ($run.Count -gt 0) {
                $status = [string](Get-JsonProperty $run[0] 'status')
                $fixRunId = [string](Get-JsonProperty $run[0] 'databaseId')
                $expectedFixPrefix = "copilot-pipeline-fix/pr-$prNumber-$headSha/run-$fixRunId/"
                $fixesOutput = Try-Invoke-Gh @(
                    'pr', 'list', '--repo', $repository, '--state', 'open', '--limit', '100',
                    '--json', 'number,url,headRefName,isCrossRepository'
                )
                if ($null -eq $fixesOutput) { continue }
                $fixes = ConvertFrom-GhJsonArray $fixesOutput
                $fix = @($fixes | Where-Object {
                    -not [bool](Get-JsonProperty $_ 'isCrossRepository') -and
                    (Get-JsonProperty $_ 'headRefName').StartsWith(
                        $expectedFixPrefix, [System.StringComparison]::Ordinal
                    )
                } | Select-Object -First 1)
                if ($fix.Count -gt 0 -or $status -eq 'completed') { break }
            }
        }
        $freshPr = Get-PullRequest $repository $prNumber @('headRefOid', 'state')
        if ((Get-JsonProperty $freshPr 'state') -ne 'OPEN' -or
            (Get-JsonProperty $freshPr 'headRefOid') -ne $headSha) {
            if ($fix.Count -gt 0) {
                $staleFixNumber = [string](Get-JsonProperty $fix[0] 'number')
                Invoke-Gh @('pr', 'close', $staleFixNumber, '--repo', $repository, '--comment', "Closed because PR #$prNumber moved or closed while this fix was generated.") | Out-Null
                Write-Host "Closed stale generated fix PR #$staleFixNumber."
            }
            $checkTitle = 'Analysis posted; generated fix is stale'
            Write-Host "PR #$prNumber moved or closed while auto-fix was running; the generated result will not be reported."
            return
        }
        if ($fix.Count -eq 0) {
            $fixBranch = ''
            if ($fixRunId) {
                $prefix = "copilot-pipeline-fix/pr-$prNumber-$headSha/run-$fixRunId/"
                $refs = @(Get-ApiArray "repos/$repository/git/matching-refs/heads/$prefix")
                if ($refs.Count -gt 0) {
                    $fixBranch = ([string](Get-JsonProperty $refs[0] 'ref')) -replace '^refs/heads/', ''
                }
            }
            if (-not $fixBranch) {
                if (-not $fixRunId) { Write-Host "Never correlated a run titled '$fixTitle'; confirm the auto-fix lock file is compiled and its run-name matches." }
                else { Write-Host "Auto-fix produced neither a pull request nor a branch for PR #$prNumber." }
                return
            }
            Write-GithubOutput 'fix_branch' $fixBranch; Write-GithubOutput 'original_pr' $prNumber; Write-GithubOutput 'original_sha' $headSha
            $checkTitle = 'Analysis posted, fix branch ready'; $checkSummary = "Next steps posted on PR #$prNumber; generated branch $fixBranch"; Write-Host "Handing $fixBranch to the GitHub App pull-request job."; return
        }
        $fixNumber = [string](Get-JsonProperty $fix[0] 'number'); $fixUrl = [string](Get-JsonProperty $fix[0] 'url')
        $checkTitle = 'Analysis posted, fix drafted'; $checkSummary = "Next steps posted on PR #$prNumber; draft fix $fixUrl"
        $addition = New-FixAddition $fixNumber $fixUrl 'pending' $defaultBranch @()
        $comment = @(Get-LatestAnalysisComment $repository $prNumber $analysisMarkers)
        if ($comment.Count -eq 0) { Write-Host "Analysis comment disappeared from PR #$prNumber."; return }
        Update-AnalysisComment $repository $comment[0] $addition $fixMarker
        Write-Host "Reported $fixUrl on PR #$prNumber."
        Invoke-Gh @('workflow', 'run', 'pipeline-analysis-trigger.yml', '--repo', $repository, '--ref', $defaultBranch, '-f', "fix_pr=$fixNumber") | Out-Null
        Write-Host "Dispatched validation for fix pull request #$fixNumber."
    } finally {
        Invoke-Gh @('api', '-X', 'PATCH', "repos/$repository/check-runs/$checkId", '-f', 'status=completed', '-f', "conclusion=$checkConclusion", '-f', "output[title]=$checkTitle", '-f', "output[summary]=$checkSummary") | Out-Null
        Remove-Item -LiteralPath (Get-CheckRunIdPath) -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CloseCheck {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY')
    $path = Get-CheckRunIdPath
    if (-not (Test-Path -LiteralPath $path)) { Write-Host 'No analysis check run needs closing.'; return }
    $checkId = ([string](Get-Content -LiteralPath $path -Raw)).Trim()
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $checkId) { return }
    $checkId = Assert-Number $checkId 'check run id'
    Invoke-Gh @(
        'api', '-X', 'PATCH', "repos/$repository/check-runs/$checkId",
        '-f', 'status=completed', '-f', 'conclusion=cancelled',
        '-f', 'output[title]=Analysis was cancelled',
        '-f', 'output[summary]=The dispatch job was cancelled or timed out before the analysis finished. Rerun a pipeline to retry.'
    ) | Out-Null
    Write-Host "Closed stranded analysis check run $checkId."
}

function Invoke-CreateFixPr {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY'); $defaultBranch = Get-RequiredEnvironmentVariable 'DEFAULT_BRANCH'
    $fixBranch = Get-RequiredEnvironmentVariable 'FIX_BRANCH'; $originalPr = Assert-Number (Get-RequiredEnvironmentVariable 'ORIGINAL_PR') 'original pull request number'; $originalSha = Assert-Sha (Get-RequiredEnvironmentVariable 'ORIGINAL_SHA')
    $expectedPrefix = "copilot-pipeline-fix/pr-$originalPr-$originalSha/run-"
    if (-not $fixBranch.StartsWith($expectedPrefix, [System.StringComparison]::Ordinal)) { throw "Unexpected generated branch '$fixBranch'." }
    $original = Get-PullRequest $repository $originalPr @('headRefOid', 'isCrossRepository', 'isDraft', 'state')
    if ((Get-JsonProperty $original 'state') -ne 'OPEN' -or (Get-JsonProperty $original 'headRefOid') -ne $originalSha -or [bool](Get-JsonProperty $original 'isDraft') -or [bool](Get-JsonProperty $original 'isCrossRepository')) { Write-Host "Original PR #$originalPr is no longer eligible; leaving the branch."; return }
    $comparison = Get-ApiObject "repos/$repository/compare/$originalSha...$fixBranch"
    if ((Get-JsonProperty (Get-JsonProperty $comparison 'merge_base_commit') 'sha') -ne $originalSha -or (Get-JsonProperty $comparison 'status') -ne 'ahead') { throw "$fixBranch is not a non-empty descendant of $originalSha." }
    $changedPaths = Get-ComparisonFilePaths $comparison
    if ($null -eq $changedPaths) { throw "$fixBranch changes too many files to verify that they stay under sdk/." }
    if ($changedPaths.Count -eq 0) { Write-Host "$fixBranch changes no files; leaving the branch."; return }
    if (-not (Test-GeneratedFixPaths $changedPaths)) { throw "$fixBranch contains changes outside sdk/." }
    $open = @(ConvertFrom-GhJsonArray (Invoke-Gh @(
        'pr', 'list', '--repo', $repository, '--state', 'open', '--head', $fixBranch,
        '--limit', '10', '--json', 'isCrossRepository,url'
    )) | Where-Object { -not [bool](Get-JsonProperty $_ 'isCrossRepository') } | Select-Object -First 1)
    $fixUrl = if ($open.Count -gt 0) { [string](Get-JsonProperty $open[0] 'url') } else { '' }
    if (-not $fixUrl) {
        $body = "Automated attempt to fix pipeline failures on #$originalPr at ``$originalSha``.`n`nThis draft was generated by the pipeline analysis workflow. Its checks run against`n``$defaultBranch``; after validation, the workflow retargets it to the original branch.`n"
        $fixUrl = (Invoke-GhWithTextFile @(
            'pr', 'create', '--repo', $repository, '--head', $fixBranch, '--base',
            $defaultBranch, '--draft', '--title',
            "[pipeline-fix] Automated fix for PR #$originalPr", '--body-file'
        ) $body).Trim()
    }
    $fixNumber = Assert-Number (($fixUrl.TrimEnd('/') -split '/')[-1]) 'fix pull request number'
    Invoke-Gh @('api', '-X', 'POST', "repos/$repository/issues/$fixNumber/labels", '-f', 'labels[]=automated') | Out-Null
    $issues = Get-ApiArray "repos/$repository/issues?state=open&labels=automated&per_page=100"
    $fallback = @($issues | Where-Object { $null -eq $_.PSObject.Properties['pull_request'] -and [string](Get-JsonProperty $_ 'body') -like "*$fixBranch*" } | Select-Object -First 1)
    if ($fallback.Count -gt 0) { Invoke-Gh @('issue', 'close', [string](Get-JsonProperty $fallback[0] 'number'), '--repo', $repository, '--comment', "Superseded by #$fixNumber.") | Out-Null }
    Write-GithubOutput 'fix_number' $fixNumber; Write-GithubOutput 'fix_url' $fixUrl
}

function Invoke-ReportFixAndDispatchValidation {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY'); $defaultBranch = Get-RequiredEnvironmentVariable 'DEFAULT_BRANCH'; $originalPr = Assert-Number (Get-RequiredEnvironmentVariable 'ORIGINAL_PR') 'original pull request number'; $fixNumber = Assert-Number (Get-RequiredEnvironmentVariable 'FIX_NUMBER') 'fix pull request number'; $fixUrl = Get-RequiredEnvironmentVariable 'FIX_URL'
    $markers = Get-AnalysisMarkers; $fixMarker = Get-RequiredEnvironmentVariable 'FIX_SECTION_MARKER'
    Set-FixSection $repository $originalPr $markers $fixMarker (New-FixAddition $fixNumber $fixUrl 'pending' $defaultBranch @())
    Invoke-Gh @('workflow', 'run', 'pipeline-analysis-trigger.yml', '--repo', $repository, '--ref', $defaultBranch, '-f', "fix_pr=$fixNumber") | Out-Null
    Write-Host "Created $fixUrl and dispatched validation."
}

function Invoke-ValidateFix {
    param([Parameter(Mandatory)]$Fix, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$DefaultBranch, [Parameter(Mandatory)][string[]]$Markers, [Parameter(Mandatory)][string]$FixMarker)
    $fixPr = [string](Get-JsonProperty $Fix 'number'); $fixUrl = [string](Get-JsonProperty $Fix 'url'); $fixRef = [string](Get-JsonProperty $Fix 'headRefName'); $fixSha = [string](Get-JsonProperty $Fix 'headRefOid'); $baseRef = [string](Get-JsonProperty $Fix 'baseRefName')
    if ([bool](Get-JsonProperty $Fix 'isCrossRepository')) { Write-Host "#${fixPr}: generated fixes must originate in $Repository; skipping."; return }
    $context = Get-FixBranchContext $fixRef
    if ($null -eq $context) { return }
    $originalPr = $context.OriginalPr; $originalSha = $context.OriginalSha
    $original = Get-PullRequest $repository $originalPr @('headRefName', 'headRefOid', 'state'); $originalRef = [string](Get-JsonProperty $original 'headRefName')
    if ((Get-JsonProperty $original 'state') -ne 'OPEN' -or (Get-JsonProperty $original 'headRefOid') -ne $originalSha) {
        Invoke-Gh @('pr', 'close', $fixPr, '--repo', $repository, '--comment', "Closed because PR #$originalPr moved or closed while this fix was being validated.") | Out-Null
        Set-FixSection $repository $originalPr $Markers $FixMarker (New-FixAddition $fixPr $fixUrl 'stale' '' @()) $fixUrl
        Write-Host "#${fixPr}: closed because original PR #$originalPr is closed or has moved past $originalSha."
        return
    }
    if ($baseRef -ne $DefaultBranch -and $baseRef -ne $originalRef) { Write-Host "#${fixPr}: targets unexpected branch '$baseRef'; skipping."; return }
    $comparison = Get-ApiObject "repos/$repository/compare/$originalSha...$fixSha"
    if ((Get-JsonProperty (Get-JsonProperty $comparison 'merge_base_commit') 'sha') -ne $originalSha -or
        (Get-JsonProperty $comparison 'status') -ne 'ahead') {
        Write-Host "#${fixPr}: head is not a non-empty descendant of the recorded original SHA; skipping."
        return
    }
    $changedPaths = Get-ComparisonFilePaths $comparison
    if ($null -eq $changedPaths) {
        Write-Host "#${fixPr}: changes too many files to verify that they stay under sdk/; skipping."
        return
    }
    if ($changedPaths.Count -eq 0 -or -not (Test-GeneratedFixPaths $changedPaths)) {
        Write-Host "#${fixPr}: changes are empty or extend outside sdk/; skipping."
        return
    }
    if (-not (Test-SuitesComplete $repository $originalSha)) { Write-Host "#${fixPr}: original Azure Pipelines suites are not complete."; return }
    if (-not (Test-SuitesComplete $repository $fixSha)) { Write-Host "#${fixPr}: fix Azure Pipelines suites are not complete."; return }
    $originalRollups = @(Get-AzureRollups $repository $originalSha); $fixRollups = @(Get-AzureRollups $repository $fixSha)
    if ($fixRollups.Count -eq 0) { Write-Host "#${fixPr}: no Azure Pipelines rollups found on $fixSha."; return }
    if (-not (Test-FixRollupsSuccessful $fixRollups)) { Write-Host "#${fixPr}: at least one pipeline did not complete successfully."; Set-FixSection $repository $originalPr $Markers $FixMarker (New-FixAddition $fixPr $fixUrl 'failed' '' @()) $fixUrl; return }
    $failed = @($originalRollups | Where-Object { (Get-JsonProperty $_ 'status') -eq 'completed' -and @('failure', 'timed_out') -contains (Get-JsonProperty $_ 'conclusion') } | ForEach-Object { [string](Get-JsonProperty $_ 'name') })
    if ($failed.Count -eq 0) { Write-Host "#${fixPr}: no failed rollups recorded on $originalSha; nothing to validate."; return }
    foreach ($pipeline in $failed) {
        $matchingRollup = @($fixRollups | Where-Object { (Get-JsonProperty $_ 'name') -eq $pipeline -and (Get-JsonProperty $_ 'status') -eq 'completed' } | Select-Object -First 1)
        $result = if ($matchingRollup.Count -gt 0) { [string](Get-JsonProperty $matchingRollup[0] 'conclusion') } else { '' }
        if ($result -ne 'success') { Write-Host "#${fixPr}: '$pipeline' has not passed on the fix branch yet."; return }
    }
    $addition = New-FixAddition $fixPr $fixUrl 'validated' '' $failed
    $freshOriginal = Get-PullRequest $repository $originalPr @('headRefName', 'headRefOid', 'state'); $freshFix = Get-PullRequest $repository $fixPr @('baseRefName', 'headRefOid', 'state')
    if ((Get-JsonProperty $freshOriginal 'state') -ne 'OPEN' -or (Get-JsonProperty $freshOriginal 'headRefOid') -ne $originalSha -or (Get-JsonProperty $freshOriginal 'headRefName') -ne $originalRef -or (Get-JsonProperty $freshFix 'state') -ne 'OPEN' -or (Get-JsonProperty $freshFix 'headRefOid') -ne $fixSha -or (@($DefaultBranch, $originalRef) -notcontains (Get-JsonProperty $freshFix 'baseRefName'))) { Write-Host "#${fixPr}: a pull request changed during validation; retrying later."; return }
    $retargeted = $false
    if ((Get-JsonProperty $freshFix 'baseRefName') -eq $DefaultBranch) { Invoke-Gh @('api', '-X', 'PATCH', "repos/$repository/pulls/$fixPr", '-f', "base=$originalRef") | Out-Null; $retargeted = $true }
    $freshOriginal = Get-PullRequest $repository $originalPr @('headRefOid', 'state'); $freshFix = Get-PullRequest $repository $fixPr @('baseRefName', 'headRefOid', 'state')
    if ((Get-JsonProperty $freshOriginal 'state') -ne 'OPEN' -or (Get-JsonProperty $freshOriginal 'headRefOid') -ne $originalSha -or (Get-JsonProperty $freshFix 'state') -ne 'OPEN' -or (Get-JsonProperty $freshFix 'headRefOid') -ne $fixSha -or (Get-JsonProperty $freshFix 'baseRefName') -ne $originalRef) { if ($retargeted) { Invoke-Gh @('api', '-X', 'PATCH', "repos/$repository/pulls/$fixPr", '-f', "base=$DefaultBranch") | Out-Null }; Write-Host "#${fixPr}: a pull request changed while retargeting; success was not reported."; return }
    Write-Host "#${fixPr}: validated against '$DefaultBranch' and targets '$originalRef'."; Set-FixSection $repository $originalPr $Markers $FixMarker $addition $fixUrl
}

function Invoke-Validate {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY'); $defaultBranch = Get-RequiredEnvironmentVariable 'DEFAULT_BRANCH'; $target = Get-OptionalEnvironmentVariable 'TARGET_FIX_PR'; $markers = Get-AnalysisMarkers; $fixMarker = Get-RequiredEnvironmentVariable 'FIX_SECTION_MARKER'
    if ($target) {
        $target = Assert-Number $target 'fix pull request number'; Write-Host "Waiting for CI on fix pull request #$target..."
        for ($i = 1; $i -le 120; $i++) { $sha = [string](Get-JsonProperty (Get-PullRequest $repository $target @('headRefOid')) 'headRefOid'); if (Test-SuitesComplete $repository $sha) { Write-Host 'All Azure Pipelines suites have completed.'; break }; Start-Sleep -Seconds 30 }
        $candidate = Get-PullRequest $repository $target @(
            'number', 'baseRefName', 'headRefName', 'headRefOid', 'isCrossRepository', 'url', 'state'
        )
        $candidates = @()
        if ((Get-JsonProperty $candidate 'state') -eq 'OPEN') { $candidates = @($candidate) }
    } else {
        $pulls = Get-ApiArray "repos/$repository/pulls?state=open&per_page=100"
        $candidateNumbers = @($pulls | Where-Object {
            (Get-JsonProperty (Get-JsonProperty $_ 'head') 'ref').StartsWith(
                'copilot-pipeline-fix/', [System.StringComparison]::Ordinal
            )
        } | ForEach-Object { [string](Get-JsonProperty $_ 'number') })
        $candidates = @($candidateNumbers | ForEach-Object {
            Get-PullRequest $repository $_ @(
                'number', 'baseRefName', 'headRefName', 'headRefOid',
                'isCrossRepository', 'url', 'state'
            )
        })
    }
    Write-Host "Checking $($candidates.Count) open fix pull requests."
    foreach ($candidate in $candidates) { Invoke-ValidateFix $candidate $repository $defaultBranch $markers $fixMarker }
}

function Test-BranchExpired {
    param([Parameter(Mandatory)][DateTimeOffset]$Committed, [Parameter(Mandatory)][DateTimeOffset]$Cutoff)
    return $Committed -lt $Cutoff
}

function Invoke-Cleanup {
    $repository = Assert-Repository (Get-RequiredEnvironmentVariable 'REPOSITORY'); $cutoff = [DateTimeOffset]::UtcNow.AddDays(-7)
    $refs = Get-ApiArray "repos/$repository/git/matching-refs/heads/copilot-pipeline-fix/"
    foreach ($reference in $refs) {
        $ref = [string](Get-JsonProperty $reference 'ref'); $branch = $ref -replace '^refs/heads/', ''
        if (-not $branch) { continue }
        # Only branches this workflow could have generated are eligible for deletion; a branch that
        # merely shares the prefix is left alone.
        if ($null -eq (Get-FixBranchContext $branch)) { Write-Host "keep   $branch (not a generated fix branch)"; continue }
        $open = @(ConvertFrom-GhJsonArray (Invoke-Gh @(
            'pr', 'list', '--repo', $repository, '--state', 'open', '--head', $branch,
            '--json', 'number'
        )))
        if ($open.Count -gt 0) { Write-Host "keep   $branch (open PR)"; continue }
        $sha = [string](Get-JsonProperty (Get-JsonProperty $reference 'object') 'sha'); $commitText = Try-Invoke-Gh @('api', "repos/$repository/commits/$sha")
        if ($null -eq $commitText) { continue }
        $commit = Get-JsonProperty (ConvertFrom-GhJson $commitText) 'commit'
        $committed = [string](Get-JsonProperty (Get-JsonProperty $commit 'committer') 'date')
        if (-not $committed) { continue }
        try { $date = [DateTimeOffset]::Parse($committed, [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        if (-not (Test-BranchExpired $date $cutoff)) { Write-Host "keep   $branch ($committed)"; continue }
        Invoke-Gh @('api', '-X', 'DELETE', "repos/$repository/git/refs/heads/$branch") | Out-Null; Write-Host "delete $branch ($committed)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Action) { throw 'Action is required.' }
    switch ($Action) {
        'Dispatch' { Invoke-Dispatch }
        'CloseCheck' { Invoke-CloseCheck }
        'CreateFixPr' { Invoke-CreateFixPr }
        'ReportFixAndDispatchValidation' { Invoke-ReportFixAndDispatchValidation }
        'Validate' { Invoke-Validate }
        'Cleanup' { Invoke-Cleanup }
    }
}