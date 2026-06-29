#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication, Az.Accounts, Az.OperationalInsights

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'conditional-access-not-applied-analysis.config.json'),

    [Parameter()]
    [Nullable[DateTimeOffset]]$StartDateTime,

    [Parameter()]
    [Nullable[DateTimeOffset]]$EndDateTime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..' 'modules' 'SignInReview' 'SignInReview.psd1'
Import-Module $modulePath -Force

try {
    $configurationDocument = Read-ConditionalAccessNotAppliedConfiguration -Path $ConfigPath
    $config = $configurationDocument.Value
    $baseDirectory = $configurationDocument.BaseDirectory

    $kqlTemplatePath = Resolve-SignInReviewPath `
        -Path ([string]$config.Query.KqlTemplatePath) `
        -BaseDirectory $baseDirectory
    $outputRoot = Resolve-SignInReviewPath `
        -Path ([string]$config.Output.Directory) `
        -BaseDirectory $baseDirectory
    $logDirectory = Resolve-SignInReviewPath `
        -Path ([string]$config.Logging.Directory) `
        -BaseDirectory $baseDirectory
    $userExclusionPath = Resolve-SignInReviewPath `
        -Path ([string]$config.Exclusions.UsersPath) `
        -BaseDirectory $baseDirectory
    $appExclusionPath = Resolve-SignInReviewPath `
        -Path ([string]$config.Exclusions.AppsPath) `
        -BaseDirectory $baseDirectory

    [void](Initialize-SignInReviewLog `
        -Directory $logDirectory `
        -Level ([string]$config.Logging.Level) `
        -Prefix 'conditional-access-not-applied-analysis')
    Write-SignInReviewLog Information 'Starting conditional access not-applied alert analysis.'

    $windowEnd = if ($PSBoundParameters.ContainsKey('EndDateTime')) {
        ([DateTimeOffset]$EndDateTime).ToUniversalTime()
    }
    else {
        [DateTimeOffset]::UtcNow
    }
    $windowStart = if ($PSBoundParameters.ContainsKey('StartDateTime')) {
        ([DateTimeOffset]$StartDateTime).ToUniversalTime()
    }
    else {
        $windowEnd.AddDays(-[int]$config.Query.LookbackDays)
    }
    if ($windowEnd -le $windowStart) {
        throw 'EndDateTime must be later than StartDateTime.'
    }

    $query = ConvertTo-ConditionalAccessNotAppliedKql `
        -TemplatePath $kqlTemplatePath `
        -StartDateTime $windowStart `
        -EndDateTime $windowEnd `
        -IncludedUpnSuffixes @($config.AlertScope.IncludedUpnSuffixes) `
        -IncludedUpnRegexPatterns @($config.AlertScope.IncludedUpnRegexPatterns) `
        -ExcludedUpnSuffixes @($config.AlertScope.ExcludedUpnSuffixes) `
        -ExcludedUserPrincipalNames @($config.AlertScope.ExcludedUserPrincipalNames) `
        -ExcludedTokenIssuerTypes @($config.AlertScope.ExcludedTokenIssuerTypes) `
        -IncludeSensitiveDetails ([bool]$config.Query.IncludeSensitiveDetails)

    Connect-SignInReviewAzure `
        -TenantId ([string]$config.TenantId) `
        -SubscriptionId ([string]$config.SubscriptionId)
    $events = @(Invoke-SignInReviewLogAnalyticsQuery `
        -WorkspaceId ([string]$config.WorkspaceId) `
        -Query $query `
        -Timespan ($windowEnd - $windowStart))
    Write-SignInReviewLog Information "Log Analytics returned $($events.Count) candidate row(s)."

    $exclusions = Import-ConditionalAccessExclusion `
        -UsersPath $userExclusionPath `
        -AppsPath $appExclusionPath `
        -AllowMissingFiles ([bool]$config.Exclusions.AllowMissingFiles) `
        -AsOfDateTime $windowEnd
    if ($exclusions.ExpiredCount -gt 0) {
        Write-SignInReviewLog Warning "Ignored $($exclusions.ExpiredCount) expired exclusion row(s)."
    }

    $directoryByUserId = @{}
    $graphState = 'Disabled'
    if ([string]$config.GraphEnrichment.Mode -ne 'Disabled') {
        try {
            Connect-SignInReviewGraph `
                -TenantId ([string]$config.TenantId) `
                -Scopes @('User.Read.All')
            $graphState = 'Available'
            $userIds = @($events | ForEach-Object { ([string]$_.UserId).ToLowerInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique)
            foreach ($userId in $userIds) {
                $directoryByUserId[$userId] = Get-SignInReviewUserById -UserId $userId
            }
            $resolvedCount = @($directoryByUserId.Values |
                Where-Object { $_.Status -eq 'Resolved' }).Count
            Write-SignInReviewLog Information "Graph enrichment resolved $resolvedCount of $($userIds.Count) unique user(s)."
        }
        catch {
            if ([string]$config.GraphEnrichment.Mode -eq 'Required') {
                throw
            }
            $graphState = 'Unavailable'
            $directoryByUserId = @{}
            Write-SignInReviewLog Warning 'Microsoft Graph enrichment was unavailable; continuing without account creation dates.'
        }
    }

    $report = ConvertTo-ConditionalAccessNotAppliedReport `
        -Events $events `
        -DirectoryByUserId $directoryByUserId `
        -GraphEnrichmentState $graphState `
        -Exclusions $exclusions `
        -NewAccountGracePeriodDays ([int]$config.GraphEnrichment.NewAccountGracePeriodDays) `
        -MinimumDistinctDays ([int]$config.RepeatedMatchingSignIn.MinimumDistinctDays) `
        -MinimumEventCount ([int]$config.RepeatedMatchingSignIn.MinimumEventCount) `
        -WindowStartDateTime $windowStart `
        -WindowEndDateTime $windowEnd `
        -IncludeSensitiveDetails ([bool]$config.Query.IncludeSensitiveDetails)

    $runDirectory = Join-Path $outputRoot (
        'conditional-access-not-applied-analysis-{0}' -f $windowEnd.ToString('yyyyMMdd-HHmmssZ')
    )
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

    $priorityOrder = @{ High = 0; Medium = 1; Low = 2 }
    $summarySort = @(
        @{ Expression = { $priorityOrder[[string]$_.ReviewPriority] }; Ascending = $true },
        @{ Expression = { [DateTimeOffset]$_.LastSeen }; Descending = $true }
    )
    $summaryRows = @($report.SummaryRows | Sort-Object -Property $summarySort)
    $summaryColumns = @(
        'UserAlias',
        'AppAlias',
        'UserPrincipalName',
        'DisplayName',
        'UserId',
        'AppDisplayName',
        'AppId',
        'UserCreatedDateTime',
        'AccountAgeDaysAtLastSeen',
        'SignInCount',
        'DistinctDetectionDays',
        'InteractiveSignInCount',
        'NonInteractiveSignInCount',
        'FirstSeen',
        'LastSeen',
        'Category',
        'CategoryJa',
        'ReasonCode',
        'EstimatedCauseJa',
        'RecommendedActionJa',
        'ReviewPriority',
        'ReviewPriorityJa',
        'RecheckAfterDateTime',
        'IsRecentAccountCandidate',
        'IsRepeatedMatchingSignIn',
        'GraphEnrichmentStatus',
        'EvaluationWindowStartDateTime',
        'EvaluationWindowEndDateTime'
    )
    Export-SignInReviewCsv `
        -Rows $summaryRows `
        -Path (Join-Path $runDirectory 'summary.csv') `
        -Columns $summaryColumns

    if ([bool]$config.Output.GenerateDetailsCsv) {
        $detailColumns = [Collections.Generic.List[string]]@(
            'TimeGenerated',
            'EventId',
            'UserAlias',
            'AppAlias',
            'UserPrincipalName',
            'UserId',
            'AppDisplayName',
            'AppId',
            'ClientAppUsed',
            'ConditionalAccessStatus',
            'PolicyResults',
            'ResultType',
            'ResultDescription',
            'IsInteractive',
            'Category',
            'CategoryJa',
            'ReviewHintJa'
        )
        if ([bool]$config.Query.IncludeSensitiveDetails) {
            foreach ($column in @(
                'CorrelationId',
                'IPAddress',
                'Location',
                'LocationDetailsJson',
                'DeviceDetailJson',
                'UserAgent'
            )) {
                $detailColumns.Add($column)
            }
        }
        Export-SignInReviewCsv `
            -Rows @($report.DetailRows | Sort-Object TimeGenerated) `
            -Path (Join-Path $runDirectory 'details.csv') `
            -Columns $detailColumns.ToArray()
    }

    $excludedColumns = @(
        'UserAlias',
        'AppAlias',
        'UserPrincipalName',
        'UserId',
        'AppDisplayName',
        'AppId',
        'SignInCount',
        'FirstSeen',
        'LastSeen',
        'ExcludedBy',
        'ExcludeReason',
        'ExclusionExpiresOn'
    )
    Export-SignInReviewCsv `
        -Rows @($report.ExcludedRows | Sort-Object LastSeen -Descending) `
        -Path (Join-Path $runDirectory 'excluded.csv') `
        -Columns $excludedColumns

    if ([bool]$config.Output.GenerateAiPromptMarkdown) {
        $aiMarkdown = ConvertTo-ConditionalAccessAiMarkdown `
            -SummaryRows $summaryRows `
            -ExcludedRows $report.ExcludedRows `
            -WindowStartDateTime $windowStart `
            -WindowEndDateTime $windowEnd `
            -IdentityMode ([string]$config.Output.AiIdentityMode) `
            -MaximumTopItems ([int]$config.Output.AiMaximumTopItems)
        Set-Content `
            -LiteralPath (Join-Path $runDirectory 'ai-prompt.md') `
            -Value $aiMarkdown `
            -Encoding utf8
    }

    if ([bool]$config.Output.GenerateChecklistMarkdown) {
        $checklistMarkdown = ConvertTo-ConditionalAccessChecklistMarkdown `
            -WindowStartDateTime $windowStart `
            -WindowEndDateTime $windowEnd `
            -NewAccountGracePeriodDays ([int]$config.GraphEnrichment.NewAccountGracePeriodDays) `
            -MinimumDistinctDays ([int]$config.RepeatedMatchingSignIn.MinimumDistinctDays) `
            -MinimumEventCount ([int]$config.RepeatedMatchingSignIn.MinimumEventCount)
        Set-Content `
            -LiteralPath (Join-Path $runDirectory 'checklist.md') `
            -Value $checklistMarkdown `
            -Encoding utf8
    }

    Write-SignInReviewLog Information "Wrote $($summaryRows.Count) summary row(s), $($report.DetailRows.Count) detail row(s), and $($report.ExcludedRows.Count) excluded row(s) to $runDirectory."
    Write-SignInReviewLog Information "Deduplicated $($report.DuplicateEventCount) repeated event row(s) by sign-in event ID."
    Write-SignInReviewLog Information 'Completed successfully. No alert, policy, account, group, application, or Workspace changes were performed.'
}
catch {
    Write-SignInReviewLog Error "Execution failed: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-SignInReviewGraph
}
