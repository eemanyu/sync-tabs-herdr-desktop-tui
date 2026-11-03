@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts print human-readable reports on purpose; JSON mode uses
        # Write-Output.
        'PSAvoidUsingWriteHost',
        # Parameters are consumed by helper functions through script scope.
        'PSReviewUnusedParameter',
        # Internal helpers return sets of rows; singular names would be misleading.
        'PSUseSingularNouns'
    )
}
