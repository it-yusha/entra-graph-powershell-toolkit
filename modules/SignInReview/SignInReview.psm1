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

function Read-SignInReviewJsonDocument {
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

    return [pscustomobject]@{
        Value         = $config
        Path          = $resolvedPath
        BaseDirectory = Split-Path -Parent $resolvedPath
    }
}

function Read-SignInReviewConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $document = Read-SignInReviewJsonDocument -Path $Path
    $config = $document.Value

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

    return $document
}

function Read-AdminAccountInactivityConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $document = Read-SignInReviewJsonDocument -Path $Path
    $config = $document.Value

    if ((Get-SignInReviewRequiredProperty $config 'SchemaVersion') -ne '1.0') {
        throw "Unsupported SchemaVersion. Expected '1.0'."
    }

    Confirm-SignInReviewGuid ([string]$config.TenantId) 'TenantId' -AllowEmpty
    Confirm-SignInReviewGuid ([string]$config.SubscriptionId) 'SubscriptionId' -AllowEmpty
    Confirm-SignInReviewGuid ([string](Get-SignInReviewRequiredProperty $config 'WorkspaceId')) 'WorkspaceId'

    $inputConfig = Get-SignInReviewRequiredProperty $config 'Input'
    [void](Get-SignInReviewRequiredProperty $inputConfig 'CsvPath')
    [void](Get-SignInReviewRequiredProperty $inputConfig 'PassthroughColumns')
    $supportedPassthroughColumns = @('Owner', 'Purpose', 'AccountType', 'Note')
    foreach ($column in @($inputConfig.PassthroughColumns)) {
        if (([string]$column) -notin $supportedPassthroughColumns) {
            throw "Input.PassthroughColumns contains unsupported column '$column'. Supported values: $($supportedPassthroughColumns -join ', ')."
        }
    }

    $evaluation = Get-SignInReviewRequiredProperty $config 'Evaluation'
    $defaultThreshold = [int](Get-SignInReviewRequiredProperty $evaluation 'DefaultInactiveThresholdDays')
    if ($defaultThreshold -lt 1 -or $defaultThreshold -gt 3650) {
        throw 'Evaluation.DefaultInactiveThresholdDays must be between 1 and 3650.'
    }
    $lookbackDays = [int](Get-SignInReviewRequiredProperty $evaluation 'LookbackDays')
    if ($lookbackDays -lt 1 -or $lookbackDays -gt 3650) {
        throw 'Evaluation.LookbackDays must be between 1 and 3650.'
    }
    if ($lookbackDays -lt $defaultThreshold) {
        throw 'Evaluation.LookbackDays must be greater than or equal to Evaluation.DefaultInactiveThresholdDays.'
    }
    $batchSize = [int](Get-SignInReviewRequiredProperty $evaluation 'BatchSize')
    if ($batchSize -lt 1 -or $batchSize -gt 1000) {
        throw 'Evaluation.BatchSize must be between 1 and 1000.'
    }
    [void](Get-SignInReviewRequiredProperty $evaluation 'KqlTemplatePath')

    $coverageText = [string](Get-SignInReviewRequiredProperty $evaluation 'EvidenceCoverageStartDateTime')
    $coverageStart = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $coverageText,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$coverageStart
    )) {
        throw 'Evaluation.EvidenceCoverageStartDateTime must be an ISO 8601 timestamp.'
    }
    if ($coverageStart -gt [DateTimeOffset]::UtcNow) {
        throw 'Evaluation.EvidenceCoverageStartDateTime cannot be in the future.'
    }

    $output = Get-SignInReviewRequiredProperty $config 'Output'
    [void](Get-SignInReviewRequiredProperty $output 'Directory')
    $fileNamePrefix = [string](Get-SignInReviewRequiredProperty $output 'FileNamePrefix')
    if ($fileNamePrefix -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'Output.FileNamePrefix must contain only lowercase letters, numbers, and hyphens.'
    }

    $logging = Get-SignInReviewRequiredProperty $config 'Logging'
    [void](Get-SignInReviewRequiredProperty $logging 'Directory')
    if (([string]$logging.Level) -notin @('Debug', 'Information', 'Warning', 'Error')) {
        throw "Logging.Level must be Debug, Information, Warning, or Error."
    }

    return $document
}

function ConvertFrom-SignInReviewBooleanText {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][int]$RowNumber
    )

    switch (([string]$Value).Trim().ToLowerInvariant()) {
        ''      { return $false }
        'false' { return $false }
        'true'  { return $true }
        default { throw "Input row $RowNumber has invalid $FieldName '$Value'. Use true, false, or blank." }
    }
}

function Import-AdminAccountReviewInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateRange(1, 3650)][int]$DefaultInactiveThresholdDays,
        [Parameter(Mandatory)][ValidateRange(1, 3650)][int]$LookbackDays,
        [Parameter()][string[]]$PassthroughColumns = @('Owner', 'Purpose', 'AccountType', 'Note')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Input CSV was not found: $Path."
    }

    $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8)
    if ($rows.Count -eq 0) {
        throw 'Input CSV must contain at least one account row.'
    }
    if ('UserPrincipalName' -notin $rows[0].PSObject.Properties.Name) {
        throw "Input CSV is missing required column 'UserPrincipalName'."
    }

    $supportedPassthroughColumns = @('Owner', 'Purpose', 'AccountType', 'Note')
    foreach ($column in $PassthroughColumns) {
        if ($column -notin $supportedPassthroughColumns) {
            throw "Unsupported passthrough column '$column'."
        }
    }

    $seenUpns = @{}
    $normalizedRows = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $row = $rows[$index]
        $rowNumber = $index + 2
        $upn = ([string]$row.UserPrincipalName).Trim()
        if ($upn -notmatch '^[^@\s]+@[^@\s]+$') {
            throw "Input row $rowNumber has an invalid UserPrincipalName."
        }
        $upnKey = $upn.ToLowerInvariant()
        if ($seenUpns.ContainsKey($upnKey)) {
            throw "Input CSV contains duplicate UserPrincipalName '$upn'."
        }
        $seenUpns[$upnKey] = $true

        $excludeValue = if ('ExcludeFromInactiveCheck' -in $row.PSObject.Properties.Name) {
            [string]$row.ExcludeFromInactiveCheck
        }
        else {
            ''
        }
        $exclude = ConvertFrom-SignInReviewBooleanText `
            -Value $excludeValue `
            -FieldName 'ExcludeFromInactiveCheck' `
            -RowNumber $rowNumber

        $thresholdText = if ('InactiveThresholdDays' -in $row.PSObject.Properties.Name) {
            ([string]$row.InactiveThresholdDays).Trim()
        }
        else {
            ''
        }
        $threshold = $DefaultInactiveThresholdDays
        if (-not [string]::IsNullOrWhiteSpace($thresholdText)) {
            if (-not [int]::TryParse($thresholdText, [ref]$threshold) -or $threshold -lt 1 -or $threshold -gt 3650) {
                throw "Input row $rowNumber has invalid InactiveThresholdDays '$thresholdText'."
            }
        }
        if ($threshold -gt $LookbackDays) {
            throw "Input row $rowNumber has InactiveThresholdDays $threshold, which exceeds LookbackDays $LookbackDays."
        }

        $passthrough = [ordered]@{}
        foreach ($column in $PassthroughColumns) {
            $passthrough[$column] = if ($column -in $row.PSObject.Properties.Name) {
                [string]$row.$column
            }
            else {
                ''
            }
        }

        $normalizedRows.Add([pscustomobject]@{
            InputUserPrincipalName   = $upn
            ExcludeFromInactiveCheck = $exclude
            InactiveThresholdDays    = $threshold
            Passthrough              = $passthrough
        })
    }

    return $normalizedRows.ToArray()
}

function Connect-SignInReviewGraph {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$TenantId,
        [Parameter()][ValidateNotNullOrEmpty()][string[]]$Scopes = @(
            'GroupMember.Read.All',
            'User.ReadBasic.All'
        )
    )

    $requiredScopes = @($Scopes | Sort-Object -Unique)
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

function Get-SignInReviewUserByUpn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[^@\s]+@[^@\s]+$')]
        [string]$UserPrincipalName
    )

    $escapedUpn = $UserPrincipalName.Replace("'", "''")
    $filter = [Uri]::EscapeDataString("userPrincipalName eq '$escapedUpn'")
    $select = [Uri]::EscapeDataString('id,displayName,userPrincipalName,accountEnabled,createdDateTime')
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$filter&`$select=$select&`$top=2"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
    $users = @($response.value)

    if ($users.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'NotFound'
            User   = $null
        }
    }
    if ($users.Count -gt 1) {
        return [pscustomobject]@{
            Status = 'MultipleMatches'
            User   = $null
        }
    }
    return [pscustomobject]@{
        Status = 'Resolved'
        User   = $users[0]
    }
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

function ConvertTo-AdminAccountSignInKql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string[]]$UserIds,
        [Parameter(Mandatory)][DateTimeOffset]$StartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EndDateTime,
        [Parameter(Mandatory)]
        [ValidateSet('SigninLogs', 'AADNonInteractiveUserSignInLogs')]
        [string]$TableName
    )

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

function Get-SignInReviewDaysSince {
    param(
        [AllowNull()][object]$Timestamp,
        [Parameter(Mandatory)][DateTimeOffset]$ReferenceDateTime
    )

    if ($null -eq $Timestamp) {
        return $null
    }
    $timestampValue = [DateTimeOffset]$Timestamp
    return [Math]::Max(0, [Math]::Floor(($ReferenceDateTime - $timestampValue).TotalDays))
}

function ConvertTo-AdminAccountInactivityReviewRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputRecord,
        [Parameter(Mandatory)][object]$DirectoryResult,
        [AllowNull()][object]$LastInteractiveSignInDateTime,
        [AllowNull()][object]$LastNonInteractiveSignInDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EvidenceWindowStartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$ReportGeneratedDateTime
    )

    $directoryStatus = [string]$DirectoryResult.Status
    $directoryStatusJa = switch ($directoryStatus) {
        'Resolved'        { '解決済み' }
        'NotFound'        { 'ユーザー未検出' }
        'MultipleMatches' { '複数ユーザー一致' }
        default           { 'ディレクトリ確認エラー' }
    }
    $directoryUser = if ($directoryStatus -eq 'Resolved') { $DirectoryResult.User } else { $null }

    $resolvedUpn = ''
    $displayName = ''
    $userId = ''
    $accountEnabled = $null
    $createdDateTime = $null
    if ($directoryUser) {
        $resolvedUpn = [string]$directoryUser.userPrincipalName
        $displayName = [string]$directoryUser.displayName
        $userId = ([string]$directoryUser.id).ToLowerInvariant()
        Confirm-SignInReviewGuid $userId 'UserId'

        $enabledProperty = $directoryUser.PSObject.Properties['accountEnabled']
        if ($enabledProperty -and $null -ne $enabledProperty.Value) {
            $accountEnabled = [bool]$enabledProperty.Value
        }
        $createdProperty = $directoryUser.PSObject.Properties['createdDateTime']
        if ($createdProperty -and $createdProperty.Value) {
            $createdDateTime = [DateTimeOffset]$createdProperty.Value
        }
    }

    $interactiveTimestamp = if ($null -eq $LastInteractiveSignInDateTime) {
        $null
    }
    else {
        [DateTimeOffset]$LastInteractiveSignInDateTime
    }
    $nonInteractiveTimestamp = if ($null -eq $LastNonInteractiveSignInDateTime) {
        $null
    }
    else {
        [DateTimeOffset]$LastNonInteractiveSignInDateTime
    }

    $lastAny = $null
    foreach ($timestamp in @($interactiveTimestamp, $nonInteractiveTimestamp)) {
        if ($null -ne $timestamp -and ($null -eq $lastAny -or $timestamp -gt $lastAny)) {
            $lastAny = $timestamp
        }
    }

    $thresholdDays = [int]$InputRecord.InactiveThresholdDays
    $cutoff = $ReportGeneratedDateTime.AddDays(-$thresholdDays)
    $interactiveRecent = $null -ne $interactiveTimestamp -and $interactiveTimestamp -ge $cutoff
    $nonInteractiveRecent = $null -ne $nonInteractiveTimestamp -and $nonInteractiveTimestamp -ge $cutoff
    $evidenceWindowSufficient = $EvidenceWindowStartDateTime -le $cutoff
    $accountOldEnough = $null -ne $createdDateTime -and $createdDateTime -le $cutoff

    $signInPattern = if ([bool]$InputRecord.ExcludeFromInactiveCheck) {
        'Excluded'
    }
    elseif ($directoryStatus -ne 'Resolved') {
        'Unresolved'
    }
    elseif ($null -ne $accountEnabled -and -not $accountEnabled) {
        'AlreadyDisabled'
    }
    elseif ($interactiveRecent -and $nonInteractiveRecent) {
        'BothRecent'
    }
    elseif ($interactiveRecent) {
        'InteractiveRecentOnly'
    }
    elseif ($nonInteractiveRecent) {
        'NonInteractiveRecentOnly'
    }
    elseif ($null -ne $lastAny) {
        'NoRecentSignIn'
    }
    else {
        'NoSignInRecord'
    }

    $signInPatternJa = switch ($signInPattern) {
        'Excluded'                 { '判定対象外' }
        'Unresolved'               { 'ユーザー未解決' }
        'AlreadyDisabled'          { '無効化済み' }
        'BothRecent'               { '対話・非対話とも直近利用あり' }
        'InteractiveRecentOnly'    { '対話サインインが直近利用あり' }
        'NonInteractiveRecentOnly' { '非対話サインインのみ直近利用あり' }
        'NoRecentSignIn'           { '直近利用なし' }
        default                    { '対象期間内ログなし' }
    }

    if ([bool]$InputRecord.ExcludeFromInactiveCheck) {
        $reviewStatus = 'Excluded'
        $reviewStatusJa = '判定対象外'
        $reasonCode = 'ExcludedByInput'
        $reason = 'The input account is excluded from inactivity evaluation.'
        $reasonJa = '入力台帳で休眠判定の対象外に指定されています。'
        $recommendedAction = 'NoAction'
    }
    elseif ($directoryStatus -ne 'Resolved') {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = $directoryStatus
        $reason = 'The input account could not be resolved to exactly one Microsoft Entra user.'
        $reasonJa = '入力アカウントをMicrosoft Entraユーザー1件に解決できないため、手動確認が必要です。'
        $recommendedAction = 'Review'
    }
    elseif ($null -eq $accountEnabled) {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = 'AccountEnabledUnavailable'
        $reason = 'The accountEnabled property was not available from Microsoft Graph.'
        $reasonJa = 'Microsoft GraphからAccountEnabledを取得できないため、手動確認が必要です。'
        $recommendedAction = 'Review'
    }
    elseif (-not $accountEnabled) {
        $reviewStatus = 'AlreadyDisabled'
        $reviewStatusJa = '無効化済み'
        $reasonCode = 'AccountAlreadyDisabled'
        $reason = 'The Microsoft Entra account is already disabled.'
        $reasonJa = 'Microsoft Entraアカウントはすでに無効化されています。'
        $recommendedAction = 'NoAction'
    }
    elseif ($interactiveRecent) {
        $reviewStatus = 'Active'
        $reviewStatusJa = '利用あり'
        $reasonCode = 'RecentInteractiveSignIn'
        $reason = 'A successful interactive sign-in exists within the inactivity threshold.'
        $reasonJa = '休眠判定しきい値内に成功した対話サインインがあります。'
        $recommendedAction = 'NoAction'
    }
    elseif ($nonInteractiveRecent) {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = 'RecentNonInteractiveSignInOnly'
        $reason = 'Only a successful non-interactive sign-in is recent; confirm the account purpose before action.'
        $reasonJa = '非対話サインインのみ直近利用があるため、用途を確認してから判断してください。'
        $recommendedAction = 'Review'
    }
    elseif (-not $evidenceWindowSufficient) {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = 'EvidenceWindowTooShort'
        $reason = 'The trusted log evidence window is shorter than the inactivity threshold.'
        $reasonJa = '信頼できるログ証拠期間が休眠判定しきい値より短いため、判定できません。'
        $recommendedAction = 'Review'
    }
    elseif ($null -eq $createdDateTime) {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = 'CreatedDateTimeUnavailable'
        $reason = 'The account creation date is unavailable, so the observation period cannot be confirmed.'
        $reasonJa = 'アカウント作成日時を取得できず、十分な観測期間を確認できません。'
        $recommendedAction = 'Review'
    }
    elseif (-not $accountOldEnough) {
        $reviewStatus = 'ReviewRequired'
        $reviewStatusJa = '要確認'
        $reasonCode = 'AccountTooNew'
        $reason = 'The account is newer than the inactivity threshold.'
        $reasonJa = 'アカウント作成から休眠判定しきい値の日数が経過していません。'
        $recommendedAction = 'Review'
    }
    else {
        $reviewStatus = 'InactiveCandidate'
        $reviewStatusJa = '休眠候補'
        $recommendedAction = 'DisableCandidate'
        if ($null -eq $lastAny) {
            $reasonCode = 'NoSignInRecord'
            $reason = 'No successful interactive or non-interactive sign-in was found in a sufficient evidence window.'
            $reasonJa = '十分な証拠期間内に成功した対話・非対話サインインが見つかりません。'
        }
        else {
            $reasonCode = 'NoRecentSignIn'
            $reason = 'Interactive and non-interactive sign-ins are both older than the inactivity threshold.'
            $reasonJa = '対話・非対話サインインの両方が休眠判定しきい値を超過しています。'
        }
    }

    $passthrough = $InputRecord.Passthrough
    $owner = if ($passthrough.Contains('Owner')) { [string]$passthrough['Owner'] } else { '' }
    $purpose = if ($passthrough.Contains('Purpose')) { [string]$passthrough['Purpose'] } else { '' }
    $accountType = if ($passthrough.Contains('AccountType')) { [string]$passthrough['AccountType'] } else { '' }
    $inputNote = if ($passthrough.Contains('Note')) { [string]$passthrough['Note'] } else { '' }

    return [pscustomobject][ordered]@{
        InputUserPrincipalName             = Protect-SignInReviewCsvText ([string]$InputRecord.InputUserPrincipalName)
        UserPrincipalName                  = Protect-SignInReviewCsvText $resolvedUpn
        DisplayName                        = Protect-SignInReviewCsvText $displayName
        UserId                             = $userId
        AccountEnabled                     = if ($null -eq $accountEnabled) { '' } else { $accountEnabled }
        CreatedDateTime                    = if ($null -eq $createdDateTime) { '' } else { $createdDateTime.ToUniversalTime().ToString('o') }
        Owner                              = Protect-SignInReviewCsvText $owner
        Purpose                            = Protect-SignInReviewCsvText $purpose
        AccountType                        = Protect-SignInReviewCsvText $accountType
        InputNote                          = Protect-SignInReviewCsvText $inputNote
        LastInteractiveSignInDateTime      = if ($null -eq $interactiveTimestamp) { '' } else { $interactiveTimestamp.ToUniversalTime().ToString('o') }
        DaysSinceLastInteractiveSignIn     = Get-SignInReviewDaysSince $interactiveTimestamp $ReportGeneratedDateTime
        LastNonInteractiveSignInDateTime   = if ($null -eq $nonInteractiveTimestamp) { '' } else { $nonInteractiveTimestamp.ToUniversalTime().ToString('o') }
        DaysSinceLastNonInteractiveSignIn  = Get-SignInReviewDaysSince $nonInteractiveTimestamp $ReportGeneratedDateTime
        LastAnyUserSignInDateTime          = if ($null -eq $lastAny) { '' } else { $lastAny.ToUniversalTime().ToString('o') }
        DaysSinceLastAnyUserSignIn         = Get-SignInReviewDaysSince $lastAny $ReportGeneratedDateTime
        InactiveThresholdDays              = $thresholdDays
        ExcludeFromInactiveCheck           = [bool]$InputRecord.ExcludeFromInactiveCheck
        EvidenceWindowStartDateTime        = $EvidenceWindowStartDateTime.ToUniversalTime().ToString('o')
        DirectoryLookupStatus              = $directoryStatus
        DirectoryLookupStatusJa            = $directoryStatusJa
        SignInPattern                       = $signInPattern
        SignInPatternJa                     = $signInPatternJa
        ReviewStatus                        = $reviewStatus
        ReviewStatusJa                      = $reviewStatusJa
        ReviewReasonCode                    = $reasonCode
        ReviewReason                        = $reason
        ReviewReasonJa                      = $reasonJa
        RecommendedAction                   = $recommendedAction
        ReportGeneratedDateTime             = $ReportGeneratedDateTime.ToUniversalTime().ToString('o')
    }
}

function ConvertTo-GroupAppSignInReportRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Users,
        [Parameter(Mandatory)][hashtable]$LastInteractiveByUserId,
        [Parameter(Mandatory)][hashtable]$LastNonInteractiveByUserId,
        [Parameter(Mandatory)][bool]$IncludeNonInteractiveSignIns,
        [Parameter(Mandatory)][string]$AppDisplayName,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][DateTimeOffset]$EvaluationWindowStartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EvaluationWindowEndDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$CheckedDateTime
    )

    Confirm-SignInReviewGuid $AppId 'AppId'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($user in $Users) {
        $userId = ([string]$user.id).ToLowerInvariant()
        Confirm-SignInReviewGuid $userId 'UserId'
        $interactive = if ($LastInteractiveByUserId.ContainsKey($userId)) {
            [DateTimeOffset]$LastInteractiveByUserId[$userId]
        }
        else {
            $null
        }
        $nonInteractive = if ($LastNonInteractiveByUserId.ContainsKey($userId)) {
            [DateTimeOffset]$LastNonInteractiveByUserId[$userId]
        }
        else {
            $null
        }

        $latest = $interactive
        if ($null -ne $nonInteractive -and ($null -eq $latest -or $nonInteractive -gt $latest)) {
            $latest = $nonInteractive
        }
        $found = $null -ne $latest

        if ($IncludeNonInteractiveSignIns) {
            $queriedSignInTypes = 'InteractiveAndNonInteractive'
            $queriedSignInTypesJa = '対話・非対話'
            if ($null -ne $interactive -and $null -ne $nonInteractive) {
                $pattern = 'Both'
                $patternJa = '対話・非対話ともログあり'
                $note = ''
                $noteJa = ''
            }
            elseif ($null -ne $interactive) {
                $pattern = 'InteractiveOnly'
                $patternJa = '対話サインインのみログあり'
                $note = ''
                $noteJa = ''
            }
            elseif ($null -ne $nonInteractive) {
                $pattern = 'NonInteractiveOnly'
                $patternJa = '非対話サインインのみログあり'
                $note = 'Only a successful non-interactive sign-in was found. This may represent token activity rather than direct user interaction.'
                $noteJa = '成功した非対話サインインのみ確認されました。人の明示操作ではなく、トークン活動などの可能性があります。'
            }
            else {
                $pattern = 'NoSignInRecord'
                $patternJa = '対象期間内ログなし'
                $note = 'No successful sign-in was found for the specified app, period, and sign-in types. This does not mean the app has never been used.'
                $noteJa = '指定したアプリ・期間・ログ種別で成功サインインは確認できませんでした。アプリを一度も利用していないことを意味しません。'
            }
        }
        else {
            $queriedSignInTypes = 'InteractiveOnly'
            $queriedSignInTypesJa = '対話のみ（非対話は未検索）'
            if ($null -ne $interactive) {
                $pattern = 'InteractiveObserved'
                $patternJa = '対話サインインあり'
                $note = 'Non-interactive sign-ins were not queried.'
                $noteJa = '非対話サインインは検索対象に含めていません。'
            }
            else {
                $pattern = 'NoInteractiveSignInRecord'
                $patternJa = '対象期間内の対話ログなし'
                $note = 'No successful interactive sign-in was found for the specified app and period. Non-interactive sign-ins were not queried, and this does not mean the app has never been used.'
                $noteJa = '指定したアプリ・期間で成功した対話サインインは確認できませんでした。非対話サインインは未検索であり、アプリを一度も利用していないことを意味しません。'
            }
        }

        $rows.Add([pscustomobject][ordered]@{
            UserPrincipalName                = Protect-SignInReviewCsvText ([string]$user.userPrincipalName)
            DisplayName                      = Protect-SignInReviewCsvText ([string]$user.displayName)
            UserId                           = $userId
            AppDisplayName                   = Protect-SignInReviewCsvText $AppDisplayName
            AppId                            = $AppId.ToLowerInvariant()
            LastSignInDateTime               = if ($found) { $latest.ToUniversalTime().ToString('o') } else { '' }
            SignInFound                      = $found
            CheckedDateTime                  = $CheckedDateTime.ToUniversalTime().ToString('o')
            Note                             = $note
            LastInteractiveSignInDateTime    = if ($null -eq $interactive) { '' } else { $interactive.ToUniversalTime().ToString('o') }
            LastNonInteractiveSignInDateTime = if ($null -eq $nonInteractive) { '' } else { $nonInteractive.ToUniversalTime().ToString('o') }
            SignInFoundJa                    = if ($found) { 'ログあり' } else { '対象期間内ログなし' }
            QueriedSignInTypes               = $queriedSignInTypes
            QueriedSignInTypesJa             = $queriedSignInTypesJa
            SignInPattern                    = $pattern
            SignInPatternJa                  = $patternJa
            EvaluationWindowStartDateTime    = $EvaluationWindowStartDateTime.ToUniversalTime().ToString('o')
            EvaluationWindowEndDateTime      = $EvaluationWindowEndDateTime.ToUniversalTime().ToString('o')
            NoteJa                           = $noteJa
        })
    }
    return $rows.ToArray()
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

. (Join-Path $PSScriptRoot 'ConditionalAccessAnalysis.ps1')

Export-ModuleMember -Function @(
    'Connect-SignInReviewAzure',
    'Connect-SignInReviewGraph',
    'ConvertTo-AdminAccountInactivityReviewRow',
    'ConvertTo-AdminAccountSignInKql',
    'ConvertTo-ConditionalAccessAiMarkdown',
    'ConvertTo-ConditionalAccessChecklistMarkdown',
    'ConvertTo-ConditionalAccessNotAppliedKql',
    'ConvertTo-ConditionalAccessNotAppliedReport',
    'ConvertTo-GroupAppSignInReportRow',
    'ConvertTo-SignInReviewReportRow',
    'Disconnect-SignInReviewGraph',
    'Export-SignInReviewCsv',
    'Get-SignInReviewUserByUpn',
    'Get-SignInReviewUserById',
    'Get-SignInReviewGroupUser',
    'Import-AdminAccountReviewInput',
    'Import-ConditionalAccessExclusion',
    'Initialize-SignInReviewLog',
    'Invoke-SignInReviewLogAnalyticsQuery',
    'ConvertTo-SignInReviewKql',
    'Protect-SignInReviewCsvText',
    'Read-SignInReviewConfiguration',
    'Read-AdminAccountInactivityConfiguration',
    'Read-ConditionalAccessNotAppliedConfiguration',
    'Resolve-SignInReviewPath',
    'Split-SignInReviewBatch',
    'Write-SignInReviewLog'
)
