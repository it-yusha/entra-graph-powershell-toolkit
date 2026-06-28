Set-StrictMode -Version Latest

$script:LogFile = $null
$script:LogLevel = 'Information'
$script:GraphConnectedByModule = $false
$script:LogRanks = @{
    Debug       = 0
    Information = 1
    Warning     = 2
    Error       = 3
}

function Write-SignInReviewLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($script:LogRanks[$Level] -lt $script:LogRanks[$script:LogLevel]) {
        return
    }

    $line = '{0} [{1}] {2}' -f [DateTimeOffset]::UtcNow.ToString('o'), $Level.ToUpperInvariant(), $Message
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error $Message -ErrorAction Continue }
        'Debug'   { Write-Verbose $Message }
        default   { Write-Host $Message }
    }

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
    }
}

function Initialize-SignInReviewLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter()]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [Parameter()]
        [ValidatePattern('^[a-z0-9-]+$')]
        [string]$Prefix = 'sign-in-review'
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $script:LogLevel = $Level
    $script:LogFile = Join-Path $Directory ('{0}-{1}.log' -f $Prefix, [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    return $script:LogFile
}

function Resolve-SignInReviewPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Confirm-SignInReviewGuid {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($AllowEmpty) {
            return
        }
        throw "$Name must be a non-empty GUID."
    }

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "$Name must be a non-empty GUID."
    }
}

function Get-SignInReviewRequiredProperty {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or
        ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
        throw "Required configuration value '$Name' is missing."
    }
    return $property.Value
}

function Read-SignInReviewConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Configuration file was not found: $resolvedPath."
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8
    if ($raw -match '(?i)"(?:client.?secret|password|access.?token|certificate.?password)"\s*:') {
        throw 'The configuration appears to contain a secret. Secrets are not accepted in JSON.'
    }

    try {
        $config = $raw | ConvertFrom-Json -Depth 10
    }
    catch {
        throw "Configuration is not valid JSON: $($_.Exception.Message)"
    }

    if ((Get-SignInReviewRequiredProperty $config 'SchemaVersion') -ne '1.0') {
        throw "Unsupported SchemaVersion. Expected '1.0'."
    }

    Confirm-SignInReviewGuid ([string]$config.TenantId) 'TenantId' -AllowEmpty
    Confirm-SignInReviewGuid ([string]$config.SubscriptionId) 'SubscriptionId' -AllowEmpty
    Confirm-SignInReviewGuid ([string](Get-SignInReviewRequiredProperty $config 'WorkspaceId')) 'WorkspaceId'
    Confirm-SignInReviewGuid ([string](Get-SignInReviewRequiredProperty $config 'GroupId')) 'GroupId'

    $membershipMode = [string](Get-SignInReviewRequiredProperty $config 'MembershipMode')
    if ($membershipMode -notin @('Direct', 'Transitive')) {
        throw "MembershipMode must be 'Direct' or 'Transitive'."
    }

    $targetApp = Get-SignInReviewRequiredProperty $config 'TargetApp'
    Confirm-SignInReviewGuid ([string](Get-SignInReviewRequiredProperty $targetApp 'AppId')) 'TargetApp.AppId'
    [void](Get-SignInReviewRequiredProperty $targetApp 'DisplayName')

    $query = Get-SignInReviewRequiredProperty $config 'Query'
    $lookbackDays = [int](Get-SignInReviewRequiredProperty $query 'LookbackDays')
    if ($lookbackDays -lt 1 -or $lookbackDays -gt 3650) {
        throw 'Query.LookbackDays must be between 1 and 3650.'
    }
    if ($query.IncludeNonInteractiveSignIns -isnot [bool]) {
        throw 'Query.IncludeNonInteractiveSignIns must be true or false.'
    }
    $batchSize = [int](Get-SignInReviewRequiredProperty $query 'BatchSize')
    if ($batchSize -lt 1 -or $batchSize -gt 1000) {
        throw 'Query.BatchSize must be between 1 and 1000.'
    }
    [void](Get-SignInReviewRequiredProperty $query 'KqlTemplatePath')

    $output = Get-SignInReviewRequiredProperty $config 'Output'
    [void](Get-SignInReviewRequiredProperty $output 'CsvPath')

    $logging = Get-SignInReviewRequiredProperty $config 'Logging'
    [void](Get-SignInReviewRequiredProperty $logging 'Directory')
    if (([string]$logging.Level) -notin @('Debug', 'Information', 'Warning', 'Error')) {
        throw "Logging.Level must be Debug, Information, Warning, or Error."
    }

    return [pscustomobject]@{
        Value         = $config
        Path          = $resolvedPath
        BaseDirectory = Split-Path -Parent $resolvedPath
    }
}

function Connect-SignInReviewGraph {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyString()][string]$TenantId)

    $requiredScopes = @('GroupMember.Read.All', 'User.ReadBasic.All')
    $context = Get-MgContext -ErrorAction SilentlyContinue
    $tenantMatches = [string]::IsNullOrWhiteSpace($TenantId) -or
        ($context -and $context.TenantId -eq $TenantId)
    $scopeMatches = $context -and (@($requiredScopes | Where-Object { $_ -notin $context.Scopes }).Count -eq 0)

    if ($context -and $tenantMatches -and $scopeMatches) {
        Write-SignInReviewLog Information 'Reusing the existing Microsoft Graph context.'
        return
    }

    $parameters = @{
        Scopes    = $requiredScopes
        NoWelcome = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $parameters.TenantId = $TenantId
    }

    Write-SignInReviewLog Information 'Opening an interactive Microsoft Graph sign-in.'
    Connect-MgGraph @parameters | Out-Null
    $script:GraphConnectedByModule = $true
}

function Disconnect-SignInReviewGraph {
    [CmdletBinding()]
    param()

    if ($script:GraphConnectedByModule) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        $script:GraphConnectedByModule = $false
    }
}

function Connect-SignInReviewAzure {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$TenantId,
        [Parameter()][AllowEmptyString()][string]$SubscriptionId
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    $tenantMatches = [string]::IsNullOrWhiteSpace($TenantId) -or
        ($context -and $context.Tenant.Id -eq $TenantId)
    $subscriptionMatches = [string]::IsNullOrWhiteSpace($SubscriptionId) -or
        ($context -and $context.Subscription.Id -eq $SubscriptionId)

    if (-not ($context -and $tenantMatches -and $subscriptionMatches)) {
        $parameters = @{}
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $parameters.Tenant = $TenantId
        }
        Write-SignInReviewLog Information 'Opening an interactive Azure sign-in.'
        Connect-AzAccount @parameters | Out-Null
    }
    else {
        Write-SignInReviewLog Information 'Reusing the existing Azure context.'
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }
}

function Get-SignInReviewPagedGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [Collections.Generic.List[object]]::new()
    $nextLink = $Uri
    while ($nextLink) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextLink -OutputType PSObject
        foreach ($item in @($response.value)) {
            $items.Add($item)
        }
        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $nextLink = if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { $null }
    }
    return $items.ToArray()
}

function Get-SignInReviewGroupUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][ValidateSet('Direct', 'Transitive')][string]$MembershipMode
    )

    Confirm-SignInReviewGuid $GroupId 'GroupId'
    $relationship = if ($MembershipMode -eq 'Transitive') { 'transitiveMembers' } else { 'members' }
    $select = [Uri]::EscapeDataString('id,displayName,userPrincipalName')
    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/$relationship/microsoft.graph.user?`$select=$select&`$top=999"
    return @(Get-SignInReviewPagedGraphCollection -Uri $uri)
}

function Split-SignInReviewBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Size
    )

    for ($index = 0; $index -lt $InputObject.Count; $index += $Size) {
        $end = [Math]::Min($index + $Size - 1, $InputObject.Count - 1)
        , @($InputObject[$index..$end])
    }
}

function ConvertTo-SignInReviewKql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string[]]$UserIds,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][DateTimeOffset]$StartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EndDateTime,
        [Parameter(Mandatory)]
        [ValidateSet('SigninLogs', 'AADNonInteractiveUserSignInLogs')]
        [string]$TableName
    )

    Confirm-SignInReviewGuid $AppId 'AppId'
    if ($UserIds.Count -eq 0) {
        throw 'At least one UserId is required to build the KQL query.'
    }

    $normalizedUserIds = @($UserIds | ForEach-Object {
        Confirm-SignInReviewGuid ([string]$_) 'UserId'
        ([string]$_).ToLowerInvariant()
    } | Sort-Object -Unique)

    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8
    $replacements = [ordered]@{
        '{{TARGET_USER_IDS_JSON}}' = ($normalizedUserIds | ConvertTo-Json -Compress -AsArray)
        '{{SIGNIN_TABLE}}'         = $TableName
        '{{START_UTC}}'            = $StartDateTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        '{{END_UTC}}'              = $EndDateTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        '{{APP_ID}}'               = $AppId.ToLowerInvariant()
    }

    $query = $template
    foreach ($replacement in $replacements.GetEnumerator()) {
        $query = $query.Replace($replacement.Key, $replacement.Value)
    }
    if ($query -match '\{\{[A-Z0-9_]+\}\}') {
        throw "KQL template contains an unresolved token: $($Matches[0])."
    }
    return $query
}

function Invoke-SignInReviewLogAnalyticsQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][TimeSpan]$Timespan,
        [Parameter()][ValidateRange(30, 600)][int]$WaitSeconds = 180
    )

    Confirm-SignInReviewGuid $WorkspaceId 'WorkspaceId'
    $response = Invoke-AzOperationalInsightsQuery `
        -WorkspaceId $WorkspaceId `
        -Query $Query `
        -Timespan $Timespan `
        -Wait $WaitSeconds

    $errorProperty = $response.PSObject.Properties['Error']
    if ($errorProperty -and $errorProperty.Value) {
        throw "Log Analytics query failed: $($errorProperty.Value)"
    }

    $items = [Collections.Generic.List[object]]::new()
    foreach ($item in $response.Results) {
        $items.Add($item)
    }
    return $items.ToArray()
}

function Protect-SignInReviewCsvText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($Value -match '^[=+\-@\t\r]') {
        return "'$Value"
    }
    return $Value
}

function ConvertTo-SignInReviewReportRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Users,
        [Parameter(Mandatory)][hashtable]$LatestByUserId,
        [Parameter(Mandatory)][string]$AppDisplayName,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][DateTimeOffset]$CheckedDateTime
    )

    Confirm-SignInReviewGuid $AppId 'AppId'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($user in $Users) {
        $userId = ([string]$user.id).ToLowerInvariant()
        Confirm-SignInReviewGuid $userId 'UserId'
        $timestamp = $LatestByUserId[$userId]
        $found = $null -ne $timestamp
        $note = if ($found) {
            ''
        }
        else {
            'No successful sign-in was found for the specified app and period. This does not mean the app has never been used.'
        }

        $rows.Add([pscustomobject][ordered]@{
            UserPrincipalName  = Protect-SignInReviewCsvText ([string]$user.userPrincipalName)
            DisplayName        = Protect-SignInReviewCsvText ([string]$user.displayName)
            UserId             = $userId
            AppDisplayName     = Protect-SignInReviewCsvText $AppDisplayName
            AppId              = $AppId.ToLowerInvariant()
            LastSignInDateTime = if ($found) { ([DateTimeOffset]$timestamp).ToUniversalTime().ToString('o') } else { '' }
            SignInFound        = $found
            CheckedDateTime    = $CheckedDateTime.ToUniversalTime().ToString('o')
            Note               = $note
        })
    }
    return $rows.ToArray()
}

function Export-SignInReviewCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Columns
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid())

    try {
        if ($Rows.Count -eq 0) {
            $empty = [ordered]@{}
            foreach ($column in $Columns) {
                $empty[$column] = ''
            }
            $header = [pscustomobject]$empty | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1
            Set-Content -LiteralPath $temporaryPath -Value $header -Encoding utf8
        }
        else {
            @($Rows) | Select-Object -Property $Columns |
                Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding utf8
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Export-ModuleMember -Function @(
    'Connect-SignInReviewAzure',
    'Connect-SignInReviewGraph',
    'ConvertTo-SignInReviewReportRow',
    'Disconnect-SignInReviewGraph',
    'Export-SignInReviewCsv',
    'Get-SignInReviewGroupUser',
    'Initialize-SignInReviewLog',
    'Invoke-SignInReviewLogAnalyticsQuery',
    'ConvertTo-SignInReviewKql',
    'Protect-SignInReviewCsvText',
    'Read-SignInReviewConfiguration',
    'Resolve-SignInReviewPath',
    'Split-SignInReviewBatch',
    'Write-SignInReviewLog'
)
