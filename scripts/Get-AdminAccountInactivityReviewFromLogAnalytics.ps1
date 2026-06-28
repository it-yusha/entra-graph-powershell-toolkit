#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication, Az.Accounts, Az.OperationalInsights

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'admin-account-inactivity-review.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..' 'modules' 'SignInReview' 'SignInReview.psd1'
Import-Module $modulePath -Force

try {
    $configurationDocument = Read-AdminAccountInactivityConfiguration -Path $ConfigPath
    $config = $configurationDocument.Value
    $baseDirectory = $configurationDocument.BaseDirectory

    $inputPath = Resolve-SignInReviewPath -Path ([string]$config.Input.CsvPath) -BaseDirectory $baseDirectory
    $kqlTemplatePath = Resolve-SignInReviewPath `
        -Path ([string]$config.Evaluation.KqlTemplatePath) `
        -BaseDirectory $baseDirectory
    $outputDirectory = Resolve-SignInReviewPath `
        -Path ([string]$config.Output.Directory) `
        -BaseDirectory $baseDirectory
    $logDirectory = Resolve-SignInReviewPath `
        -Path ([string]$config.Logging.Directory) `
        -BaseDirectory $baseDirectory

    [void](Initialize-SignInReviewLog `
        -Directory $logDirectory `
        -Level ([string]$config.Logging.Level) `
        -Prefix 'admin-account-inactivity-review')

    Write-SignInReviewLog Information 'Starting administrator account inactivity review.'
    $inputRows = @(Import-AdminAccountReviewInput `
        -Path $inputPath `
        -DefaultInactiveThresholdDays ([int]$config.Evaluation.DefaultInactiveThresholdDays) `
        -LookbackDays ([int]$config.Evaluation.LookbackDays) `
        -PassthroughColumns @($config.Input.PassthroughColumns))
    Write-SignInReviewLog Information "Loaded $($inputRows.Count) administrator account row(s)."

    Connect-SignInReviewAzure `
        -TenantId ([string]$config.TenantId) `
        -SubscriptionId ([string]$config.SubscriptionId)
    Connect-SignInReviewGraph `
        -TenantId ([string]$config.TenantId) `
        -Scopes @('User.Read.All')

    $reportGeneratedAt = [DateTimeOffset]::UtcNow
    $queryWindowStart = $reportGeneratedAt.AddDays(-[int]$config.Evaluation.LookbackDays)
    $configuredCoverageStart = [DateTimeOffset]$config.Evaluation.EvidenceCoverageStartDateTime
    $evidenceWindowStart = if ($configuredCoverageStart -gt $queryWindowStart) {
        $configuredCoverageStart
    }
    else {
        $queryWindowStart
    }
    $queryTimespan = $reportGeneratedAt - $queryWindowStart

    $directoryByInputUpn = @{}
    $eligibleUsers = [Collections.Generic.List[object]]::new()
    foreach ($inputRow in $inputRows) {
        $upnKey = ([string]$inputRow.InputUserPrincipalName).ToLowerInvariant()
        $directoryResult = Get-SignInReviewUserByUpn `
            -UserPrincipalName ([string]$inputRow.InputUserPrincipalName)
        $directoryByInputUpn[$upnKey] = $directoryResult

        if ([bool]$inputRow.ExcludeFromInactiveCheck -or $directoryResult.Status -ne 'Resolved') {
            continue
        }
        $enabledProperty = $directoryResult.User.PSObject.Properties['accountEnabled']
        if ($enabledProperty -and $null -ne $enabledProperty.Value -and [bool]$enabledProperty.Value) {
            $eligibleUsers.Add($directoryResult.User)
        }
    }
    $resolvedCount = @($directoryByInputUpn.Values | Where-Object { $_.Status -eq 'Resolved' }).Count
    Write-SignInReviewLog Information "Resolved $resolvedCount account(s); $($eligibleUsers.Count) enabled, non-excluded account(s) require log queries."

    $lastInteractiveByUserId = @{}
    $lastNonInteractiveByUserId = @{}
    if ($eligibleUsers.Count -gt 0) {
        $batches = @(Split-SignInReviewBatch `
            -InputObject $eligibleUsers.ToArray() `
            -Size ([int]$config.Evaluation.BatchSize))
        $tableDefinitions = @(
            [pscustomobject]@{
                Name = 'SigninLogs'
                Map  = $lastInteractiveByUserId
            },
            [pscustomobject]@{
                Name = 'AADNonInteractiveUserSignInLogs'
                Map  = $lastNonInteractiveByUserId
            }
        )
        Write-SignInReviewLog Information "Querying two Log Analytics tables in $($batches.Count) user batch(es)."

        $batchNumber = 0
        foreach ($batch in $batches) {
            $batchNumber++
            $userIds = @($batch | ForEach-Object { [string]$_.id })
            foreach ($tableDefinition in $tableDefinitions) {
                $query = ConvertTo-AdminAccountSignInKql `
                    -TemplatePath $kqlTemplatePath `
                    -UserIds $userIds `
                    -StartDateTime $queryWindowStart `
                    -EndDateTime $reportGeneratedAt `
                    -TableName $tableDefinition.Name
                $queryResults = @(Invoke-SignInReviewLogAnalyticsQuery `
                    -WorkspaceId ([string]$config.WorkspaceId) `
                    -Query $query `
                    -Timespan $queryTimespan)
                Write-SignInReviewLog Information "Batch $batchNumber from $($tableDefinition.Name) returned $($queryResults.Count) aggregated row(s)."

                foreach ($queryResult in $queryResults) {
                    $userId = ([string]$queryResult.UserId).ToLowerInvariant()
                    if ([string]::IsNullOrWhiteSpace($userId) -or $null -eq $queryResult.LastSignInDateTime) {
                        continue
                    }
                    $timestamp = [DateTimeOffset]$queryResult.LastSignInDateTime
                    $targetMap = [hashtable]$tableDefinition.Map
                    if (-not $targetMap.ContainsKey($userId) -or $timestamp -gt $targetMap[$userId]) {
                        $targetMap[$userId] = $timestamp
                    }
                }
            }
        }
    }
    else {
        Write-SignInReviewLog Warning 'No enabled, non-excluded, resolved accounts require a Log Analytics query.'
    }

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($inputRow in $inputRows) {
        $upnKey = ([string]$inputRow.InputUserPrincipalName).ToLowerInvariant()
        $directoryResult = $directoryByInputUpn[$upnKey]
        $userId = if ($directoryResult.Status -eq 'Resolved') {
            ([string]$directoryResult.User.id).ToLowerInvariant()
        }
        else {
            ''
        }
        $rows.Add((ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord $inputRow `
            -DirectoryResult $directoryResult `
            -LastInteractiveSignInDateTime $lastInteractiveByUserId[$userId] `
            -LastNonInteractiveSignInDateTime $lastNonInteractiveByUserId[$userId] `
            -EvidenceWindowStartDateTime $evidenceWindowStart `
            -ReportGeneratedDateTime $reportGeneratedAt))
    }

    $statusOrder = @{
        InactiveCandidate = 0
        ReviewRequired    = 1
        Active            = 2
        AlreadyDisabled   = 3
        Excluded          = 4
    }
    $sortedRows = @($rows | Sort-Object `
        @{ Expression = { $statusOrder[[string]$_.ReviewStatus] } }, `
        InputUserPrincipalName)

    $columns = @(
        'InputUserPrincipalName',
        'UserPrincipalName',
        'DisplayName',
        'UserId',
        'AccountEnabled',
        'CreatedDateTime',
        'Owner',
        'Purpose',
        'AccountType',
        'InputNote',
        'LastInteractiveSignInDateTime',
        'DaysSinceLastInteractiveSignIn',
        'LastNonInteractiveSignInDateTime',
        'DaysSinceLastNonInteractiveSignIn',
        'LastAnyUserSignInDateTime',
        'DaysSinceLastAnyUserSignIn',
        'InactiveThresholdDays',
        'ExcludeFromInactiveCheck',
        'EvidenceWindowStartDateTime',
        'DirectoryLookupStatus',
        'DirectoryLookupStatusJa',
        'SignInPattern',
        'SignInPatternJa',
        'ReviewStatus',
        'ReviewStatusJa',
        'ReviewReasonCode',
        'ReviewReason',
        'ReviewReasonJa',
        'RecommendedAction',
        'ReportGeneratedDateTime'
    )
    $outputFileName = '{0}-{1}.csv' -f (
        [string]$config.Output.FileNamePrefix,
        $reportGeneratedAt.ToString('yyyyMMdd-HHmmss')
    )
    $outputPath = Join-Path $outputDirectory $outputFileName
    Export-SignInReviewCsv -Rows $sortedRows -Path $outputPath -Columns $columns
    Write-SignInReviewLog Information "Wrote $($sortedRows.Count) review row(s) to $outputPath."
    Write-SignInReviewLog Information 'Completed successfully. No account changes were performed.'
}
catch {
    Write-SignInReviewLog Error "Execution failed: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-SignInReviewGraph
}
