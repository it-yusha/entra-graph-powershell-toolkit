BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repositoryRoot 'modules' 'SignInReview' 'SignInReview.psd1'
    $configPath = Join-Path $repositoryRoot 'config' 'conditional-access-not-applied-analysis.config.example.json'
    $kqlPath = Join-Path $repositoryRoot 'kql' 'conditional-access-not-applied-analysis.kql'
    $scriptPath = Join-Path $repositoryRoot 'scripts' 'Get-ConditionalAccessNotAppliedAnalysisFromLogAnalytics.ps1'
    $summarySamplePath = Join-Path $repositoryRoot 'samples' 'conditional-access-not-applied-summary.sample.csv'
    $detailsSamplePath = Join-Path $repositoryRoot 'samples' 'conditional-access-not-applied-details.sample.csv'
    $excludedSamplePath = Join-Path $repositoryRoot 'samples' 'conditional-access-not-applied-excluded.sample.csv'
    $aiSamplePath = Join-Path $repositoryRoot 'samples' 'conditional-access-not-applied-ai-prompt.sample.md'
    Import-Module $modulePath -Force

    function New-AlertEvent {
        param(
            [string]$Id = 'event-001',
            [string]$TimeGenerated = '2026-06-28T00:00:00Z',
            [string]$UserId = '10000000-0000-0000-0000-000000000001',
            [string]$UserPrincipalName = 'alex.taylor@example.invalid',
            [string]$AppId = '00000000-0000-0000-0000-000000000002',
            [string]$AppDisplayName = 'Example Business Application',
            [bool]$IsInteractive = $true
        )
        return [pscustomobject]@{
            TimeGenerated          = $TimeGenerated
            Id                     = $Id
            CorrelationId          = '30000000-0000-0000-0000-000000000001'
            UserPrincipalName      = $UserPrincipalName
            UserId                 = $UserId
            UserDisplayName        = 'Alex Taylor'
            AppDisplayName         = $AppDisplayName
            AppId                  = $AppId
            ClientAppUsed          = 'Browser'
            ConditionalAccessStatus = 'notApplied'
            PolicyResults          = @('notApplied')
            ResultType             = '0'
            ResultDescription      = 'Success'
            IsInteractive          = $IsInteractive
            TokenIssuerType        = 'AzureAD'
        }
    }

    function New-EmptyExclusions {
        return [pscustomobject]@{
            UsersById    = @{}
            UsersByUpn   = @{}
            AppsById     = @{}
            ExpiredCount = 0
        }
    }

    function New-DirectoryMap {
        param([string]$CreatedDateTime = '2026-06-26T00:00:00Z')
        return @{
            '10000000-0000-0000-0000-000000000001' = [pscustomobject]@{
                Status = 'Resolved'
                User   = [pscustomobject]@{
                    id                = '10000000-0000-0000-0000-000000000001'
                    userPrincipalName = 'alex.taylor@example.invalid'
                    displayName       = 'Alex Taylor'
                    accountEnabled    = $true
                    createdDateTime   = $CreatedDateTime
                }
            }
        }
    }
}

Describe 'Conditional access not-applied configuration and KQL' {
    It 'validates the public example configuration' {
        $document = Read-ConditionalAccessNotAppliedConfiguration -Path $configPath
        $document.Value.Query.LookbackDays | Should -Be 7
        $document.Value.GraphEnrichment.Mode | Should -Be 'Optional'
        $document.Value.Query.IncludeSensitiveDetails | Should -BeFalse
    }

    It 'renders the alert semantics without sensitive detail fields by default' {
        $query = ConvertTo-ConditionalAccessNotAppliedKql `
            -TemplatePath $kqlPath `
            -StartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -EndDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z') `
            -IncludedUpnSuffixes @('@example.invalid') `
            -IncludedUpnRegexPatterns @('^[a-z][0-9]{6}@example\.invalid$') `
            -ExcludedUpnSuffixes @('#EXT#@example.invalid') `
            -ExcludedUserPrincipalNames @('excluded@example.invalid') `
            -ExcludedTokenIssuerTypes @('AzureADBackupAuth') `
            -IncludeSensitiveDetails $false

        $query | Should -Not -Match '\{\{[A-Z0-9_]+\}\}'
        $query | Should -Match 'ConditionalAccessStatus == "notApplied"'
        $query | Should -Match 'tostring\(ResultType\) == "0"'
        $query | Should -Match 'set_has_element\(PolicyResults, "notApplied"\)'
        $query | Should -Not -Match 'CorrelationId|IPAddress|LocationDetailsJson|DeviceDetailJson|UserAgent'
    }

    It 'adds sensitive detail fields only when explicitly enabled' {
        $query = ConvertTo-ConditionalAccessNotAppliedKql `
            -TemplatePath $kqlPath `
            -StartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -EndDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z') `
            -IncludedUpnSuffixes @('@example.invalid') `
            -IncludedUpnRegexPatterns @() `
            -ExcludedUpnSuffixes @() `
            -ExcludedUserPrincipalNames @() `
            -ExcludedTokenIssuerTypes @() `
            -IncludeSensitiveDetails $true

        $query | Should -Match 'IPAddress = take_any'
        $query | Should -Match 'DeviceDetailJson'
        $query | Should -Match 'UserAgent'
    }
}

Describe 'Conditional access exclusions' {
    It 'loads active user and app exclusions and ignores expired rows' {
        $usersPath = Join-Path $TestDrive 'users.csv'
        $appsPath = Join-Path $TestDrive 'apps.csv'
        @'
UserId,UserPrincipalName,Reason,ExpiresOn
10000000-0000-0000-0000-000000000001,alex.taylor@example.invalid,Temporary exclusion,2027-12-31
10000000-0000-0000-0000-000000000002,old@example.invalid,Expired exclusion,2025-01-01
'@ | Set-Content -LiteralPath $usersPath -Encoding utf8
        @'
AppId,Reason,ExpiresOn
00000000-0000-0000-0000-000000000002,Approved app,2027-12-31
'@ | Set-Content -LiteralPath $appsPath -Encoding utf8

        $result = Import-ConditionalAccessExclusion `
            -UsersPath $usersPath `
            -AppsPath $appsPath `
            -AllowMissingFiles $false `
            -AsOfDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z')

        $result.UsersById.Count | Should -Be 1
        $result.AppsById.Count | Should -Be 1
        $result.ExpiredCount | Should -Be 1
    }
}

Describe 'Conditional access report classification' {
    It 'classifies a recently created account as provisioning-related without asserting new-hire status' {
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events @((New-AlertEvent)) `
            -DirectoryByUserId (New-DirectoryMap) `
            -GraphEnrichmentState Available `
            -Exclusions (New-EmptyExclusions) `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false

        $report.SummaryRows.Count | Should -Be 1
        $report.SummaryRows[0].Category | Should -Be 'LikelyRecentAccountProvisioning'
        $report.SummaryRows[0].CategoryJa | Should -Be '新規作成アカウントの設定途中の可能性'
        $report.SummaryRows[0].ReviewPriority | Should -Be 'Low'
    }

    It 'classifies distinct matching events across multiple days as repeated' {
        $events = @(
            New-AlertEvent -Id 'event-001' -TimeGenerated '2026-06-24T00:00:00Z'
            New-AlertEvent -Id 'event-002' -TimeGenerated '2026-06-27T00:00:00Z'
        )
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events $events `
            -DirectoryByUserId (New-DirectoryMap -CreatedDateTime '2025-01-01T00:00:00Z') `
            -GraphEnrichmentState Available `
            -Exclusions (New-EmptyExclusions) `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false

        $report.SummaryRows[0].Category | Should -Be 'RepeatedMatchingSignIn'
        $report.SummaryRows[0].DistinctDetectionDays | Should -Be 2
        $report.SummaryRows[0].ReviewPriority | Should -Be 'High'
    }

    It 'deduplicates overlapping stateless alert windows by sign-in event ID' {
        $event = New-AlertEvent
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events @($event, $event) `
            -DirectoryByUserId @{} `
            -GraphEnrichmentState Disabled `
            -Exclusions (New-EmptyExclusions) `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false

        $report.SummaryRows[0].SignInCount | Should -Be 1
        $report.DuplicateEventCount | Should -Be 1
    }

    It 'classifies an old account with only non-interactive events separately' {
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events @((New-AlertEvent -IsInteractive $false)) `
            -DirectoryByUserId (New-DirectoryMap -CreatedDateTime '2025-01-01T00:00:00Z') `
            -GraphEnrichmentState Available `
            -Exclusions (New-EmptyExclusions) `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false

        $report.SummaryRows[0].Category | Should -Be 'NonInteractiveOnly'
    }

    It 'moves configured exclusions out of the main summary' {
        $exclusions = New-EmptyExclusions
        $exclusions.UsersById['10000000-0000-0000-0000-000000000001'] = [pscustomobject]@{
            Source = 'ExcludeUsers'
            Reason = 'Approved test exclusion'
            ExpiresOn = '2027-12-31'
        }
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events @((New-AlertEvent)) `
            -DirectoryByUserId @{} `
            -GraphEnrichmentState Disabled `
            -Exclusions $exclusions `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false

        $report.SummaryRows.Count | Should -Be 0
        $report.DetailRows.Count | Should -Be 0
        $report.ExcludedRows.Count | Should -Be 1
        $report.ExcludedRows[0].ExcludedBy | Should -Be 'ExcludeUsers'
    }
}

Describe 'AI markdown privacy and source safety' {
    It 'uses aliases and omits raw identities by default' {
        $report = ConvertTo-ConditionalAccessNotAppliedReport `
            -Events @((New-AlertEvent)) `
            -DirectoryByUserId @{} `
            -GraphEnrichmentState Disabled `
            -Exclusions (New-EmptyExclusions) `
            -NewAccountGracePeriodDays 5 `
            -MinimumDistinctDays 2 `
            -MinimumEventCount 2 `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IncludeSensitiveDetails $false
        $markdown = ConvertTo-ConditionalAccessAiMarkdown `
            -SummaryRows $report.SummaryRows `
            -ExcludedRows $report.ExcludedRows `
            -WindowStartDateTime ([DateTimeOffset]'2026-06-21T00:00:00Z') `
            -WindowEndDateTime ([DateTimeOffset]'2026-06-28T12:00:00Z') `
            -IdentityMode Alias `
            -MaximumTopItems 10

        $markdown | Should -Match 'User-001'
        $markdown | Should -Match 'App-001'
        $markdown | Should -Not -Match 'alex\.taylor@example\.invalid'
        $markdown | Should -Not -Match 'Example Business Application'
    }

    It 'contains no Entra, alert, or Azure mutation commands' {
        $source = @(
            Get-Content -LiteralPath $scriptPath -Raw
            Get-Content -LiteralPath (Join-Path $repositoryRoot 'modules' 'SignInReview' 'ConditionalAccessAnalysis.ps1') -Raw
        ) -join "`n"
        $source | Should -Not -Match '(?i)\b(?:Update|Remove|New|Set|Revoke|Restore)-Mg'
        $source | Should -Not -Match '(?i)Invoke-MgGraphRequest[^\r\n]+-Method\s+(?:POST|PUT|PATCH|DELETE)'
        $source | Should -Not -Match '(?i)\b(?:New|Set|Remove)-Az(?:ScheduledQueryRule|OperationalInsights|ADUser)'
    }

    It 'publishes only dummy sample identities and omits sensitive detail columns' {
        $summaryRows = @(Import-Csv -LiteralPath $summarySamplePath)
        $detailRows = @(Import-Csv -LiteralPath $detailsSamplePath)
        $excludedRows = @(Import-Csv -LiteralPath $excludedSamplePath)
        foreach ($row in @($summaryRows + $detailRows + $excludedRows)) {
            $row.UserPrincipalName | Should -Match '@example\.invalid$'
        }
        $detailRows[0].PSObject.Properties.Name | Should -Not -Contain 'IPAddress'
        $detailRows[0].PSObject.Properties.Name | Should -Not -Contain 'UserAgent'
        $detailRows[0].PSObject.Properties.Name | Should -Not -Contain 'CorrelationId'
        (Get-Content -LiteralPath $aiSamplePath -Raw) | Should -Not -Match '@example\.invalid'
    }

    It 'ignores real configuration and exclusion file names' {
        $gitignore = Get-Content -LiteralPath (Join-Path $repositoryRoot '.gitignore') -Raw
        $gitignore | Should -Match 'config/\*\.config\.json'
        $gitignore | Should -Match 'config/conditional-access-exclude-users\.csv'
        $gitignore | Should -Match 'config/conditional-access-exclude-apps\.csv'
    }
}
