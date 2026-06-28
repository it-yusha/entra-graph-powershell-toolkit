@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Console status and the local operational log intentionally share messages.
        'PSAvoidUsingWriteHost',
        # PowerShell 7.2+ reads UTF-8 without BOM; the repository standard is UTF-8.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
