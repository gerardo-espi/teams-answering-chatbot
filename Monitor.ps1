#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Enable', 'Disable', 'AllowPerson', 'AllowGroup', 'RemovePerson',
        'RemoveGroup', 'Begin', 'Plan', 'Check', 'Reserve', 'Complete', 'Finish', 'Drafts', 'Dismiss')]
    [string]$Command = 'Status',
    [string]$TargetId,
    [ValidateSet('casualRelaxed', 'casualCautious', 'mixedSelective', 'workAcknowledgment',
        'workDraft', 'draftAll', 'monitorOnly', 'disabled')][string]$Policy,
    [ValidateSet('auto', 'draft')][string]$Mode = 'auto',
    [string[]]$AutoTopics = @('greeting', 'thanks', 'farewell', 'wellbeing', 'weekend', 'hobbies', 'social'),
    [switch]$Approved,
    [switch]$ReconsiderSkipped,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
# Keep emoji and non-ASCII reply text intact over piped stdin/stdout.
[Console]::InputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:Topics = @('greeting', 'thanks', 'farewell', 'wellbeing', 'weekend', 'hobbies', 'social')
$script:Policies = @{
    casualRelaxed = @{ mode = 'auto'; autoTopics = $script:Topics; conversationStyle = 'relaxedCasual'; conversationContext = 'nonWorkDefault' }
    casualCautious = @{ mode = 'auto'; autoTopics = @('greeting', 'thanks', 'farewell'); conversationStyle = 'strict'; conversationContext = 'nonWorkDefault' }
    mixedSelective = @{ mode = 'auto'; autoTopics = $script:Topics; conversationStyle = 'strict'; conversationContext = 'mixed' }
    workAcknowledgment = @{ mode = 'auto'; autoTopics = @('acknowledgment'); conversationStyle = 'strict'; conversationContext = 'work' }
    workDraft = @{ mode = 'draft'; autoTopics = @(); conversationStyle = 'strict'; conversationContext = 'work' }
    draftAll = @{ mode = 'draft'; autoTopics = @(); conversationStyle = 'strict'; conversationContext = 'mixed' }
    monitorOnly = @{ mode = 'draft'; autoTopics = @(); conversationStyle = 'strict'; conversationContext = 'mixed' }
    disabled = @{ mode = 'draft'; autoTopics = @(); conversationStyle = 'strict'; conversationContext = 'mixed' }
}

function Get-EffectiveRule($Rule) {
    if (-not $Rule.policy) { return $Rule }
    if (-not $script:Policies.ContainsKey($Rule.policy)) { throw 'Unknown chat policy.' }
    $preset = $script:Policies[$Rule.policy]
    $effective = @{} + $Rule
    foreach ($name in @('conversationStyle', 'conversationContext')) { $effective[$name] = $preset[$name] }
    $effective.mode = if ($Rule.mode -eq 'draft') { 'draft' } else { $preset.mode }
    $effective.autoTopics = @($Rule.autoTopics | Where-Object { $_ -in $preset.autoTopics })
    return $effective
}

function New-TargetRule([string]$PolicyName, [datetimeoffset]$AddedAt, [string]$RequestedMode, $RequestedTopics) {
    if (-not $PolicyName -or -not $script:Policies.ContainsKey($PolicyName)) {
        throw 'An explicit Policy is required. Ask the user to choose a chat policy before whitelisting.'
    }
    $preset = $script:Policies[$PolicyName]
    if ($RequestedMode -eq 'auto' -and $preset.mode -ne 'auto') { throw 'This policy cannot auto-send.' }
    $topics = if ($null -eq $RequestedTopics) { @($preset.autoTopics) } else { @($RequestedTopics) }
    foreach ($topic in $topics) {
        if ($topic -notin $preset.autoTopics) { throw "Automatic topic is not allowed by policy: $topic" }
    }
    return @{
        policy = $PolicyName; addedAt = $AddedAt.ToString('o')
        mode = $(if ($RequestedMode) { $RequestedMode } else { $preset.mode })
        autoTopics = @($topics)
    }
}

function Get-RuleSignature($Rule) {
    return ([ordered]@{
        policy = [string]$Rule.policy; mode = $Rule.mode
        autoTopics = @($Rule.autoTopics | Sort-Object)
        conversationStyle = [string]$Rule.conversationStyle
        conversationContext = [string]$Rule.conversationContext
    } | ConvertTo-Json -Compress)
}

function Test-PolicyCandidate($Rule, [string]$Classification, [string]$Topic, [string]$Reply) {
    if ($Rule.policy -in @('monitorOnly', 'disabled')) { return $false }
    if ($Rule.policy -eq 'workAcknowledgment') {
        return ($Classification -ceq 'work' -and $Topic -ceq 'acknowledgment' -and
            $Reply -ceq 'Thanks for the update.')
    }
    if ($Rule.policy -eq 'workDraft') {
        return ($Classification -cin @('work', 'mixed') -and $Topic -ceq 'work')
    }
    if ($Classification -ceq 'casual') { return ($Topic -cin $script:Topics) }
    return ($Rule.policy -in @('mixedSelective', 'draftAll') -and
        $Classification -cin @('work', 'mixed') -and $Topic -ceq 'work')
}

function Test-EntryPolicy($Entry, $Rule) {
    if (-not $Entry.ruleSignature) {
        return (-not $Rule.policy -and (Test-PolicyCandidate $Rule 'casual' $Entry.topic $Entry.reply))
    }
    return ($Entry.ruleSignature -ceq (Get-RuleSignature $Rule) -and
        (Test-PolicyCandidate $Rule $Entry.classification $Entry.topic $Entry.reply))
}

function Assert-Config($Config) {
    if ($Config.enabled -isnot [bool]) { throw 'enabled must be a boolean.' }
    foreach ($name in @('maxMessageAgeMinutes', 'cooldownSeconds')) {
        if (($Config[$name] -isnot [int] -and $Config[$name] -isnot [long]) -or
            $Config[$name] -lt 1 -or $Config[$name] -gt 3600) { throw "Invalid $name." }
    }
    foreach ($section in @('people', 'groupChats')) {
        if ($Config[$section] -isnot [Collections.IDictionary]) { throw "Invalid $section." }
        foreach ($id in $Config[$section].Keys) {
            $rule = $Config[$section][$id]
            if ($rule.Contains('policy') -and $rule.policy -notin $script:Policies.Keys) { throw 'Unknown chat policy.' }
            $guid = [guid]::Empty
            if ([string]::IsNullOrWhiteSpace($id) -or
                ($section -eq 'people' -and -not [guid]::TryParseExact($id, 'D', [ref]$guid))) {
                throw 'People must use Entra object IDs; groups must use exact chat IDs.'
            }
            if ($rule.mode -notin @('auto', 'draft') -or $rule.autoTopics -isnot [array]) {
                throw 'Each target needs mode, autoTopics, and addedAt.'
            }
            $null = [datetimeoffset]::Parse($rule.addedAt)
            foreach ($topic in $rule.autoTopics) {
                $allowed = if ($rule.policy) { $script:Policies[$rule.policy].autoTopics } else { $script:Topics }
                if ($topic -notin $allowed) { throw "Unsupported automatic topic: $topic" }
            }
        }
    }
}

function New-MonitorState {
    return @{ accountId = ''; lease = $null; checkpoints = @{}; entries = @{} }
}

function Get-TargetRule($Config, $Chat, [string]$SelfId) {
    if ($Chat.chatType -eq 'group') {
        if ($Config.groupChats.Contains($Chat.id) -and $Config.groupChats[$Chat.id].policy -ne 'disabled') {
            return Get-EffectiveRule $Config.groupChats[$Chat.id]
        }
        return $null
    }
    if ($Chat.chatType -ne 'oneOnOne') { return $null }
    $members = @($Chat.members)
    if ($members.Count -ne 2 -or $SelfId -notin $members.userId) { return $null }
    $other = @($members | Where-Object { $_.userId -and $_.userId -ne $SelfId })
    if ($other.Count -eq 1 -and $Config.people.Contains($other[0].userId)) {
        if ($Config.people[$other[0].userId].policy -ne 'disabled') {
            return Get-EffectiveRule $Config.people[$other[0].userId]
        }
    }
    return $null
}

function Get-MessageKey([string]$ChatId, [string]$MessageId) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$ChatId`n$MessageId")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-MessageHash($Message) {
    $snapshot = [ordered]@{
        id = [string]$Message.id
        sender = [string]$Message.from.user.id
        application = [string]$Message.from.application.id
        created = ([datetimeoffset]$Message.createdDateTime).ToUniversalTime().ToString('o')
        type = [string]$Message.messageType
        contentType = [string]$Message.body.contentType
        content = [string]$Message.body.content
        edited = [string]$Message.lastEditedDateTime
        deleted = [string]$Message.deletedDateTime
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Assert-Lease($State, [string]$RunId, [datetimeoffset]$Now) {
    if (-not $State.lease -or $State.lease.id -ne $RunId -or
        [datetimeoffset]$State.lease.expiresAt -le $Now) { throw 'Missing or expired poll lease.' }
}

function Start-Poll($Config, $State, [datetimeoffset]$Now, [bool]$Reconsider = $false) {
    if (-not $Config.enabled) { return @{ action = 'skip'; reason = 'disabled' } }
    if ($Config.people.Count -eq 0 -and $Config.groupChats.Count -eq 0) {
        return @{ action = 'skip'; reason = 'empty-whitelist' }
    }
    $active = @($Config.people.Values) + @($Config.groupChats.Values) |
        Where-Object { $_.policy -ne 'disabled' }
    if (-not $active) { return @{ action = 'skip'; reason = 'all-targets-disabled' } }
    if ($State.lease -and [datetimeoffset]$State.lease.expiresAt -gt $Now) {
        return @{ action = 'skip'; reason = 'poll-already-running' }
    }
    foreach ($key in @($State.entries.Keys)) {
        if ([datetimeoffset]$State.entries[$key].createdAt -lt $Now.AddDays(-1)) {
            $State.entries.Remove($key)
        }
    }
    $State.lease = @{
        id = [guid]::NewGuid().ToString()
        through = $Now.ToString('o')
        expiresAt = $Now.AddMinutes(4).ToString('o')
        targets = @{}
        reconsiderSkipped = $Reconsider
    }
    $metadata = @(
        foreach ($id in $Config.people.Keys) {
            if ($Config.people[$id].policy -eq 'disabled') { continue }
            $filter = [uri]::EscapeDataString("chatType eq 'oneOnOne' and members/any(m:m/microsoft.graph.aadUserConversationMember/userId eq '$id')")
            @{
                kind = 'person'; targetId = $id
                path = "/me/chats?`$filter=$filter&`$select=id,chatType,members&`$expand=members&`$top=10"
            }
        }
        foreach ($id in $Config.groupChats.Keys) {
            if ($Config.groupChats[$id].policy -eq 'disabled') { continue }
            @{
                kind = 'group'; targetId = $id
                path = "/chats/$([uri]::EscapeDataString($id))?`$select=id,chatType"
            }
        }
    )
    return @{ action = 'poll'; runId = $State.lease.id; through = $State.lease.through; metadata = $metadata }
}

function Test-ResumableReply($Entry, $Rule) {
    return ($null -ne $Entry -and $Entry.status -eq 'pending' -and
        $Entry.mode -eq 'auto' -and -not $Entry.reservedAt -and -not $Entry.reservationId -and
        $Rule.mode -eq 'auto' -and $Entry.topic -in $Rule.autoTopics -and
        (Test-EntryPolicy $Entry $Rule))
}

function Get-PollPlan($Config, $State, $InputData, [datetimeoffset]$Now) {
    Assert-Lease $State $InputData.runId $Now
    if (-not $Config.enabled) { throw 'Plugin is disabled.' }
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($InputData.selfId, 'D', [ref]$guid)) { throw 'Missing signed-in account ID.' }
    if ($State.accountId -and $State.accountId -ne $InputData.selfId) {
        throw 'Teams connection changed accounts. Refusing to read or reply.'
    }
    $State.accountId = $InputData.selfId
    $plans = @()
    foreach ($chat in $InputData.chats) {
        $rule = Get-TargetRule $Config $chat $State.accountId
        if ($null -eq $rule) { continue }
        $since = [datetimeoffset]$rule.addedAt
        if (-not $State.lease.reconsiderSkipped -and $State.checkpoints.Contains($chat.id) -and [datetimeoffset]$State.checkpoints[$chat.id] -gt $since) {
            $since = [datetimeoffset]$State.checkpoints[$chat.id]
        }
        foreach ($entry in $State.entries.Values) {
            if ($entry.chatId -eq $chat.id -and (Test-ResumableReply $entry $rule) -and
                [datetimeoffset]$entry.createdAt -gt [datetimeoffset]$rule.addedAt) {
                $pendingSince = ([datetimeoffset]$entry.createdAt).AddTicks(-1)
                if ($pendingSince -lt $since) { $since = $pendingSince }
            }
        }
        if ($since -lt $Now.AddMinutes(-$Config.maxMessageAgeMinutes)) {
            $since = $Now.AddMinutes(-$Config.maxMessageAgeMinutes)
        }
        $State.lease.targets[$chat.id] = $since.ToString('o')
        $filter = [uri]::EscapeDataString("lastModifiedDateTime gt $($since.AddSeconds(-15).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))")
        $encoded = [uri]::EscapeDataString($chat.id)
        $plans += @{
            chatId = $chat.id
            rule = $rule
            since = $since.ToString('o')
            through = $State.lease.through
            path = "/chats/$encoded/messages?`$top=50&`$orderby=lastModifiedDateTime desc&`$filter=$filter"
            contextPath = "/chats/$encoded/messages?`$top=10&`$orderby=createdDateTime desc&`$select=id,createdDateTime,from,body,messageType,lastEditedDateTime,deletedDateTime,attachments,mentions"
            fallbackContextPath = "/chats/$encoded/messages?`$top=3&`$orderby=createdDateTime desc&`$select=id,createdDateTime,from,body,messageType,lastEditedDateTime,deletedDateTime,attachments,mentions"
        }
    }
    return @{ runId = $State.lease.id; chats = $plans }
}

function Get-Eligibility($Config, $State, $Chat, $Message, [datetimeoffset]$Now) {
    if (-not $Config.enabled -or -not $Message.id -or -not $Chat.id) { return $null }
    $target = Get-TargetRule $Config $Chat $State.accountId
    if ($null -eq $target -or -not $Message.from.user.id -or
        $Message.from.user.id -eq $State.accountId -or $Message.from.application -or
        $Message.messageType -ne 'message' -or $Message.deletedDateTime -or
        $Message.lastEditedDateTime -or @($Message.attachments).Count -gt 0 -or
        @($Message.mentions).Count -gt 0) { return $null }
    if ($Chat.chatType -eq 'oneOnOne' -and $Message.from.user.id -notin @($Chat.members.userId)) {
        return $null
    }
    try { $created = [datetimeoffset]$Message.createdDateTime } catch { return $null }
    if ($created -gt $Now -or $created -le [datetimeoffset]$target.addedAt -or
        $created -lt $Now.AddMinutes(-$Config.maxMessageAgeMinutes)) { return $null }
    return $target
}

function Add-Candidate($Config, $State, $InputData, [datetimeoffset]$Now) {
    Assert-Lease $State $InputData.runId $Now
    $chat = $InputData.chat
    $message = $InputData.message
    if (-not $State.lease.targets.Contains($chat.id)) { throw 'Chat was not authorized by Plan.' }
    $target = Get-Eligibility $Config $State $chat $message $Now
    if ($null -eq $target -or -not (Test-PolicyCandidate $target $InputData.classification $InputData.topic $InputData.reply)) {
        return @{ action = 'skip'; reason = 'not-eligible' }
    }
    $created = [datetimeoffset]$message.createdDateTime
    if ($created -le [datetimeoffset]$State.lease.targets[$chat.id] -or
        $created -gt [datetimeoffset]$State.lease.through) {
        return @{ action = 'skip'; reason = 'outside-poll-window' }
    }
    $key = Get-MessageKey $chat.id $message.id
    if ($State.entries.Contains($key)) {
        $entry = $State.entries[$key]
        if (-not (Test-ResumableReply $entry $target) -or $InputData.topic -notin $target.autoTopics -or
            ($entry.classification -and $entry.classification -cne $InputData.classification) -or
            $entry.runId -eq $InputData.runId -or
            $entry.messageHash -ne (Get-MessageHash $message)) {
            return @{ action = 'skip'; reason = 'already-handled' }
        }
        $entry.runId = $InputData.runId
        return @{ action = 'auto'; id = $key; reply = $entry.reply; chatId = $chat.id }
    }
    if ($InputData.reply -isnot [string] -or [string]::IsNullOrWhiteSpace($InputData.reply) -or
        $InputData.reply.Length -gt 500 -or $InputData.reply -match '(?i)https?://|<[^>]+>') {
        throw 'Reply must be short plain text without links or markup.'
    }
    $mode = if ($target.mode -eq 'auto' -and $InputData.topic -in $target.autoTopics) { 'auto' } else { 'draft' }
    $State.entries[$key] = @{
        chatId = $chat.id
        messageId = $message.id
        messageHash = Get-MessageHash $message
        original = [string]$message.body.content
        reply = $InputData.reply
        topic = $InputData.topic
        classification = $InputData.classification
        ruleSignature = Get-RuleSignature $target
        createdAt = $created.ToString('o')
        runId = $InputData.runId
        mode = $mode
        status = 'pending'
    }
    return @{ action = $mode; id = $key; reply = $InputData.reply; chatId = $chat.id }
}

function Reserve-Reply($Config, $State, $InputData, [datetimeoffset]$Now, [bool]$Approved = $false) {
    Assert-Lease $State $InputData.runId $Now
    $entry = $State.entries[$InputData.id]
    if (-not $entry -or $entry.status -ne 'pending') { throw 'Reply is missing or already handled.' }
    if ($entry.chatId -ne $InputData.chat.id -or $entry.messageId -ne $InputData.message.id -or
        $InputData.latestMessageId -ne $entry.messageId -or
        (Get-MessageHash $InputData.message) -ne $entry.messageHash) { throw 'Conversation or message changed.' }
    $target = Get-Eligibility $Config $State $InputData.chat $InputData.message $Now
    if ($null -eq $target) { throw 'Whitelist, freshness, or sender check failed.' }
    if (-not (Test-EntryPolicy $entry $target)) { throw 'Chat policy changed or no longer permits this reply.' }
    if (-not $Approved -and ($entry.runId -ne $InputData.runId -or $entry.mode -ne 'auto' -or
        $target.mode -ne 'auto' -or $entry.topic -notin $target.autoTopics)) {
        throw 'Explicit user approval is required.'
    }
    $last = $State.entries.Values | Where-Object {
        $_.chatId -eq $entry.chatId -and $_.reservedAt -and
        [datetimeoffset]$_.reservedAt -gt $Now.AddSeconds(-$Config.cooldownSeconds)
    }
    if ($last) { throw 'Chat cooldown is active.' }
    $entry.status = 'reserved'
    $entry.reservedAt = $Now.ToString('o')
    $entry.reservationId = [guid]::NewGuid().ToString()
    return @{
        action = 'send'
        id = $InputData.id
        reservationId = $entry.reservationId
        path = "/chats/$([uri]::EscapeDataString($entry.chatId))/messages"
        body = @{ body = @{ contentType = 'text'; content = $entry.reply } }
    }
}

function Complete-Reply($State, $InputData) {
    $entry = $State.entries[$InputData.id]
    if (-not $entry -or $entry.status -ne 'reserved' -or
        $entry.reservationId -ne $InputData.reservationId -or
        $InputData.result -notin @('sent', 'delivery-unknown')) { throw 'Invalid delivery receipt.' }
    $entry.status = $InputData.result
    return @{ status = $entry.status }
}

function Finish-Poll($State, $InputData, [datetimeoffset]$Now) {
    Assert-Lease $State $InputData.runId $Now
    foreach ($id in $InputData.completedChatIds) {
        if (-not $State.lease.targets.Contains($id)) { throw 'Cannot checkpoint an unplanned chat.' }
    }
    foreach ($id in $InputData.completedChatIds) { $State.checkpoints[$id] = $State.lease.through }
    $State.lease = $null
    return @{ action = 'finished' }
}

function Read-ProtectedState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return New-MonitorState }
    $secure = Get-Content -LiteralPath $Path -Raw | ConvertTo-SecureString
    return ([Net.NetworkCredential]::new('', $secure).Password | ConvertFrom-Json -AsHashtable)
}

function Write-ProtectedState([string]$Path, $State) {
    $plain = $State | ConvertTo-Json -Depth 40 -Compress
    $cipher = ConvertTo-SecureString $plain -AsPlainText -Force | ConvertFrom-SecureString
    [IO.File]::WriteAllText("$Path.tmp", $cipher)
    [IO.File]::Move("$Path.tmp", $Path, $true)
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $IsWindows) { throw 'Windows is required for DPAPI-protected local state.' }
if ($ConfigPath -eq (Join-Path $PSScriptRoot 'config.json') -and -not (Test-Path -LiteralPath $ConfigPath)) {
    [IO.File]::Copy((Join-Path $PSScriptRoot 'config.example.json'), $ConfigPath, $false)
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
Assert-Config $config
if ($Command -eq 'Status') { $config | ConvertTo-Json -Depth 20; return }
if ($Command -eq 'Begin' -and (-not $config.enabled -or ($config.people.Count -eq 0 -and $config.groupChats.Count -eq 0))) {
    @{ action = 'skip'; reason = 'disabled-or-empty-whitelist' } | ConvertTo-Json -Compress
    return
}
$dataDir = Join-Path $PSScriptRoot '.data'
$null = New-Item -ItemType Directory -Path $dataDir -Force
$lock = [IO.File]::Open((Join-Path $dataDir 'state.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Config $config
    $statePath = Join-Path $dataDir 'state.dpapi'
    $state = Read-ProtectedState $statePath
    $now = [datetimeoffset]::UtcNow
    $payload = $null
    if ($Command -in @('Plan', 'Check', 'Reserve', 'Complete', 'Finish')) {
        $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
        if (-not $payload) { throw 'Provide a JSON object on standard input.' }
    }
    $configChanged = $false
    $result = switch ($Command) {
        'Enable' { $config.enabled = $true; $configChanged = $true; @{ enabled = $true } }
        'Disable' { $config.enabled = $false; $configChanged = $true; @{ enabled = $false } }
        { $_ -in @('AllowPerson', 'AllowGroup', 'RemovePerson', 'RemoveGroup') } {
            if ([string]::IsNullOrWhiteSpace($TargetId)) { throw 'TargetId is required.' }
            $section = if ($Command.EndsWith('Person')) { 'people' } else { 'groupChats' }
            if ($Command.StartsWith('Remove')) {
                $config[$section].Remove($TargetId)
            } else {
                $addedAt = $now.ToString('o')
                if ($config[$section].Contains($TargetId)) { $addedAt = $config[$section][$TargetId].addedAt }
                $requestedMode = if ($PSBoundParameters.ContainsKey('Mode')) { $Mode } else { '' }
                $requestedTopics = $null
                if ($PSBoundParameters.ContainsKey('AutoTopics')) { $requestedTopics = @($AutoTopics) }
                $config[$section][$TargetId] = New-TargetRule $Policy $addedAt $requestedMode $requestedTopics
            }
            Assert-Config $config
            $configChanged = $true
            @{ updated = $section; id = $TargetId }
        }
        'Begin' { Start-Poll $config $state $now $ReconsiderSkipped.IsPresent }
        'Plan' { Get-PollPlan $config $state $payload $now }
        'Check' { Add-Candidate $config $state $payload $now }
        'Reserve' { Reserve-Reply $config $state $payload $now $Approved.IsPresent }
        'Complete' { Complete-Reply $state $payload }
        'Finish' { Finish-Poll $state $payload $now }
        'Drafts' {
            @{ drafts = @($state.entries.GetEnumerator() | Where-Object { $_.Value.status -eq 'pending' } |
                ForEach-Object { @{ id = $_.Key; entry = $_.Value } }) }
        }
        'Dismiss' {
            if (-not $state.entries.Contains($TargetId) -or $state.entries[$TargetId].status -ne 'pending') {
                throw 'Specify a pending draft ID.'
            }
            $state.entries[$TargetId].status = 'dismissed'
            @{ dismissed = $TargetId }
        }
    }
    if ($configChanged) {
        [IO.File]::WriteAllText("$ConfigPath.tmp", ($config | ConvertTo-Json -Depth 20))
        [IO.File]::Move("$ConfigPath.tmp", $ConfigPath, $true)
    }
    Write-ProtectedState $statePath $state
    $result | ConvertTo-Json -Depth 40 -Compress
} finally { $lock.Dispose() }
