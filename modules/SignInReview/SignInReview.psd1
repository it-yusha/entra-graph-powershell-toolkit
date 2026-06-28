@{
    RootModule        = 'SignInReview.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = '20000000-0000-0000-0000-000000000001'
    Author            = 'Repository contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026 Repository contributors. MIT License.'
    Description       = 'Shared read-only helpers for Entra sign-in review scripts.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Connect-SignInReviewAzure',
        'Connect-SignInReviewGraph',
        'ConvertTo-AdminAccountInactivityReviewRow',
        'ConvertTo-AdminAccountSignInKql',
        'ConvertTo-GroupAppSignInReportRow',
        'ConvertTo-SignInReviewReportRow',
        'Disconnect-SignInReviewGraph',
        'Export-SignInReviewCsv',
        'Get-SignInReviewUserByUpn',
        'Get-SignInReviewGroupUser',
        'Import-AdminAccountReviewInput',
        'Initialize-SignInReviewLog',
        'Invoke-SignInReviewLogAnalyticsQuery',
        'ConvertTo-SignInReviewKql',
        'Protect-SignInReviewCsvText',
        'Read-SignInReviewConfiguration',
        'Read-AdminAccountInactivityConfiguration',
        'Resolve-SignInReviewPath',
        'Split-SignInReviewBatch',
        'Write-SignInReviewLog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
