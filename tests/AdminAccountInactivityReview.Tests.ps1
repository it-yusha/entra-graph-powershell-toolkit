BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repositoryRoot 'modules' 'SignInReview' 'SignInReview.psd1'
    $configPath = Join-Path $repositoryRoot 'config' 'admin-account-inactivity-review.config.example.json'
    $inputPath = Join-Path $repositoryRoot 'samples' 'admin-accounts.sample.csv'
    $outputPath = Join-Path $repositoryRoot 'samples' 'admin-account-inactivity-review.sample.csv'
    $kqlPath = Join-Path $repositoryRoot 'kql' 'admin-account-last-signin.kql'
    $scriptPath = Join-Path $repositoryRoot 'scripts' 'Get-AdminAccountInactivityReviewFromLogAnalytics.ps1'
    Import-Module $modulePath -Force

    function New-TestInputRecord {
        param(
            [bool]$Excluded = $false,
            [int]$Threshold = 90
        )
        return [pscustomobject]@{
            InputUserPrincipalName   = 'admin01@example.invalid'
            ExcludeFromInactiveCheck = $Excluded
            InactiveThresholdDays    = $Threshold
            Passthrough              = [ordered]@{
                Owner       = 'Example Operations Team'
                Purpose     = 'Administration'
                AccountType = 'NamedAdmin'
                Note        = 'Dummy note'
            }
        }
    }

    function New-TestDirectoryResult {
        param(
            [string]$Status = 'Resolved',
            [AllowNull()][object]$AccountEnabled = $true,
            [AllowNull()][object]$CreatedDateTime = '2024-01-01T00:00:00Z'
        )
        if ($Status -ne 'Resolved') {
            return [pscustomobject]@{ Status = $Status; User = $null }
        }
        $user = [pscustomobject]@{
            id                = '10000000-0000-0000-0000-000000000001'
            userPrincipalName = 'admin01@example.invalid'
            displayName       = 'Admin User 01'
            accountEnabled    = $AccountEnabled
            createdDateTime   = $CreatedDateTime
        }
        return [pscustomobject]@{ Status = 'Resolved'; User = $user }
    }

    $reportDate = [DateTimeOffset]'2026-06-28T00:00:00Z'
    $sufficientEvidenceStart = [DateTimeOffset]'2024-06-29T00:00:00Z'
}

Describe 'Administrator inactivity configuration and input' {
    It 'validates the public configuration' {
        $document = Read-AdminAccountInactivityConfiguration -Path $configPath
        $document.Value.Evaluation.DefaultInactiveThresholdDays | Should -Be 90
        $document.Value.Evaluation.LookbackDays | Should -Be 730
        $document.Value.Input.PassthroughColumns | Should -Contain 'Owner'
    }

    It 'normalizes the public input sample' {
        $rows = @(Import-AdminAccountReviewInput `
            -Path $inputPath `
            -DefaultInactiveThresholdDays 90 `
            -LookbackDays 730)
        $rows.Count | Should -Be 5
        $rows[0].InactiveThresholdDays | Should -Be 90
        $rows[2].InactiveThresholdDays | Should -Be 90
        $rows[3].ExcludeFromInactiveCheck | Should -BeTrue
        $rows[0].Passthrough['Owner'] | Should -Be 'Example Operations Team'
    }

    It 'rejects a row threshold longer than the query lookback' {
        $temporaryPath = Join-Path $TestDrive 'invalid-threshold.csv'
        @'
UserPrincipalName,ExcludeFromInactiveCheck,InactiveThresholdDays
admin01@example.invalid,false,731
'@ | Set-Content -LiteralPath $temporaryPath -Encoding utf8

        {
            Import-AdminAccountReviewInput `
                -Path $temporaryPath `
                -DefaultInactiveThresholdDays 90 `
                -LookbackDays 730
        } | Should -Throw '*exceeds LookbackDays*'
    }

    It 'rejects duplicate UPNs case-insensitively' {
        $temporaryPath = Join-Path $TestDrive 'duplicate-upn.csv'
        @'
UserPrincipalName
admin01@example.invalid
ADMIN01@example.invalid
'@ | Set-Content -LiteralPath $temporaryPath -Encoding utf8

        {
            Import-AdminAccountReviewInput `
                -Path $temporaryPath `
                -DefaultInactiveThresholdDays 90 `
                -LookbackDays 730
        } | Should -Throw '*duplicate UserPrincipalName*'
    }
}

Describe 'Administrator sign-in KQL' {
    It 'renders only aggregate evidence fields' {
        $query = ConvertTo-AdminAccountSignInKql `
            -TemplatePath $kqlPath `
            -UserIds @('10000000-0000-0000-0000-000000000001') `
            -StartDateTime ([DateTimeOffset]'2024-06-29T00:00:00Z') `
            -EndDateTime $reportDate `
            -TableName 'AADNonInteractiveUserSignInLogs'

        $query | Should -Not -Match '\{\{[A-Z0-9_]+\}\}'
        $query | Should -Match '(?m)^AADNonInteractiveUserSignInLogs$'
        $query | Should -Match 'summarize LastSignInDateTime = max\(TimeGenerated\)'
        $query | Should -Not -Match 'IPAddress|UserAgent|CorrelationId|DeviceDetail|LocationDetails'
    }
}

Describe 'Administrator inactivity decision matrix' {
    It 'marks an excluded account as Excluded' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord -Excluded $true) `
            -DirectoryResult (New-TestDirectoryResult) `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'Excluded'
        $row.RecommendedAction | Should -Be 'NoAction'
    }

    It 'marks a disabled account as AlreadyDisabled' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult -AccountEnabled $false) `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'AlreadyDisabled'
        $row.SignInPattern | Should -Be 'AlreadyDisabled'
    }

    It 'marks a recent interactive sign-in as Active' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult) `
            -LastInteractiveSignInDateTime ([DateTimeOffset]'2026-06-01T10:00:00Z') `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'Active'
        $row.SignInPattern | Should -Be 'InteractiveRecentOnly'
        $row.DaysSinceLastAnyUserSignIn | Should -Be 26
    }

    It 'requires review when only non-interactive activity is recent' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult) `
            -LastInteractiveSignInDateTime ([DateTimeOffset]'2025-10-01T10:00:00Z') `
            -LastNonInteractiveSignInDateTime ([DateTimeOffset]'2026-06-20T10:00:00Z') `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'ReviewRequired'
        $row.SignInPattern | Should -Be 'NonInteractiveRecentOnly'
        $row.ReviewReasonCode | Should -Be 'RecentNonInteractiveSignInOnly'
    }

    It 'marks old sign-ins as an InactiveCandidate' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult) `
            -LastInteractiveSignInDateTime ([DateTimeOffset]'2025-12-01T10:00:00Z') `
            -LastNonInteractiveSignInDateTime ([DateTimeOffset]'2025-12-02T10:00:00Z') `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'InactiveCandidate'
        $row.SignInPattern | Should -Be 'NoRecentSignIn'
        $row.RecommendedAction | Should -Be 'DisableCandidate'
    }

    It 'marks no records as an InactiveCandidate when evidence is sufficient' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult) `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'InactiveCandidate'
        $row.SignInPattern | Should -Be 'NoSignInRecord'
        $row.ReviewReasonCode | Should -Be 'NoSignInRecord'
    }

    It 'requires review when the evidence window is too short' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult) `
            -EvidenceWindowStartDateTime ([DateTimeOffset]'2026-05-01T00:00:00Z') `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'ReviewRequired'
        $row.ReviewReasonCode | Should -Be 'EvidenceWindowTooShort'
    }

    It 'requires review when the account is newer than the threshold' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult -CreatedDateTime '2026-05-01T00:00:00Z') `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'ReviewRequired'
        $row.ReviewReasonCode | Should -Be 'AccountTooNew'
    }

    It 'requires review when the input UPN cannot be resolved' {
        $row = ConvertTo-AdminAccountInactivityReviewRow `
            -InputRecord (New-TestInputRecord) `
            -DirectoryResult (New-TestDirectoryResult -Status 'NotFound') `
            -EvidenceWindowStartDateTime $sufficientEvidenceStart `
            -ReportGeneratedDateTime $reportDate
        $row.ReviewStatus | Should -Be 'ReviewRequired'
        $row.SignInPattern | Should -Be 'Unresolved'
        $row.DirectoryLookupStatusJa | Should -Be 'ユーザー未検出'
    }
}

Describe 'Administrator review sample output' {
    It 'contains the intended review statuses and no approval workflow columns' {
        $rows = @(Import-Csv -LiteralPath $outputPath)
        $rows.ReviewStatus | Should -Contain 'InactiveCandidate'
        $rows.ReviewStatus | Should -Contain 'ReviewRequired'
        $rows.ReviewStatus | Should -Contain 'Active'
        $rows.ReviewStatus | Should -Contain 'AlreadyDisabled'
        $rows.ReviewStatus | Should -Contain 'Excluded'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'ApprovedToDisable'
        $rows[0].PSObject.Properties.Name | Should -Not -Contain 'ReviewedBy'
        foreach ($row in $rows) {
            $row.InputUserPrincipalName | Should -Match '@example\.invalid$'
        }
    }

    It 'contains no Entra or Graph mutation commands' {
        $source = @(
            Get-Content -LiteralPath $scriptPath -Raw
            Get-Content -LiteralPath $modulePath.Replace('.psd1', '.psm1') -Raw
        ) -join "`n"
        $source | Should -Not -Match '(?i)\b(?:Update|Remove|New|Set|Revoke|Restore)-Mg(?:User|DirectoryRole|RoleManagement)'
        $source | Should -Not -Match '(?i)Invoke-MgGraphRequest[^\r\n]+-Method\s+(?:POST|PUT|PATCH|DELETE)'
    }
}
