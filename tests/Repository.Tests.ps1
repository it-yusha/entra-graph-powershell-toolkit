BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repositoryRoot 'scripts' 'Get-AppLastSignInByGroup.ps1'
    $configPath = Join-Path $repositoryRoot 'config' 'config.example.json'
    $samplePath = Join-Path $repositoryRoot 'samples' 'sample-output.csv'
    $expectedColumns = @(
        'UserPrincipalName', 'DisplayName', 'UserId', 'CurrentGroupMember',
        'AppDisplayName', 'AppId', 'LastSignInDateTime',
        'LastSeenInCurrentRun', 'LastCheckedDateTime', 'Note'
    )
}

Describe 'PowerShell source' {
    It 'has no parser errors' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Published examples' {
    It 'contains only the supported sample schema' {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $config.SchemaVersion | Should -Be '1.0'
        $config.MembershipMode | Should -BeIn @('Direct', 'Transitive')
        $config.Output.RemovedMemberHandling | Should -BeIn @('Retain', 'Exclude')
        { [Guid]::Parse($config.GroupId) } | Should -Not -Throw
        { [Guid]::Parse($config.TargetApp.AppId) } | Should -Not -Throw
    }

    It 'has the documented CSV columns and dummy identities' {
        $rows = @(Import-Csv -LiteralPath $samplePath)
        $rows.Count | Should -BeGreaterThan 0
        ($rows[0].PSObject.Properties.Name -join ',') | Should -Be ($expectedColumns -join ',')
        foreach ($row in $rows) {
            $row.UserPrincipalName | Should -Match '@example\.invalid$'
        }
    }

    It 'does not publish common secret fields' {
        $publishedText = @(
            Get-Content -LiteralPath $configPath -Raw
            Get-Content -LiteralPath $samplePath -Raw
        ) -join "`n"
        $publishedText | Should -Not -Match '(?i)client.?secret|access.?token|certificate.?password'
    }
}
