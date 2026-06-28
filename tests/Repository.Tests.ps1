BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repositoryRoot 'modules' 'SignInReview' 'SignInReview.psd1'
    $graphConfigPath = Join-Path $repositoryRoot 'config' 'config.example.json'
    $graphSamplePath = Join-Path $repositoryRoot 'samples' 'sample-output.csv'
    $logConfigPath = Join-Path $repositoryRoot 'config' 'group-app-last-signin.loganalytics.config.example.json'
    $logSamplePath = Join-Path $repositoryRoot 'samples' 'group-app-last-signin-loganalytics.sample.csv'
    $adminConfigPath = Join-Path $repositoryRoot 'config' 'admin-account-inactivity-review.config.example.json'
    $adminInputPath = Join-Path $repositoryRoot 'samples' 'admin-accounts.sample.csv'
    $adminOutputPath = Join-Path $repositoryRoot 'samples' 'admin-account-inactivity-review.sample.csv'
    $kqlPath = Join-Path $repositoryRoot 'kql' 'group-app-last-signin.kql'

    $graphColumns = @(
        'UserPrincipalName', 'DisplayName', 'UserId', 'CurrentGroupMember',
        'AppDisplayName', 'AppId', 'LastSignInDateTime',
        'LastSeenInCurrentRun', 'LastCheckedDateTime', 'Note'
    )
    $logAnalyticsColumns = @(
        'UserPrincipalName', 'DisplayName', 'UserId', 'AppDisplayName', 'AppId',
        'LastSignInDateTime', 'SignInFound', 'CheckedDateTime', 'Note',
        'LastInteractiveSignInDateTime', 'LastNonInteractiveSignInDateTime',
        'SignInFoundJa', 'QueriedSignInTypes', 'QueriedSignInTypesJa',
        'SignInPattern', 'SignInPatternJa', 'EvaluationWindowStartDateTime',
        'EvaluationWindowEndDateTime', 'NoteJa'
    )

    Import-Module $modulePath -Force
}

Describe 'PowerShell source' {
    It 'has no parser errors in scripts or modules' {
        $files = Get-ChildItem `
            (Join-Path $repositoryRoot 'scripts'), (Join-Path $repositoryRoot 'modules') `
            -Recurse -Include '*.ps1', '*.psm1', '*.psd1'

        $allErrors = foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$errors
            )
            $errors
        }
        $allErrors | Should -BeNullOrEmpty
    }
}

Describe 'Graph example artifacts' {
    It 'contains the supported sample schema' {
        $config = Get-Content -LiteralPath $graphConfigPath -Raw | ConvertFrom-Json
        $config.SchemaVersion | Should -Be '1.0'
        $config.MembershipMode | Should -BeIn @('Direct', 'Transitive')
        $config.Output.RemovedMemberHandling | Should -BeIn @('Retain', 'Exclude')
        { [Guid]::Parse($config.GroupId) } | Should -Not -Throw
        { [Guid]::Parse($config.TargetApp.AppId) } | Should -Not -Throw
    }

    It 'has the documented CSV columns and dummy identities' {
        $rows = @(Import-Csv -LiteralPath $graphSamplePath)
        $rows.Count | Should -BeGreaterThan 0
        ($rows[0].PSObject.Properties.Name -join ',') | Should -Be ($graphColumns -join ',')
        foreach ($row in $rows) {
            $row.UserPrincipalName | Should -Match '@example\.invalid$'
        }
    }
}

Describe 'Log Analytics example artifacts' {
    It 'validates the public configuration' {
        $document = Read-SignInReviewConfiguration -Path $logConfigPath
        $document.Value.SchemaVersion | Should -Be '1.0'
        $document.Value.MembershipMode | Should -Be 'Transitive'
        $document.Value.Query.BatchSize | Should -Be 500
        $document.Value.Query.IncludeNonInteractiveSignIns | Should -BeTrue
    }

    It 'renders allow-listed KQL without unresolved tokens' {
        $query = ConvertTo-SignInReviewKql `
            -TemplatePath $kqlPath `
            -UserIds @(
                '10000000-0000-0000-0000-000000000001',
                '10000000-0000-0000-0000-000000000002'
            ) `
            -AppId '00000000-0000-0000-0000-000000000002' `
            -StartDateTime ([DateTimeOffset]'2026-01-01T00:00:00Z') `
            -EndDateTime ([DateTimeOffset]'2026-06-01T00:00:00Z') `
            -TableName 'SigninLogs'

        $query | Should -Not -Match '\{\{[A-Z0-9_]+\}\}'
        $query | Should -Match '(?m)^SigninLogs$'
        $query | Should -Match 'summarize LastSignInDateTime = max\(TimeGenerated\)'
        $query | Should -Match '10000000-0000-0000-0000-000000000001'
        $query | Should -Not -Match 'IPAddress|UserAgent|CorrelationId|DeviceDetail|LocationDetails'
    }

    It 'rejects a non-allow-listed KQL table' {
        {
            ConvertTo-SignInReviewKql `
                -TemplatePath $kqlPath `
                -UserIds @('10000000-0000-0000-0000-000000000001') `
                -AppId '00000000-0000-0000-0000-000000000002' `
                -StartDateTime ([DateTimeOffset]'2026-01-01T00:00:00Z') `
                -EndDateTime ([DateTimeOffset]'2026-06-01T00:00:00Z') `
                -TableName 'SecurityEvent'
        } | Should -Throw
    }

    It 'splits users into bounded batches' {
        $items = 1..7 | ForEach-Object { [pscustomobject]@{ id = $_ } }
        $batches = @(Split-SignInReviewBatch -InputObject $items -Size 3)
        $batches.Count | Should -Be 3
        @($batches[0]).Count | Should -Be 3
        @($batches[2]).Count | Should -Be 1
    }

    It 'outputs every current member including users without a matching sign-in' {
        $users = @(
            [pscustomobject]@{
                id                = '10000000-0000-0000-0000-000000000001'
                userPrincipalName = 'alex.taylor@example.invalid'
                displayName       = 'Alex Taylor'
            },
            [pscustomobject]@{
                id                = '10000000-0000-0000-0000-000000000002'
                userPrincipalName = 'jamie.lee@example.invalid'
                displayName       = 'Jamie Lee'
            }
        )
        $latest = @{
            '10000000-0000-0000-0000-000000000001' = [DateTimeOffset]'2026-06-01T10:00:00Z'
        }

        $rows = @(ConvertTo-SignInReviewReportRow `
            -Users $users `
            -LatestByUserId $latest `
            -AppDisplayName 'Example Business Application' `
            -AppId '00000000-0000-0000-0000-000000000002' `
            -CheckedDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z'))

        $rows.Count | Should -Be 2
        $rows[0].SignInFound | Should -BeTrue
        $rows[0].LastSignInDateTime | Should -Be '2026-06-01T10:00:00.0000000+00:00'
        $rows[1].SignInFound | Should -BeFalse
        $rows[1].LastSignInDateTime | Should -BeNullOrEmpty
        $rows[1].Note | Should -Match 'does not mean'
    }

    It 'keeps interactive and non-interactive evidence distinguishable' {
        $users = @(
            [pscustomobject]@{
                id                = '10000000-0000-0000-0000-000000000001'
                userPrincipalName = 'alex.taylor@example.invalid'
                displayName       = 'Alex Taylor'
            },
            [pscustomobject]@{
                id                = '10000000-0000-0000-0000-000000000002'
                userPrincipalName = 'jamie.lee@example.invalid'
                displayName       = 'Jamie Lee'
            }
        )
        $interactive = @{
            '10000000-0000-0000-0000-000000000001' = [DateTimeOffset]'2026-06-01T10:00:00Z'
        }
        $nonInteractive = @{
            '10000000-0000-0000-0000-000000000002' = [DateTimeOffset]'2026-06-20T10:00:00Z'
        }
        $rows = @(ConvertTo-GroupAppSignInReportRow `
            -Users $users `
            -LastInteractiveByUserId $interactive `
            -LastNonInteractiveByUserId $nonInteractive `
            -IncludeNonInteractiveSignIns $true `
            -AppDisplayName 'Example Business Application' `
            -AppId '00000000-0000-0000-0000-000000000002' `
            -EvaluationWindowStartDateTime ([DateTimeOffset]'2024-06-28T00:00:00Z') `
            -EvaluationWindowEndDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z') `
            -CheckedDateTime ([DateTimeOffset]'2026-06-28T00:00:00Z'))

        $rows[0].SignInPattern | Should -Be 'InteractiveOnly'
        $rows[0].SignInPatternJa | Should -Be '対話サインインのみログあり'
        $rows[1].SignInPattern | Should -Be 'NonInteractiveOnly'
        $rows[1].NoteJa | Should -Match '人の明示操作ではなく'
    }

    It 'has the minimal documented CSV columns and dummy identities' {
        $rows = @(Import-Csv -LiteralPath $logSamplePath)
        $rows.Count | Should -Be 3
        ($rows[0].PSObject.Properties.Name -join ',') | Should -Be ($logAnalyticsColumns -join ',')
        foreach ($row in $rows) {
            $row.UserPrincipalName | Should -Match '@example\.invalid$'
            $row.PSObject.Properties.Name | Should -Not -Contain 'IPAddress'
            $row.PSObject.Properties.Name | Should -Not -Contain 'WorkspaceId'
        }
    }
}

Describe 'Published data safety' {
    It 'does not publish common secret fields in example data' {
        $publishedText = @(
            Get-Content -LiteralPath $graphConfigPath -Raw
            Get-Content -LiteralPath $graphSamplePath -Raw
            Get-Content -LiteralPath $logConfigPath -Raw
            Get-Content -LiteralPath $logSamplePath -Raw
            Get-Content -LiteralPath $adminConfigPath -Raw
            Get-Content -LiteralPath $adminInputPath -Raw
            Get-Content -LiteralPath $adminOutputPath -Raw
        ) -join "`n"
        $publishedText | Should -Not -Match '(?i)client.?secret|access.?token|certificate.?password|private.?key'
    }
}
