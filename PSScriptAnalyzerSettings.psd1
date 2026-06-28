@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Console status and the local operational log intentionally share messages.
        'PSAvoidUsingWriteHost'
    )
}
