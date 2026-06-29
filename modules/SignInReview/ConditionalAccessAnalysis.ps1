function Get-ConditionalAccessPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function ConvertTo-ConditionalAccessKqlStringLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -match '[\r\n]') {
        throw 'KQL configuration values must not contain line breaks.'
    }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function ConvertTo-ConditionalAccessBoolean {
    param([Parameter()][AllowNull()][object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $parsed = $false
    if ($null -ne $Value -and [bool]::TryParse(([string]$Value), [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function ConvertTo-ConditionalAccessDateTimeOffset {
    param([Parameter()][AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function ConvertTo-ConditionalAccessExpirationDate {
    param([Parameter()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )) {
        return $null
    }
    return [DateTimeOffset]::new(
        $parsedDate.Year,
        $parsedDate.Month,
        $parsedDate.Day,
        0,
        0,
        0,
        [TimeSpan]::Zero
    )
}

function Protect-ConditionalAccessMarkdownText {
    param([Parameter()][AllowEmptyString()][string]$Value)

    return ($Value -replace '[\r\n\t]+', ' ' -replace '\|', '\|' -replace '`', "'").Trim()
}

function Read-ConditionalAccessNotAppliedConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $document = Read-SignInReviewJsonDocument -Path $Path
    $config = $document.Value

    if ((Get-SignInReviewRequiredProperty $config 'SchemaVersion') -ne '1.0') {
        throw "Unsupported SchemaVersion. Expected '1.0'."
    }

    Confirm-SignInReviewGuid ([string]$config.TenantId) 'TenantId' -AllowEmpty
    Confirm-SignInReviewGuid ([string]$config.SubscriptionId) 'SubscriptionId' -AllowEmpty
    Confirm-SignInReviewGuid ([string](Get-SignInReviewRequiredProperty $config 'WorkspaceId')) 'WorkspaceId'

    $query = Get-SignInReviewRequiredProperty $config 'Query'
    $lookbackDays = [int](Get-SignInReviewRequiredProperty $query 'LookbackDays')
    if ($lookbackDays -lt 1 -or $lookbackDays -gt 365) {
        throw 'Query.LookbackDays must be between 1 and 365.'
    }
    [void](Get-SignInReviewRequiredProperty $query 'KqlTemplatePath')
    if ($query.IncludeSensitiveDetails -isnot [bool]) {
        throw 'Query.IncludeSensitiveDetails must be true or false.'
    }

    $scope = Get-SignInReviewRequiredProperty $config 'AlertScope'
    $suffixes = @($scope.IncludedUpnSuffixes)
    $patterns = @($scope.IncludedUpnRegexPatterns)
    if ($suffixes.Count -eq 0 -and $patterns.Count -eq 0) {
        throw 'AlertScope must contain at least one included UPN suffix or regular expression.'
    }
    foreach ($value in @(
        $suffixes
        @($scope.ExcludedUpnSuffixes)
        @($scope.ExcludedUserPrincipalNames)
        @($scope.ExcludedTokenIssuerTypes)
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$value) -or ([string]$value).Length -gt 512) {
            throw 'AlertScope string values must be non-empty and no longer than 512 characters.'
        }
        if ([string]$value -match '[\r\n]') {
            throw 'AlertScope string values must not contain line breaks.'
        }
    }
    foreach ($pattern in $patterns) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern) -or ([string]$pattern).Length -gt 512) {
            throw 'AlertScope regular expressions must be non-empty and no longer than 512 characters.'
        }
        try {
            [void][regex]::new([string]$pattern)
        }
        catch {
            throw "AlertScope contains an invalid regular expression: $pattern."
        }
    }

    $graph = Get-SignInReviewRequiredProperty $config 'GraphEnrichment'
    if ([string]$graph.Mode -notin @('Disabled', 'Optional', 'Required')) {
        throw 'GraphEnrichment.Mode must be Disabled, Optional, or Required.'
    }
    $graceDays = [int](Get-SignInReviewRequiredProperty $graph 'NewAccountGracePeriodDays')
    if ($graceDays -lt 1 -or $graceDays -gt 90) {
        throw 'GraphEnrichment.NewAccountGracePeriodDays must be between 1 and 90.'
    }

    $repeated = Get-SignInReviewRequiredProperty $config 'RepeatedMatchingSignIn'
    $minimumDistinctDays = [int](Get-SignInReviewRequiredProperty $repeated 'MinimumDistinctDays')
    $minimumEventCount = [int](Get-SignInReviewRequiredProperty $repeated 'MinimumEventCount')
    if ($minimumDistinctDays -lt 2 -or $minimumDistinctDays -gt $lookbackDays) {
        throw 'RepeatedMatchingSignIn.MinimumDistinctDays must be between 2 and Query.LookbackDays.'
    }
    if ($minimumEventCount -lt 2 -or $minimumEventCount -gt 100000) {
        throw 'RepeatedMatchingSignIn.MinimumEventCount must be between 2 and 100000.'
    }

    $exclusions = Get-SignInReviewRequiredProperty $config 'Exclusions'
    [void](Get-SignInReviewRequiredProperty $exclusions 'UsersPath')
    [void](Get-SignInReviewRequiredProperty $exclusions 'AppsPath')
    if ($exclusions.AllowMissingFiles -isnot [bool]) {
        throw 'Exclusions.AllowMissingFiles must be true or false.'
    }

    $output = Get-SignInReviewRequiredProperty $config 'Output'
    [void](Get-SignInReviewRequiredProperty $output 'Directory')
    foreach ($name in @(
        'GenerateDetailsCsv',
        'GenerateAiPromptMarkdown',
        'GenerateChecklistMarkdown'
    )) {
        if ($output.$name -isnot [bool]) {
            throw "Output.$name must be true or false."
        }
    }
    if ([string]$output.AiIdentityMode -notin @('Alias', 'Masked', 'Raw')) {
        throw 'Output.AiIdentityMode must be Alias, Masked, or Raw.'
    }
    $maximumTopItems = [int](Get-SignInReviewRequiredProperty $output 'AiMaximumTopItems')
    if ($maximumTopItems -lt 1 -or $maximumTopItems -gt 50) {
        throw 'Output.AiMaximumTopItems must be between 1 and 50.'
    }

    $logging = Get-SignInReviewRequiredProperty $config 'Logging'
    [void](Get-SignInReviewRequiredProperty $logging 'Directory')
    if ([string]$logging.Level -notin @('Debug', 'Information', 'Warning', 'Error')) {
        throw 'Logging.Level must be Debug, Information, Warning, or Error.'
    }

    return $document
}

function ConvertTo-ConditionalAccessNotAppliedKql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][DateTimeOffset]$StartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$EndDateTime,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IncludedUpnSuffixes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IncludedUpnRegexPatterns,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludedUpnSuffixes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludedUserPrincipalNames,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludedTokenIssuerTypes,
        [Parameter(Mandatory)][bool]$IncludeSensitiveDetails
    )

    if ($EndDateTime -le $StartDateTime) {
        throw 'EndDateTime must be later than StartDateTime.'
    }
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "KQL template was not found: $TemplatePath."
    }

    $includeParts = [Collections.Generic.List[string]]::new()
    foreach ($suffix in $IncludedUpnSuffixes) {
        $includeParts.Add("UserPrincipalName endswith $(ConvertTo-ConditionalAccessKqlStringLiteral $suffix)")
    }
    foreach ($pattern in $IncludedUpnRegexPatterns) {
        $includeParts.Add("UserPrincipalName matches regex $(ConvertTo-ConditionalAccessKqlStringLiteral $pattern)")
    }
    if ($includeParts.Count -eq 0) {
        throw 'At least one included UPN predicate is required.'
    }

    $excludeParts = [Collections.Generic.List[string]]::new()
    foreach ($suffix in $ExcludedUpnSuffixes) {
        $excludeParts.Add("UserPrincipalName endswith $(ConvertTo-ConditionalAccessKqlStringLiteral $suffix)")
    }
    foreach ($upn in $ExcludedUserPrincipalNames) {
        $excludeParts.Add("UserPrincipalName == $(ConvertTo-ConditionalAccessKqlStringLiteral $upn)")
    }
    $excludePredicate = if ($excludeParts.Count -eq 0) {
        'false'
    }
    else {
        $excludeParts -join ' or '
    }

    $tokenIssuerPredicate = if ($ExcludedTokenIssuerTypes.Count -eq 0) {
        'true'
    }
    else {
        $literals = @($ExcludedTokenIssuerTypes | ForEach-Object {
            ConvertTo-ConditionalAccessKqlStringLiteral $_
        })
        "TokenIssuerType !in ($($literals -join ', '))"
    }

    $sensitiveAggregations = ''
    $sensitiveProjections = ''
    if ($IncludeSensitiveDetails) {
        $sensitiveAggregations = @'
,
    CorrelationId = take_any(tostring(CorrelationId)),
    IPAddress = take_any(tostring(IPAddress)),
    Location = take_any(tostring(Location)),
    LocationDetailsJson = take_any(tostring(LocationDetails)),
    DeviceDetailJson = take_any(tostring(DeviceDetail)),
    UserAgent = take_any(tostring(UserAgent))
'@
        $sensitiveProjections = @'
,
    CorrelationId,
    IPAddress,
    Location,
    LocationDetailsJson,
    DeviceDetailJson,
    UserAgent
'@
    }

    $query = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8
    $replacements = [ordered]@{
        '{{START_UTC}}'                  = $StartDateTime.ToUniversalTime().ToString('o')
        '{{END_UTC}}'                    = $EndDateTime.ToUniversalTime().ToString('o')
        '{{INCLUDE_USER_PREDICATE}}'     = $includeParts -join ' or '
        '{{EXCLUDE_USER_PREDICATE}}'     = $excludePredicate
        '{{TOKEN_ISSUER_PREDICATE}}'     = $tokenIssuerPredicate
        '{{SENSITIVE_AGGREGATIONS}}'     = $sensitiveAggregations.TrimEnd()
        '{{SENSITIVE_PROJECTIONS}}'      = $sensitiveProjections.TrimEnd()
    }
    foreach ($token in $replacements.Keys) {
        $query = $query.Replace($token, [string]$replacements[$token])
    }
    if ($query -match '\{\{[A-Z0-9_]+\}\}') {
        throw 'The KQL template contains an unresolved token.'
    }
    return $query
}

function Import-ConditionalAccessExclusion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UsersPath,
        [Parameter(Mandatory)][string]$AppsPath,
        [Parameter(Mandatory)][bool]$AllowMissingFiles,
        [Parameter()][DateTimeOffset]$AsOfDateTime = [DateTimeOffset]::UtcNow
    )

    $usersById = @{}
    $usersByUpn = @{}
    $appsById = @{}
    $expiredCount = 0

    if (-not (Test-Path -LiteralPath $UsersPath -PathType Leaf)) {
        if (-not $AllowMissingFiles) {
            throw "User exclusion file was not found: $UsersPath."
        }
    }
    else {
        foreach ($row in @(Import-Csv -LiteralPath $UsersPath -Encoding utf8)) {
            $userId = ([string]$row.UserId).Trim().ToLowerInvariant()
            $upn = ([string]$row.UserPrincipalName).Trim().ToLowerInvariant()
            $reason = ([string]$row.Reason).Trim()
            if ([string]::IsNullOrWhiteSpace($userId) -and [string]::IsNullOrWhiteSpace($upn)) {
                throw 'Every user exclusion row must contain UserId or UserPrincipalName.'
            }
            if (-not [string]::IsNullOrWhiteSpace($userId)) {
                Confirm-SignInReviewGuid $userId 'Exclusion.UserId'
            }
            if ([string]::IsNullOrWhiteSpace($reason)) {
                throw 'Every user exclusion row must contain Reason.'
            }
            $expiresOn = ConvertTo-ConditionalAccessExpirationDate ([string]$row.ExpiresOn)
            if (-not [string]::IsNullOrWhiteSpace([string]$row.ExpiresOn) -and $null -eq $expiresOn) {
                throw "Invalid user exclusion ExpiresOn value: $($row.ExpiresOn)."
            }
            if ($null -ne $expiresOn -and $expiresOn.Date -lt $AsOfDateTime.ToUniversalTime().Date) {
                $expiredCount++
                continue
            }
            $record = [pscustomobject]@{
                Source    = 'ExcludeUsers'
                Reason    = $reason
                ExpiresOn = if ($null -eq $expiresOn) { '' } else { $expiresOn.ToString('yyyy-MM-dd') }
            }
            if (-not [string]::IsNullOrWhiteSpace($userId)) {
                if ($usersById.ContainsKey($userId)) {
                    throw "Duplicate excluded UserId: $userId."
                }
                $usersById[$userId] = $record
            }
            if (-not [string]::IsNullOrWhiteSpace($upn)) {
                if ($usersByUpn.ContainsKey($upn)) {
                    throw "Duplicate excluded UserPrincipalName: $upn."
                }
                $usersByUpn[$upn] = $record
            }
        }
    }

    if (-not (Test-Path -LiteralPath $AppsPath -PathType Leaf)) {
        if (-not $AllowMissingFiles) {
            throw "Application exclusion file was not found: $AppsPath."
        }
    }
    else {
        foreach ($row in @(Import-Csv -LiteralPath $AppsPath -Encoding utf8)) {
            $appId = ([string]$row.AppId).Trim().ToLowerInvariant()
            $reason = ([string]$row.Reason).Trim()
            Confirm-SignInReviewGuid $appId 'Exclusion.AppId'
            if ([string]::IsNullOrWhiteSpace($reason)) {
                throw 'Every application exclusion row must contain Reason.'
            }
            $expiresOn = ConvertTo-ConditionalAccessExpirationDate ([string]$row.ExpiresOn)
            if (-not [string]::IsNullOrWhiteSpace([string]$row.ExpiresOn) -and $null -eq $expiresOn) {
                throw "Invalid application exclusion ExpiresOn value: $($row.ExpiresOn)."
            }
            if ($null -ne $expiresOn -and $expiresOn.Date -lt $AsOfDateTime.ToUniversalTime().Date) {
                $expiredCount++
                continue
            }
            if ($appsById.ContainsKey($appId)) {
                throw "Duplicate excluded AppId: $appId."
            }
            $appsById[$appId] = [pscustomobject]@{
                Source    = 'ExcludeApps'
                Reason    = $reason
                ExpiresOn = if ($null -eq $expiresOn) { '' } else { $expiresOn.ToString('yyyy-MM-dd') }
            }
        }
    }

    return [pscustomobject]@{
        UsersById    = $usersById
        UsersByUpn   = $usersByUpn
        AppsById     = $appsById
        ExpiredCount = $expiredCount
    }
}

function Get-SignInReviewUserById {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    Confirm-SignInReviewGuid $UserId 'UserId'
    $select = [Uri]::EscapeDataString('id,displayName,createdDateTime')
    $uri = "https://graph.microsoft.com/v1.0/users/$UserId`?`$select=$select"
    try {
        $user = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject
        return [pscustomobject]@{
            Status = 'Resolved'
            User   = $user
        }
    }
    catch {
        $statusCodeProperty = $_.Exception.PSObject.Properties['ResponseStatusCode']
        $statusCode = if ($statusCodeProperty) { [string]$statusCodeProperty.Value } else { '' }
        if ($statusCode -in @('NotFound', '404')) {
            return [pscustomobject]@{
                Status = 'NotFound'
                User   = $null
            }
        }
        return [pscustomobject]@{
            Status = 'Error'
            User   = $null
        }
    }
}

function ConvertTo-ConditionalAccessNotAppliedReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][hashtable]$DirectoryByUserId,
        [Parameter(Mandatory)][ValidateSet('Disabled', 'Available', 'Unavailable')]
        [string]$GraphEnrichmentState,
        [Parameter(Mandatory)][object]$Exclusions,
        [Parameter(Mandatory)][ValidateRange(1, 90)][int]$NewAccountGracePeriodDays,
        [Parameter(Mandatory)][ValidateRange(2, 365)][int]$MinimumDistinctDays,
        [Parameter(Mandatory)][ValidateRange(2, 100000)][int]$MinimumEventCount,
        [Parameter(Mandatory)][DateTimeOffset]$WindowStartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$WindowEndDateTime,
        [Parameter(Mandatory)][bool]$IncludeSensitiveDetails
    )

    $seenEventIds = @{}
    $duplicateEventCount = 0
    $groups = @{}
    foreach ($eventRecord in $Events) {
        $eventId = ([string](Get-ConditionalAccessPropertyValue $eventRecord 'Id' '')).Trim()
        $timestamp = ConvertTo-ConditionalAccessDateTimeOffset (
            Get-ConditionalAccessPropertyValue $eventRecord 'TimeGenerated'
        )
        if ([string]::IsNullOrWhiteSpace($eventId) -or $null -eq $timestamp) {
            continue
        }
        if ($seenEventIds.ContainsKey($eventId)) {
            $duplicateEventCount++
            continue
        }
        $seenEventIds[$eventId] = $true

        $userId = ([string](Get-ConditionalAccessPropertyValue $eventRecord 'UserId' '')).Trim().ToLowerInvariant()
        $upn = ([string](Get-ConditionalAccessPropertyValue $eventRecord 'UserPrincipalName' '')).Trim().ToLowerInvariant()
        $appId = ([string](Get-ConditionalAccessPropertyValue $eventRecord 'AppId' '')).Trim().ToLowerInvariant()
        $appName = ([string](Get-ConditionalAccessPropertyValue $eventRecord 'AppDisplayName' '')).Trim()
        $userKey = if ($userId) { $userId } elseif ($upn) { $upn } else { '<missing-user>' }
        $appKey = if ($appId) { $appId } elseif ($appName) { $appName.ToLowerInvariant() } else { '<missing-app>' }
        $groupKey = "$userKey|$appKey"

        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [Collections.Generic.List[object]]::new()
        }
        $groups[$groupKey].Add([pscustomobject]@{
            Source    = $eventRecord
            Id        = $eventId
            Timestamp = $timestamp
            UserId    = $userId
            Upn       = $upn
            AppId     = $appId
            AppName   = $appName
        })
    }

    $summaryRows = [Collections.Generic.List[object]]::new()
    $detailRows = [Collections.Generic.List[object]]::new()
    $excludedRows = [Collections.Generic.List[object]]::new()
    $userAliases = @{}
    $appAliases = @{}
    $nextUserAlias = 1
    $nextAppAlias = 1

    foreach ($groupKey in @($groups.Keys | Sort-Object)) {
        $items = @($groups[$groupKey] | Sort-Object Timestamp)
        $first = $items[0]
        $last = $items[-1]
        $userAliasKey = if ($first.UserId) { $first.UserId } else { $first.Upn }
        $appAliasKey = if ($first.AppId) { $first.AppId } else { $first.AppName.ToLowerInvariant() }
        if (-not $userAliases.ContainsKey($userAliasKey)) {
            $userAliases[$userAliasKey] = 'User-{0:D3}' -f $nextUserAlias
            $nextUserAlias++
        }
        if (-not $appAliases.ContainsKey($appAliasKey)) {
            $appAliases[$appAliasKey] = 'App-{0:D3}' -f $nextAppAlias
            $nextAppAlias++
        }
        $userAlias = $userAliases[$userAliasKey]
        $appAlias = $appAliases[$appAliasKey]

        $directoryStatus = switch ($GraphEnrichmentState) {
            'Disabled' { 'Disabled' }
            'Unavailable' { 'Unavailable' }
            default { 'NotFound' }
        }
        $directoryUser = $null
        if ($GraphEnrichmentState -eq 'Available' -and $DirectoryByUserId.ContainsKey($first.UserId)) {
            $directoryResult = $DirectoryByUserId[$first.UserId]
            $directoryStatus = [string]$directoryResult.Status
            if ($directoryStatus -eq 'Resolved') {
                $directoryUser = $directoryResult.User
            }
        }

        $createdDateTime = if ($null -ne $directoryUser) {
            ConvertTo-ConditionalAccessDateTimeOffset (
                Get-ConditionalAccessPropertyValue $directoryUser 'createdDateTime'
            )
        }
        else {
            $null
        }
        $displayName = if ($null -ne $directoryUser) {
            [string](Get-ConditionalAccessPropertyValue $directoryUser 'displayName' '')
        }
        else {
            [string](Get-ConditionalAccessPropertyValue $first.Source 'UserDisplayName' '')
        }

        $accountAgeDays = ''
        $isRecentAccount = $false
        $recheckAfter = ''
        if ($null -ne $createdDateTime -and $createdDateTime -le $last.Timestamp) {
            $age = $last.Timestamp - $createdDateTime
            $accountAgeDays = [Math]::Max(0, [Math]::Floor($age.TotalDays))
            $isRecentAccount = $age.TotalDays -le $NewAccountGracePeriodDays
            if ($isRecentAccount) {
                $recheckAfter = $createdDateTime.AddDays($NewAccountGracePeriodDays).ToString('o')
            }
        }

        $distinctDays = @($items | ForEach-Object {
            $_.Timestamp.ToUniversalTime().ToString('yyyy-MM-dd')
        } | Sort-Object -Unique).Count
        $isRepeated = $items.Count -ge $MinimumEventCount -and
            $distinctDays -ge $MinimumDistinctDays
        $interactiveValues = @($items | ForEach-Object {
            ConvertTo-ConditionalAccessBoolean (
                Get-ConditionalAccessPropertyValue $_.Source 'IsInteractive'
            )
        })
        $interactiveCount = @($interactiveValues | Where-Object { $_ -eq $true }).Count
        $nonInteractiveCount = @($interactiveValues | Where-Object { $_ -eq $false }).Count
        $isNonInteractiveOnly = $nonInteractiveCount -eq $items.Count -and $items.Count -gt 0

        $exclusionRecords = [Collections.Generic.List[object]]::new()
        if ($first.UserId -and $Exclusions.UsersById.ContainsKey($first.UserId)) {
            $exclusionRecords.Add($Exclusions.UsersById[$first.UserId])
        }
        if ($first.Upn -and $Exclusions.UsersByUpn.ContainsKey($first.Upn)) {
            $exclusionRecords.Add($Exclusions.UsersByUpn[$first.Upn])
        }
        if ($first.AppId -and $Exclusions.AppsById.ContainsKey($first.AppId)) {
            $exclusionRecords.Add($Exclusions.AppsById[$first.AppId])
        }

        if ($exclusionRecords.Count -gt 0) {
            $sources = @($exclusionRecords | ForEach-Object Source | Sort-Object -Unique) -join ';'
            $reasons = @($exclusionRecords | ForEach-Object Reason | Sort-Object -Unique) -join '; '
            $expires = @($exclusionRecords | ForEach-Object ExpiresOn |
                Where-Object { $_ } | Sort-Object -Unique) -join ';'
            $excludedRows.Add([pscustomobject][ordered]@{
                UserAlias            = $userAlias
                AppAlias             = $appAlias
                UserPrincipalName    = Protect-SignInReviewCsvText $first.Upn
                UserId               = $first.UserId
                AppDisplayName       = Protect-SignInReviewCsvText $first.AppName
                AppId                = $first.AppId
                SignInCount          = $items.Count
                FirstSeen            = $first.Timestamp.ToString('o')
                LastSeen             = $last.Timestamp.ToString('o')
                ExcludedBy           = $sources
                ExcludeReason        = Protect-SignInReviewCsvText $reasons
                ExclusionExpiresOn   = $expires
            })
            continue
        }

        if (-not $first.UserId -or -not $first.AppId) {
            $category = 'Unknown'
            $categoryJa = '要確認'
            $reasonCode = 'StableIdentifierMissing'
            $causeJa = 'ユーザーIDまたはアプリIDを取得できず、安定した単位で分類できません。'
            $actionJa = '元のサインインログと対象アプリを手動で確認してください。'
            $priority = 'High'
            $priorityJa = '高'
        }
        elseif ($isRecentAccount) {
            $category = 'LikelyRecentAccountProvisioning'
            $categoryJa = '新規作成アカウントの設定途中の可能性'
            $reasonCode = 'AccountCreatedWithinGracePeriod'
            $causeJa = "最新検知時点でアカウント作成から${accountAgeDays}日です。"
            $actionJa = '設定反映の猶予期限後に再確認し、継続する場合は条件付きアクセスの対象条件を確認してください。'
            $priority = 'Low'
            $priorityJa = '低'
        }
        elseif ($isRepeated) {
            $category = 'RepeatedMatchingSignIn'
            $categoryJa = '条件一致サインインの複数日継続'
            $reasonCode = 'MatchingSignInsObservedOnMultipleDays'
            $causeJa = "条件に一致する異なるサインインが${distinctDays}日で確認されています。"
            $actionJa = '条件付きアクセスの対象ユーザー、グループ、アプリ、除外条件を優先して確認してください。'
            $priority = 'High'
            $priorityJa = '高'
        }
        elseif ($isNonInteractiveOnly) {
            $category = 'NonInteractiveOnly'
            $categoryJa = '非対話サインインのみ'
            $reasonCode = 'OnlyNonInteractiveSignInsObserved'
            $causeJa = '取得した条件一致イベントはすべて非対話サインインです。'
            $actionJa = 'トークン更新や連携処理など、ユーザーの代理で動作する処理を確認してください。'
            $priority = 'Medium'
            $priorityJa = '中'
        }
        else {
            $category = 'PolicyScopeReviewRequired'
            $categoryJa = 'CA対象条件の確認が必要'
            $reasonCode = 'NoKnownExplanationMatched'
            $causeJa = '新規作成アカウント、既知除外、複数日継続の条件に該当しません。'
            $actionJa = '条件付きアクセスの対象ユーザー、グループ、アプリ、クライアント条件を確認してください。'
            $priority = 'Medium'
            $priorityJa = '中'
        }

        $summaryRows.Add([pscustomobject][ordered]@{
            UserAlias                = $userAlias
            AppAlias                 = $appAlias
            UserPrincipalName        = Protect-SignInReviewCsvText $first.Upn
            DisplayName              = Protect-SignInReviewCsvText $displayName
            UserId                   = $first.UserId
            AppDisplayName           = Protect-SignInReviewCsvText $first.AppName
            AppId                    = $first.AppId
            UserCreatedDateTime      = if ($null -eq $createdDateTime) { '' } else { $createdDateTime.ToString('o') }
            AccountAgeDaysAtLastSeen = $accountAgeDays
            SignInCount              = $items.Count
            DistinctDetectionDays    = $distinctDays
            InteractiveSignInCount   = $interactiveCount
            NonInteractiveSignInCount = $nonInteractiveCount
            FirstSeen                = $first.Timestamp.ToString('o')
            LastSeen                 = $last.Timestamp.ToString('o')
            Category                 = $category
            CategoryJa               = $categoryJa
            ReasonCode               = $reasonCode
            EstimatedCauseJa         = $causeJa
            RecommendedActionJa      = $actionJa
            ReviewPriority           = $priority
            ReviewPriorityJa         = $priorityJa
            RecheckAfterDateTime     = $recheckAfter
            IsRecentAccountCandidate = $isRecentAccount
            IsRepeatedMatchingSignIn = $isRepeated
            GraphEnrichmentStatus    = $directoryStatus
            EvaluationWindowStartDateTime = $WindowStartDateTime.ToUniversalTime().ToString('o')
            EvaluationWindowEndDateTime = $WindowEndDateTime.ToUniversalTime().ToString('o')
        })

        foreach ($item in $items) {
            $policyResults = @(
                Get-ConditionalAccessPropertyValue $item.Source 'PolicyResults' @()
            ) -join ';'
            $detail = [ordered]@{
                TimeGenerated          = $item.Timestamp.ToString('o')
                EventId                = $item.Id
                UserAlias              = $userAlias
                AppAlias               = $appAlias
                UserPrincipalName      = Protect-SignInReviewCsvText $item.Upn
                UserId                 = $item.UserId
                AppDisplayName         = Protect-SignInReviewCsvText $item.AppName
                AppId                  = $item.AppId
                ClientAppUsed          = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'ClientAppUsed' ''))
                ConditionalAccessStatus = [string](Get-ConditionalAccessPropertyValue $item.Source 'ConditionalAccessStatus' '')
                PolicyResults          = Protect-SignInReviewCsvText $policyResults
                ResultType             = [string](Get-ConditionalAccessPropertyValue $item.Source 'ResultType' '')
                ResultDescription      = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'ResultDescription' ''))
                IsInteractive          = Get-ConditionalAccessPropertyValue $item.Source 'IsInteractive' ''
                Category               = $category
                CategoryJa             = $categoryJa
                ReviewHintJa           = $actionJa
            }
            if ($IncludeSensitiveDetails) {
                $detail.CorrelationId = [string](Get-ConditionalAccessPropertyValue $item.Source 'CorrelationId' '')
                $detail.IPAddress = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'IPAddress' ''))
                $detail.Location = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'Location' ''))
                $detail.LocationDetailsJson = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'LocationDetailsJson' ''))
                $detail.DeviceDetailJson = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'DeviceDetailJson' ''))
                $detail.UserAgent = Protect-SignInReviewCsvText ([string](Get-ConditionalAccessPropertyValue $item.Source 'UserAgent' ''))
            }
            $detailRows.Add([pscustomobject]$detail)
        }
    }

    return [pscustomobject]@{
        SummaryRows       = $summaryRows.ToArray()
        DetailRows        = $detailRows.ToArray()
        ExcludedRows      = $excludedRows.ToArray()
        UniqueEventCount  = $seenEventIds.Count
        DuplicateEventCount = $duplicateEventCount
    }
}

function ConvertTo-ConditionalAccessAiMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SummaryRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExcludedRows,
        [Parameter(Mandatory)][DateTimeOffset]$WindowStartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$WindowEndDateTime,
        [Parameter(Mandatory)][ValidateSet('Alias', 'Masked', 'Raw')][string]$IdentityMode,
        [Parameter(Mandatory)][ValidateRange(1, 50)][int]$MaximumTopItems
    )

    function Get-UserLabel {
        param([object]$Row, [string]$Mode)
        if ($Mode -eq 'Raw') {
            return Protect-ConditionalAccessMarkdownText ([string]$Row.UserPrincipalName)
        }
        if ($Mode -eq 'Masked') {
            $upn = [string]$Row.UserPrincipalName
            if ($upn -match '^(.).*(@.+)$') {
                return Protect-ConditionalAccessMarkdownText ($Matches[1] + '***' + $Matches[2])
            }
        }
        return [string]$Row.UserAlias
    }

    function Get-AppLabel {
        param([object]$Row, [string]$Mode)
        if ($Mode -eq 'Raw') {
            return Protect-ConditionalAccessMarkdownText ([string]$Row.AppDisplayName)
        }
        return [string]$Row.AppAlias
    }

    $totalEvents = (@($SummaryRows | Measure-Object -Property SignInCount -Sum).Sum)
    if ($null -eq $totalEvents) {
        $totalEvents = 0
    }
    $categoryCounts = @($SummaryRows | Group-Object Category, CategoryJa | Sort-Object Count -Descending)
    $userCounts = @{}
    $appCounts = @{}
    foreach ($row in $SummaryRows) {
        $userLabel = Get-UserLabel $row $IdentityMode
        $appLabel = Get-AppLabel $row $IdentityMode
        $userCounts[$userLabel] = [int]$userCounts[$userLabel] + [int]$row.SignInCount
        $appCounts[$appLabel] = [int]$appCounts[$appLabel] + [int]$row.SignInCount
    }
    $sortByCountThenName = @(
        @{ Expression = { $_.Value }; Descending = $true },
        @{ Expression = { $_.Name }; Ascending = $true }
    )
    $topUsers = @($userCounts.GetEnumerator() | Sort-Object -Property $sortByCountThenName |
        Select-Object -First $MaximumTopItems)
    $topApps = @($appCounts.GetEnumerator() | Sort-Object -Property $sortByCountThenName |
        Select-Object -First $MaximumTopItems)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# 条件付きアクセス未適用アラート 分析相談メモ')
    $lines.Add('')
    $lines.Add('> 集計済み情報だけを記載しています。原因の断定やアカウント変更の自動実行には使用しないでください。')
    $lines.Add('')
    $lines.Add('## 対象')
    $lines.Add('')
    $lines.Add("- 期間: $($WindowStartDateTime.ToUniversalTime().ToString('o')) ～ $($WindowEndDateTime.ToUniversalTime().ToString('o'))")
    $lines.Add("- 条件一致イベント数: $totalEvents")
    $lines.Add("- ユーザー数: $($userCounts.Count)")
    $lines.Add("- アプリ数: $($appCounts.Count)")
    $lines.Add("- 除外グループ数: $($ExcludedRows.Count)")
    $lines.Add('')
    $lines.Add('## 推定カテゴリ別件数')
    $lines.Add('')
    if ($categoryCounts.Count -eq 0) {
        $lines.Add('- 対象なし')
    }
    else {
        foreach ($category in $categoryCounts) {
            $sample = $category.Group[0]
            $lines.Add(('- {0} (`{1}`): {2}' -f $sample.CategoryJa, $sample.Category, $category.Count))
        }
    }
    $lines.Add('')
    $lines.Add('## 上位ユーザー')
    $lines.Add('')
    if ($topUsers.Count -eq 0) {
        $lines.Add('- 対象なし')
    }
    else {
        foreach ($entry in $topUsers) {
            $lines.Add("- $($entry.Name): $($entry.Value)件")
        }
    }
    $lines.Add('')
    $lines.Add('## 上位アプリ')
    $lines.Add('')
    if ($topApps.Count -eq 0) {
        $lines.Add('- 対象なし')
    }
    else {
        foreach ($entry in $topApps) {
            $lines.Add("- $($entry.Name): $($entry.Value)件")
        }
    }
    $lines.Add('')
    $lines.Add('## AIに確認してほしい観点')
    $lines.Add('')
    $lines.Add('- 新規作成アカウントの設定途中として説明できる可能性')
    $lines.Add('- 複数日にわたる条件一致イベントを優先調査すべきか')
    $lines.Add('- 非対話サインインやクライアント条件による影響')
    $lines.Add('- CA対象ユーザー、グループ、アプリ、除外条件で次に確認すべき点')
    $lines.Add('- この情報だけでは断定できない点と、追加で必要な証拠')
    return $lines -join [Environment]::NewLine
}

function ConvertTo-ConditionalAccessChecklistMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTimeOffset]$WindowStartDateTime,
        [Parameter(Mandatory)][DateTimeOffset]$WindowEndDateTime,
        [Parameter(Mandatory)][int]$NewAccountGracePeriodDays,
        [Parameter(Mandatory)][int]$MinimumDistinctDays,
        [Parameter(Mandatory)][int]$MinimumEventCount
    )

    return @"
# 条件付きアクセス未適用アラート 初動確認チェックリスト

- 対象期間: $($WindowStartDateTime.ToUniversalTime().ToString('o')) ～ $($WindowEndDateTime.ToUniversalTime().ToString('o'))
- 新規作成アカウント猶予日数: $NewAccountGracePeriodDays 日
- 複数日継続の基準: $MinimumDistinctDays 日以上、かつ $MinimumEventCount イベント以上

## 1. レポート条件

- [ ] アラートと分析レポートのKQL条件が一致している
- [ ] 対象期間とタイムゾーンを確認した
- [ ] Graph補完に失敗したユーザーがいないか確認した
- [ ] 同じイベントIDが重複集計されていないことを確認した

## 2. 新規作成アカウント由来の可能性

- [ ] ユーザー作成日が直近 $NewAccountGracePeriodDays 日以内か確認した
- [ ] 月初や入社日前後の作成タイミングと一致するか確認した
- [ ] グループ、属性、ライセンスの設定途中でないか確認した
- [ ] 猶予期限後の再確認日を決めた

## 3. 継続性と除外

- [ ] 同一ユーザー・同一アプリの異なるイベントが複数日に存在するか確認した
- [ ] ステートレスアラートの重複通知を新規イベントと誤認していない
- [ ] 除外ユーザー・除外アプリの理由と有効期限を確認した

## 4. 本格調査

- [ ] 対象ユーザーとグループがCAポリシーの対象か確認した
- [ ] 対象アプリがCAポリシーの対象か確認した
- [ ] ユーザー、グループ、アプリの除外条件を確認した
- [ ] クライアントアプリ、デバイス、場所などの条件を確認した
- [ ] 非対話サインインやバックグラウンド処理の影響を確認した
- [ ] `notApplied`だけで設定不備と断定していない

## 5. 情報の取扱い

- [ ] CSVとMarkdownを承認された保存先に置いた
- [ ] AIへ共有する前に個人情報と内部アプリ情報を確認した
- [ ] IP、場所、端末、UserAgentを必要なく共有していない
- [ ] レポートをアカウント無効化や削除処理へ直接渡していない
"@
}
