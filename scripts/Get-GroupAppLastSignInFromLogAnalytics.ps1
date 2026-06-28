#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication, Az.Accounts, Az.OperationalInsights

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'group-app-last-signin.loganalytics.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..' 'modules' 'SignInReview' 'SignInReview.psd1'
Import-Module $modulePath -Force

try {
    $configurationDocument = Read-SignInReviewConfiguration -Path $ConfigPath
    $config = $configurationDocument.Value
    $baseDirectory = $configurationDocument.BaseDirectory

    $logDirectory = Resolve-SignInReviewPath -Path ([string]$config.Logging.Directory) -BaseDirectory $baseDirectory
    [void](Initialize-SignInReviewLog `
        -Directory $logDirectory `
        -Level ([string]$config.Logging.Level) `
        -Prefix 'group-app-last-signin-loganalytics')

    Write-SignInReviewLog Information 'Starting Log Analytics app last-sign-in report.'
    Connect-SignInReviewAzure `
        -TenantId ([string]$config.TenantId) `
        -SubscriptionId ([string]$config.SubscriptionId)
    Connect-SignInReviewGraph -TenantId ([string]$config.TenantId)

    $checkedAt = [DateTimeOffset]::UtcNow
    $windowStart = $checkedAt.AddDays(-[int]$config.Query.LookbackDays)
    $queryTimespan = $checkedAt - $windowStart
    $kqlTemplatePath = Resolve-SignInReviewPath `
        -Path ([string]$config.Query.KqlTemplatePath) `
        -BaseDirectory $baseDirectory
    $outputPath = Resolve-SignInReviewPath `
        -Path ([string]$config.Output.CsvPath) `
        -BaseDirectory $baseDirectory

    $users = @(Get-SignInReviewGroupUser `
        -GroupId ([string]$config.GroupId) `
        -MembershipMode ([string]$config.MembershipMode))
    Write-SignInReviewLog Information "Retrieved $($users.Count) current user member(s) from Microsoft Graph."

    $lastInteractiveByUserId = @{}
    $lastNonInteractiveByUserId = @{}
    if ($users.Count -gt 0) {
        $userBatches = @(Split-SignInReviewBatch -InputObject $users -Size ([int]$config.Query.BatchSize))
        $tableNames = [Collections.Generic.List[string]]::new()
        $tableNames.Add('SigninLogs')
        if ([bool]$config.Query.IncludeNonInteractiveSignIns) {
            $tableNames.Add('AADNonInteractiveUserSignInLogs')
        }
        Write-SignInReviewLog Information "Querying $($tableNames.Count) Log Analytics table(s) in $($userBatches.Count) user batch(es)."

        $batchNumber = 0
        foreach ($batch in $userBatches) {
            $batchNumber++
            foreach ($tableName in $tableNames) {
                $query = ConvertTo-SignInReviewKql `
                    -TemplatePath $kqlTemplatePath `
                    -UserIds @($batch | ForEach-Object { [string]$_.id }) `
                    -AppId ([string]$config.TargetApp.AppId) `
                    -StartDateTime $windowStart `
                    -EndDateTime $checkedAt `
                    -TableName $tableName

                $queryResults = @(Invoke-SignInReviewLogAnalyticsQuery `
                    -WorkspaceId ([string]$config.WorkspaceId) `
                    -Query $query `
                    -Timespan $queryTimespan)
                Write-SignInReviewLog Information "Batch $batchNumber from $tableName returned $($queryResults.Count) aggregated row(s)."

                foreach ($queryResult in $queryResults) {
                    $userId = ([string]$queryResult.UserId).ToLowerInvariant()
                    if ([string]::IsNullOrWhiteSpace($userId) -or $null -eq $queryResult.LastSignInDateTime) {
                        continue
                    }
                    $timestamp = [DateTimeOffset]$queryResult.LastSignInDateTime
                    $targetMap = if ($tableName -eq 'SigninLogs') {
                        $lastInteractiveByUserId
                    }
                    else {
                        $lastNonInteractiveByUserId
                    }
                    if (-not $targetMap.ContainsKey($userId) -or $timestamp -gt $targetMap[$userId]) {
                        $targetMap[$userId] = $timestamp
                    }
                }
            }
        }
    }
    else {
        Write-SignInReviewLog Warning 'The group query returned no users. Log Analytics was not queried.'
    }

    $columns = @(
        'UserPrincipalName',
        'DisplayName',
        'UserId',
        'AppDisplayName',
        'AppId',
        'LastSignInDateTime',
        'SignInFound',
        'CheckedDateTime',
        'Note',
        'LastInteractiveSignInDateTime',
        'LastNonInteractiveSignInDateTime',
        'SignInFoundJa',
        'QueriedSignInTypes',
        'QueriedSignInTypesJa',
        'SignInPattern',
        'SignInPatternJa',
        'EvaluationWindowStartDateTime',
        'EvaluationWindowEndDateTime',
        'NoteJa'
    )
    $rows = @(ConvertTo-GroupAppSignInReportRow `
        -Users $users `
        -LastInteractiveByUserId $lastInteractiveByUserId `
        -LastNonInteractiveByUserId $lastNonInteractiveByUserId `
        -IncludeNonInteractiveSignIns ([bool]$config.Query.IncludeNonInteractiveSignIns) `
        -AppDisplayName ([string]$config.TargetApp.DisplayName) `
        -AppId ([string]$config.TargetApp.AppId) `
        -EvaluationWindowStartDateTime $windowStart `
        -EvaluationWindowEndDateTime $checkedAt `
        -CheckedDateTime $checkedAt)

    $sortedRows = @($rows | Sort-Object UserPrincipalName, UserId)
    Export-SignInReviewCsv -Rows $sortedRows -Path $outputPath -Columns $columns
    Write-SignInReviewLog Information "Wrote $($sortedRows.Count) minimal report row(s) to $outputPath."
    Write-SignInReviewLog Information 'Completed successfully.'
}
catch {
    Write-SignInReviewLog Error "Execution failed: $($_.Exception.Message)"
    throw
}
finally {
    Disconnect-SignInReviewGraph
}
