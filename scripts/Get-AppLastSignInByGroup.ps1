#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Reports

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:LogLevel = 'Information'
$script:ConnectedByScript = $false
$script:LogRanks = @{
    Debug       = 0
    Information = 1
    Warning     = 2
    Error       = 3
}

function Write-OperationalLog {
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

function Resolve-ConfiguredPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Confirm-GuidString {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "$Name must be a non-empty GUID."
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or
        ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value))) {
        throw "Required configuration value '$Name' is missing."
    }

    return $property.Value
}

function Read-ToolkitConfiguration {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Configuration file was not found: $resolvedPath. Copy config/config.example.json to config/config.json and replace the dummy values."
    }

    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8
    if ($raw -match '(?i)"(?:client.?secret|password|access.?token|certificate.?password)"\s*:') {
        throw 'The configuration appears to contain a secret. This toolkit does not accept secrets in JSON.'
    }

    try {
        $config = $raw | ConvertFrom-Json -Depth 10
    }
    catch {
        throw "Configuration is not valid JSON: $($_.Exception.Message)"
    }

    if ((Get-RequiredProperty $config 'SchemaVersion') -ne '1.0') {
        throw "Unsupported SchemaVersion. Expected '1.0'."
    }

    $groupId = [string](Get-RequiredProperty $config 'GroupId')
    Confirm-GuidString $groupId 'GroupId'

    $targetApp = Get-RequiredProperty $config 'TargetApp'
    $appId = [string](Get-RequiredProperty $targetApp 'AppId')
    Confirm-GuidString $appId 'TargetApp.AppId'
    [void](Get-RequiredProperty $targetApp 'DisplayName')

    $membershipMode = [string](Get-RequiredProperty $config 'MembershipMode')
    if ($membershipMode -notin @('Direct', 'Transitive')) {
        throw "MembershipMode must be 'Direct' or 'Transitive'."
    }

    $query = Get-RequiredProperty $config 'Query'
    $lookbackDays = [int](Get-RequiredProperty $query 'LookbackDays')
    if ($lookbackDays -lt 1 -or $lookbackDays -gt 366) {
        throw 'Query.LookbackDays must be between 1 and 366. The Graph service still limits results to the tenant retention period.'
    }
    if ($query.SuccessfulSignInsOnly -isnot [bool]) {
        throw 'Query.SuccessfulSignInsOnly must be true or false.'
    }

    $output = Get-RequiredProperty $config 'Output'
    [void](Get-RequiredProperty $output 'CsvPath')
    if (([string]$output.RemovedMemberHandling) -notin @('Retain', 'Exclude')) {
        throw "Output.RemovedMemberHandling must be 'Retain' or 'Exclude'."
    }

    $logging = Get-RequiredProperty $config 'Logging'
    [void](Get-RequiredProperty $logging 'Directory')
    if (([string]$logging.Level) -notin @('Debug', 'Information', 'Warning', 'Error')) {
        throw "Logging.Level must be Debug, Information, Warning, or Error."
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$config.TenantId)) {
        Confirm-GuidString ([string]$config.TenantId) 'TenantId'
    }

    return [pscustomobject]@{
        Value         = $config
        Path          = $resolvedPath
        BaseDirectory = Split-Path -Parent $resolvedPath
    }
}

function Connect-ToolkitGraph {
    param([Parameter(Mandatory)][object]$Config)

    $requiredScopes = @('AuditLog.Read.All', 'GroupMember.Read.All', 'User.ReadBasic.All')
    $context = Get-MgContext -ErrorAction SilentlyContinue
    $tenantMatches = [string]::IsNullOrWhiteSpace([string]$Config.TenantId) -or
        ($context -and $context.TenantId -eq [string]$Config.TenantId)
    $scopeMatches = $context -and (@($requiredScopes | Where-Object { $_ -notin $context.Scopes }).Count -eq 0)

    if ($context -and $tenantMatches -and $scopeMatches) {
        Write-OperationalLog Information "Reusing the existing Microsoft Graph context for tenant $($context.TenantId)."
        return
    }

    $connectParameters = @{
        Scopes    = $requiredScopes
        NoWelcome = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.TenantId)) {
        $connectParameters.TenantId = [string]$Config.TenantId
    }

    Write-OperationalLog Information 'Opening an interactive Microsoft Graph sign-in.'
    Connect-MgGraph @connectParameters | Out-Null
    $script:ConnectedByScript = $true

    $context = Get-MgContext
    if (-not $context) {
        throw 'Microsoft Graph authentication did not produce an active context.'
    }
    Write-OperationalLog Information "Connected to Microsoft Graph tenant $($context.TenantId)."
}

function Get-PagedGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [System.Collections.Generic.List[object]]::new()
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

function Get-TargetGroupUser {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][ValidateSet('Direct', 'Transitive')][string]$MembershipMode
    )

    $relationship = if ($MembershipMode -eq 'Transitive') { 'transitiveMembers' } else { 'members' }
    $select = [Uri]::EscapeDataString('id,displayName,userPrincipalName')
    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/$relationship/microsoft.graph.user?`$select=$select&`$top=999"

    Write-OperationalLog Information "Reading $($MembershipMode.ToLowerInvariant()) user membership for the configured group."
    return @(Get-PagedGraphCollection -Uri $uri)
}

function Get-AppSignIn {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][DateTimeOffset]$StartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EndDateTime,
        [Parameter(Mandatory)][bool]$SuccessfulOnly
    )

    $startText = $StartDateTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endText = $EndDateTime.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = "createdDateTime ge $startText and createdDateTime le $endText and appId eq '$AppId'"

    Write-OperationalLog Information "Reading sign-ins for the configured app from $startText through $endText."
    $signIns = @(Get-MgAuditLogSignIn -Filter $filter -All -Property @(
        'appId', 'createdDateTime', 'status', 'userId'
    ))

    if ($SuccessfulOnly) {
        $signIns = @($signIns | Where-Object {
            $null -ne $_.Status -and [int]$_.Status.ErrorCode -eq 0
        })
    }

    return $signIns
}

function ConvertTo-UtcIsoString {
    param([Parameter(Mandatory)][DateTimeOffset]$Value)
    return $Value.ToUniversalTime().ToString('o')
}

function Protect-CsvText {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($Value -match '^[=+\-@\t\r]') {
        return "'$Value"
    }
    return $Value
}

function ConvertFrom-OptionalTimestamp {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        throw "Existing CSV contains an invalid LastSignInDateTime value: '$Value'."
    }
    return $parsed
}

function Export-ManagementCsv {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid())

    try {
        if ($Rows.Count -eq 0) {
            $emptyRow = [pscustomobject][ordered]@{
                UserPrincipalName    = ''
                DisplayName          = ''
                UserId               = ''
                CurrentGroupMember   = ''
                AppDisplayName       = ''
                AppId                = ''
                LastSignInDateTime   = ''
                LastSeenInCurrentRun = ''
                LastCheckedDateTime  = ''
                Note                 = ''
            }
            $header = $emptyRow | ConvertTo-Csv -NoTypeInformation | Select-Object -First 1
            Set-Content -LiteralPath $temporaryPath -Value $header -Encoding utf8
        }
        else {
            @($Rows) | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding utf8
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

try {
    $configurationDocument = Read-ToolkitConfiguration -Path $ConfigPath
    $config = $configurationDocument.Value

    $script:LogLevel = [string]$config.Logging.Level
    $logDirectory = Resolve-ConfiguredPath -Path ([string]$config.Logging.Directory) -BaseDirectory $configurationDocument.BaseDirectory
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $script:LogFile = Join-Path $logDirectory ('app-last-signin-{0}.log' -f [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'))

    Write-OperationalLog Information 'Starting app last-sign-in inventory.'
    Connect-ToolkitGraph -Config $config

    $checkedAt = [DateTimeOffset]::UtcNow
    $windowStart = $checkedAt.AddDays(-[int]$config.Query.LookbackDays)
    $outputPath = Resolve-ConfiguredPath -Path ([string]$config.Output.CsvPath) -BaseDirectory $configurationDocument.BaseDirectory

    $users = @(Get-TargetGroupUser -GroupId ([string]$config.GroupId) -MembershipMode ([string]$config.MembershipMode))
    Write-OperationalLog Information "Retrieved $($users.Count) user member(s)."

    if ($users.Count -eq 0) {
        Write-OperationalLog Warning 'The group query returned no users. Skipping the app sign-in query.'
        $signIns = @()
    }
    else {
        $signIns = @(Get-AppSignIn `
            -AppId ([string]$config.TargetApp.AppId) `
            -StartDateTime $windowStart `
            -EndDateTime $checkedAt `
            -SuccessfulOnly ([bool]$config.Query.SuccessfulSignInsOnly))
    }
    Write-OperationalLog Information "Retrieved $($signIns.Count) matching sign-in event(s) after configured filtering."

    $latestSignInByUserId = @{}
    foreach ($signIn in $signIns) {
        if ([string]::IsNullOrWhiteSpace([string]$signIn.UserId) -or $null -eq $signIn.CreatedDateTime) {
            continue
        }
        $timestamp = [DateTimeOffset]$signIn.CreatedDateTime
        $userId = [string]$signIn.UserId
        if (-not $latestSignInByUserId.ContainsKey($userId) -or $timestamp -gt $latestSignInByUserId[$userId]) {
            $latestSignInByUserId[$userId] = $timestamp
        }
    }

    $existingRows = @()
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $existingRows = @(Import-Csv -LiteralPath $outputPath -Encoding utf8)
        $requiredColumns = @(
            'UserPrincipalName', 'DisplayName', 'UserId', 'CurrentGroupMember',
            'AppDisplayName', 'AppId', 'LastSignInDateTime',
            'LastSeenInCurrentRun', 'LastCheckedDateTime', 'Note'
        )
        if ($existingRows.Count -gt 0) {
            $missingColumns = @($requiredColumns | Where-Object {
                $_ -notin $existingRows[0].PSObject.Properties.Name
            })
            if ($missingColumns.Count -gt 0) {
                throw "Existing CSV is missing required column(s): $($missingColumns -join ', ')."
            }
        }
        Write-OperationalLog Information "Loaded $($existingRows.Count) row(s) from the existing management CSV."
    }

    $existingByUserId = @{}
    foreach ($row in $existingRows) {
        if ([string]::IsNullOrWhiteSpace([string]$row.UserId)) {
            throw 'Existing CSV contains a row without UserId.'
        }
        if ([string]$row.AppId -ne [string]$config.TargetApp.AppId) {
            throw 'Existing CSV contains a different AppId. Use a separate output file for each app.'
        }
        if ($existingByUserId.ContainsKey([string]$row.UserId)) {
            throw "Existing CSV contains duplicate rows for UserId '$($row.UserId)'."
        }
        $existingByUserId[[string]$row.UserId] = $row
    }

    $currentUserIds = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($user in $users) {
        $userId = [string]$user.id
        if ([string]::IsNullOrWhiteSpace($userId)) {
            throw 'Graph returned a group member without an id.'
        }
        $currentUserIds[$userId] = $true
        $existing = $existingByUserId[$userId]
        $previousTimestamp = if ($existing) {
            ConvertFrom-OptionalTimestamp -Value ([string]$existing.LastSignInDateTime)
        } else {
            $null
        }
        $observedTimestamp = $latestSignInByUserId[$userId]
        $lastSeenInCurrentRun = $null -ne $observedTimestamp

        $latestTimestamp = $previousTimestamp
        if ($observedTimestamp -and (-not $latestTimestamp -or $observedTimestamp -gt $latestTimestamp)) {
            $latestTimestamp = $observedTimestamp
        }

        $eventDescription = if ([bool]$config.Query.SuccessfulSignInsOnly) { 'successful sign-in' } else { 'sign-in event' }
        if ($lastSeenInCurrentRun) {
            $note = "$eventDescription observed in the current query window."
        }
        elseif ($previousTimestamp) {
            $note = "No $eventDescription was observed in the current query window; retained the previously recorded value."
        }
        else {
            $note = "No $eventDescription was observed in the current query window. This does not mean the app has never been used."
        }

        $result.Add([pscustomobject][ordered]@{
            UserPrincipalName   = Protect-CsvText ([string]$user.userPrincipalName)
            DisplayName         = Protect-CsvText ([string]$user.displayName)
            UserId              = $userId
            CurrentGroupMember  = $true
            AppDisplayName      = Protect-CsvText ([string]$config.TargetApp.DisplayName)
            AppId               = [string]$config.TargetApp.AppId
            LastSignInDateTime  = if ($latestTimestamp) { ConvertTo-UtcIsoString $latestTimestamp } else { '' }
            LastSeenInCurrentRun = $lastSeenInCurrentRun
            LastCheckedDateTime = ConvertTo-UtcIsoString $checkedAt
            Note                = $note
        })
    }

    if ([string]$config.Output.RemovedMemberHandling -eq 'Retain') {
        foreach ($existing in $existingRows) {
            if ($currentUserIds.ContainsKey([string]$existing.UserId)) {
                continue
            }
            $result.Add([pscustomobject][ordered]@{
                UserPrincipalName    = Protect-CsvText ([string]$existing.UserPrincipalName)
                DisplayName          = Protect-CsvText ([string]$existing.DisplayName)
                UserId               = [string]$existing.UserId
                CurrentGroupMember   = $false
                AppDisplayName       = Protect-CsvText ([string]$config.TargetApp.DisplayName)
                AppId                = [string]$config.TargetApp.AppId
                LastSignInDateTime   = [string]$existing.LastSignInDateTime
                LastSeenInCurrentRun = $false
                LastCheckedDateTime  = ConvertTo-UtcIsoString $checkedAt
                Note                 = 'Not a current group member; retained from the existing management CSV.'
            })
        }
    }

    $sortedResult = @($result | Sort-Object @{ Expression = 'CurrentGroupMember'; Descending = $true }, UserPrincipalName, UserId)
    Export-ManagementCsv -Rows $sortedResult -Path $outputPath
    Write-OperationalLog Information "Wrote $($sortedResult.Count) row(s) to $outputPath."
    Write-OperationalLog Information 'Completed successfully.'
}
catch {
    Write-OperationalLog Error "Execution failed: $($_.Exception.Message)"
    throw
}
finally {
    if ($script:ConnectedByScript) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}
