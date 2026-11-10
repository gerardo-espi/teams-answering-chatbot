#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Monitor.ps1')
function Assert($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $threw = $false
    try { $null = & $Action } catch { $threw = $true }
    Assert $threw $Name
}
$now = [datetimeoffset]::UtcNow
$self = '00000000-0000-0000-0000-000000000001'
$person = '00000000-0000-0000-0000-000000000002'
$other = '00000000-0000-0000-0000-000000000003'
$config = @{
    enabled = $true; maxMessageAgeMinutes = 30; cooldownSeconds = 120
    people = @{}; groupChats = @{}
}
Assert-Config $config
$state = New-MonitorState
Assert ((Start-Poll $config $state $now).action -eq 'skip') 'empty whitelist is a no-op'
Assert (-not $state.lease) 'empty whitelist does not start a poll'
$config.people[$person] = @{
    mode = 'auto'; autoTopics = @('greeting', 'thanks'); addedAt = $now.AddMinutes(-10).ToString('o')
}
$dm = @{ id = 'dm'; chatType = 'oneOnOne'; members = @(@{ userId = $self }, @{ userId = $person }) }
$group = @{ id = 'group'; chatType = 'group'; members = $dm.members }
Assert ($null -eq (Get-TargetRule $config $group $self)) 'person permission never grants group access'
$begin = Start-Poll $config $state $now
Assert ($begin.metadata.Count -eq 1 -and $begin.metadata[0].targetId -eq $person -and
    [uri]::UnescapeDataString($begin.metadata[0].path).Contains(
        "chatType eq 'oneOnOne' and members/any(m:m/microsoft.graph.aadUserConversationMember/userId eq '$person')")) 'DM discovery filters by the exact whitelisted person and chat type'
Assert ((Start-Poll $config $state $now).action -eq 'skip') 'concurrent poll is rejected'
$inputData = @{ runId = $begin.runId; selfId = $self; chats = @($dm, $group) }
$plan = Get-PollPlan $config $state $inputData $now
Assert ($plan.chats.Count -eq 1 -and $plan.chats[0].chatId -eq 'dm') 'only whitelisted chat gets a message-read path'
Assert ($plan.chats[0].path -match 'orderby=lastModifiedDateTime' -and
    $plan.chats[0].path -match 'lastModifiedDateTime%20gt') 'message filter matches its ordering property'
Assert ($plan.chats[0].contextPath -eq
    '/chats/dm/messages?$top=10&$orderby=createdDateTime desc&$select=id,createdDateTime,from,body,messageType,lastEditedDateTime,deletedDateTime,attachments,mentions') 'authorized DM gets the latest 10 messages in one context query without the incremental filter'
Assert ($plan.chats[0].fallbackContextPath -eq
    '/chats/dm/messages?$top=3&$orderby=createdDateTime desc&$select=id,createdDateTime,from,body,messageType,lastEditedDateTime,deletedDateTime,attachments,mentions') 'authorized DM gets one latest-3 fallback query with all context safety fields'
$inputData.selfId = $other
Assert-Throws { Get-PollPlan $config $state $inputData $now } 'signed-in account cannot silently change'
$inputData.selfId = $self
$message = @{
    id = 'new-message'; messageType = 'message'; createdDateTime = $now.AddMinutes(-1).ToString('o')
    from = @{ user = @{ id = $person } }; body = @{ contentType = 'text'; content = 'Hey!' }
    attachments = @(); mentions = @()
}
$candidate = @{
    runId = $begin.runId; chat = $dm; message = $message
    classification = 'work'; topic = 'greeting'; reply = 'Hey!'
}
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'work classification cannot produce a reply'
$candidate.classification = 'casual'
$result = Add-Candidate $config $state $candidate $now
Assert ($result.action -eq 'auto') 'allowed person and automatic topic produces a candidate'
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'candidate deduplication prevents repeat preparation in the same poll'
$fresh = @{
    runId = $begin.runId; id = $result.id; chat = $dm; message = $message; latestMessageId = $message.id
}
$fresh.latestMessageId = 'newer-message'
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'conversation changes prevent stale replies'
$fresh.latestMessageId = $message.id
$message.body.content = 'Updated'
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'source message edits invalidate reply'
$message.body.content = 'Hey!'
$config.enabled = $false
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'disabled plugin cannot send'
$config.enabled = $true
$rule = $config.people[$person]
$config.people.Remove($person)
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'whitelist removal cancels prepared replies'
$config.people[$person] = $rule
$reservation = Reserve-Reply $config $state $fresh $now
Assert ($reservation.action -eq 'send' -and $state.entries[$result.id].status -eq 'reserved') 'send must first reserve a durable record'
Assert ($reservation.path -eq '/chats/dm/messages' -and $reservation.body.body.content -eq 'Hey!') 'reservation fixes destination and exact body'
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'reserved reply is never retried'
$receipt = @{ id = $result.id; reservationId = $reservation.reservationId; result = 'delivery-unknown' }
$null = Complete-Reply $state $receipt
Assert ($state.entries[$result.id].status -eq 'delivery-unknown') 'uncertain delivery is retained without retry'
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'uncertain delivery cannot be resent'
$config.groupChats.group = @{ mode = 'draft'; autoTopics = @(); addedAt = $now.AddMinutes(-5).ToString('o') }
$groupPlan = Get-PollPlan $config $state $inputData $now
Assert ($groupPlan.chats.Count -eq 2) 'group requires a separate whitelist entry'
$candidate.chat = $group
$message.id = 'group-message'
$message.from.user.id = $other
$groupDraft = Add-Candidate $config $state $candidate $now
Assert ($groupDraft.action -eq 'draft') 'allowed groups honor draft mode for any human sender'
$fresh.chat = $group; $fresh.id = $groupDraft.id; $fresh.latestMessageId = $message.id
Assert-Throws { Reserve-Reply $config $state $fresh $now } 'draft cannot auto-send'
$null = Reserve-Reply $config $state $fresh $now $true
Assert ($state.entries[$groupDraft.id].status -eq 'reserved') 'explicit approval may reserve a draft'
$candidate.chat = $dm; $message.from.user.id = $person; $message.id = 'future'
$message.createdDateTime = $now.AddSeconds(1).ToString('o')
Assert ((Add-Candidate $config $state $candidate $now.AddSeconds(2)).action -eq 'skip') 'arrivals after poll start wait for next poll'
$message.createdDateTime = $now.AddMinutes(-11).ToString('o')
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'messages predating consent are ignored'
$message.createdDateTime = $now.AddMinutes(-1).ToString('o')
$message.from.user.id = $self
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'never answers self'
$message.from.user.id = $person
$message.from.application = @{ id = 'bot' }
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'never answers application messages'
$message.from.Remove('application')
$message.lastEditedDateTime = $now.ToString('o')
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'never answers edited messages'
$message.Remove('lastEditedDateTime')
Assert-Throws { Reserve-Reply $config $state $fresh $now.AddMinutes(5) $true } 'expired leases cannot send'
$null = Finish-Poll $state @{ runId = $begin.runId; completedChatIds = @('dm') } $now
Assert ($state.checkpoints.Contains('dm') -and -not $state.checkpoints.Contains('group')) 'only completed reads advance their checkpoint'
$new = Start-Poll $config $state $now.AddMinutes(5)
Assert ($new.metadata.Count -eq 2 -and
    @($new.metadata | Where-Object { $_.kind -eq 'group' })[0].path -eq
    '/chats/group?$select=id,chatType') 'group discovery fetches only the exact whitelisted group'
$discoveryConfig = @{
    enabled = $true; maxMessageAgeMinutes = 30; cooldownSeconds = 120
    people = @{}; groupChats = @{
        '19:group@thread.v2' = @{ mode = 'draft'; autoTopics = @(); addedAt = $now.ToString('o') }
    }
}
$groupOnly = Start-Poll $discoveryConfig (New-MonitorState) $now
Assert ($groupOnly.metadata.Count -eq 1 -and
    $groupOnly.metadata[0].path -eq '/chats/19%3Agroup%40thread.v2?$select=id,chatType') 'group-only polling encodes exact IDs without listing chats'
$contextState = New-MonitorState
$contextBegin = Start-Poll $discoveryConfig $contextState $now
$contextPlan = Get-PollPlan $discoveryConfig $contextState @{
    runId = $contextBegin.runId; selfId = $self
    chats = @(@{ id = '19:group@thread.v2'; chatType = 'group' }, $dm)
} $now
Assert ($contextPlan.chats.Count -eq 1 -and $contextPlan.chats[0].contextPath.StartsWith(
    '/chats/19%3Agroup%40thread.v2/messages?') -and
    $contextPlan.chats[0].fallbackContextPath -eq (
        $contextPlan.chats[0].contextPath.Replace('$top=10', '$top=3'))) 'primary and fallback context stay scoped to the encoded authorized group, never an unwhitelisted DM'
$discoveryConfig.enabled = $false
Assert (-not (Start-Poll $discoveryConfig (New-MonitorState) $now).Contains('metadata')) 'disabled polling exposes no discovery requests'
$inputData.runId = $new.runId
$next = Get-PollPlan $config $state $inputData $now.AddMinutes(5)
Assert ([datetimeoffset]$next.chats[0].since -eq $now) 'next poll resumes from previous checkpoint'
$candidate.runId = $new.runId
$message.createdDateTime = $now.AddMinutes(-1).ToString('o')
$message.id = 'context-only-message'
Assert ((Add-Candidate $config $state $candidate $now.AddMinutes(5)).reason -eq
    'outside-poll-window') 'older context does not become a reply target after a checkpoint'
$retryConfig = @{
    enabled = $true; maxMessageAgeMinutes = 30; cooldownSeconds = 120
    people = @{ $person = @{ mode = 'auto'; autoTopics = @('greeting'); addedAt = $now.AddMinutes(-10).ToString('o') } }
    groupChats = @{}
}
$retryState = New-MonitorState
$retryBegin = Start-Poll $retryConfig $retryState $now
$retryInput = @{ runId = $retryBegin.runId; selfId = $self; chats = @($dm) }
$null = Get-PollPlan $retryConfig $retryState $retryInput $now
$retryMessage = @{
    id = 'unsent'; messageType = 'message'; createdDateTime = $now.AddMinutes(-1).ToString('o')
    from = @{ user = @{ id = $person } }; body = @{ contentType = 'text'; content = 'Hey!' }
    attachments = @(); mentions = @()
}
$retryCandidate = @{
    runId = $retryBegin.runId; chat = $dm; message = $retryMessage
    classification = 'casual'; topic = 'greeting'; reply = 'Hello!'
}
$pending = Add-Candidate $retryConfig $retryState $retryCandidate $now
$null = Finish-Poll $retryState @{ runId = $retryBegin.runId; completedChatIds = @('dm') } $now
$retryNow = $now.AddMinutes(1)
$retryBegin = Start-Poll $retryConfig $retryState $retryNow
$retryInput.runId = $retryBegin.runId
$retryCandidate.runId = $retryBegin.runId
$retryPlan = Get-PollPlan $retryConfig $retryState $retryInput $retryNow
Assert ([datetimeoffset]$retryPlan.chats[0].since -lt [datetimeoffset]$retryMessage.createdDateTime) 'unreserved pending auto reply is discovered despite an advanced checkpoint'
$pendingEntry = $retryState.entries[$pending.id]
foreach ($status in @('reserved', 'sent', 'delivery-unknown', 'dismissed')) {
    $pendingEntry.status = $status
    Assert ((Add-Candidate $retryConfig $retryState $retryCandidate $retryNow).reason -eq
        'already-handled') "$status reply is never reopened as pending"
}
$pendingEntry.status = 'pending'
$pendingEntry.reservationId = 'previous-reservation'
Assert ((Add-Candidate $retryConfig $retryState $retryCandidate $retryNow).action -eq
    'skip') 'a pending record with reservation evidence cannot resume'
$pendingEntry.Remove('reservationId')
$retryMessage.body.content = 'Changed'
Assert ((Add-Candidate $retryConfig $retryState $retryCandidate $retryNow).action -eq
    'skip') 'changed source cannot resume a pending reply'
$retryMessage.body.content = 'Hey!'
$retryRule = $retryConfig.people[$person]
foreach ($blocked in @('draft-entry', 'draft-target', 'removed-topic', 'new-consent')) {
    switch ($blocked) {
        'draft-entry' { $pendingEntry.mode = 'draft' }
        'draft-target' { $retryRule.mode = 'draft' }
        'removed-topic' { $retryRule.autoTopics = @() }
        'new-consent' { $retryRule.addedAt = $now.ToString('o') }
    }
    $blockedPlan = Get-PollPlan $retryConfig $retryState $retryInput $retryNow
    Assert ([datetimeoffset]$blockedPlan.chats[0].since -eq $now) "$blocked does not reopen a checkpoint for automatic retry"
    $retryState.lease.targets.dm = $retryPlan.chats[0].since
    Assert ((Add-Candidate $retryConfig $retryState $retryCandidate $retryNow).action -eq
        'skip') "$blocked cannot resume automatic sending"
    $pendingEntry.mode = 'auto'; $retryRule.mode = 'auto'; $retryRule.autoTopics = @('greeting')
    $retryRule.addedAt = $now.AddMinutes(-10).ToString('o')
}
$retryCandidate.reply = 'A different proposed reply'
$resumed = Add-Candidate $retryConfig $retryState $retryCandidate $retryNow
Assert ($resumed.action -eq 'auto' -and $resumed.id -eq $pending.id -and
    $resumed.reply -eq 'Hello!' -and $pendingEntry.runId -eq $retryBegin.runId) 'next poll resumes the same unsent reply under its fresh lease'
$retryFresh = @{
    runId = $retryBegin.runId; id = $pending.id; chat = $dm
    message = $retryMessage; latestMessageId = 'newer-message'
}
Assert-Throws { Reserve-Reply $retryConfig $retryState $retryFresh $retryNow } 'resumed pending reply still requires the source to be newest'
$retryFresh.latestMessageId = $retryMessage.id
$retryReservation = Reserve-Reply $retryConfig $retryState $retryFresh $retryNow
Assert ($retryReservation.action -eq 'send' -and
    $retryReservation.body.body.content -eq 'Hello!') 'resumed pending reply can reserve exactly its saved body after fresh checks'
Assert-Throws { Reserve-Reply $retryConfig $retryState $retryFresh $retryNow } 'resumed reply cannot reserve twice'
$null = Finish-Poll $retryState @{ runId = $retryBegin.runId; completedChatIds = @('dm') } $retryNow
$pendingEntry.status = 'pending'
$pendingEntry.Remove('reservedAt'); $pendingEntry.Remove('reservationId')
$expiredNow = $now.AddMinutes(31)
$expiredBegin = Start-Poll $retryConfig $retryState $expiredNow
$retryInput.runId = $expiredBegin.runId
$retryCandidate.runId = $expiredBegin.runId
$expiredPlan = Get-PollPlan $retryConfig $retryState $retryInput $expiredNow
Assert ([datetimeoffset]$expiredPlan.chats[0].since -ge $expiredNow.AddMinutes(-30) -and
    (Add-Candidate $retryConfig $retryState $retryCandidate $expiredNow).action -eq 'skip') 'pending retries cannot bypass message expiry'
$policyCases = @(
    @('casualRelaxed', 'casual', 'social', 'Nice!', 'auto'),
    @('casualCautious', 'casual', 'greeting', 'Hey!', 'auto'),
    @('casualCautious', 'casual', 'social', 'Nice!', 'draft'),
    @('mixedSelective', 'casual', 'social', 'Nice!', 'auto'),
    @('mixedSelective', 'work', 'work', 'Which version is affected?', 'draft'),
    @('mixedSelective', 'mixed', 'work', 'Which version is affected?', 'draft'),
    @('workAcknowledgment', 'work', 'acknowledgment', 'Thanks for the update.', 'auto'),
    @('workAcknowledgment', 'work', 'work', 'I will fix it.', 'skip'),
    @('workAcknowledgment', 'work', 'acknowledgment', 'I will fix it.', 'skip'),
    @('workAcknowledgment', 'casual', 'social', 'Nice!', 'skip'),
    @('workDraft', 'work', 'work', 'Which version is affected?', 'draft'),
    @('workDraft', 'casual', 'greeting', 'Hey!', 'skip'),
    @('draftAll', 'casual', 'social', 'Nice!', 'draft'),
    @('draftAll', 'mixed', 'work', 'Which version is affected?', 'draft'),
    @('monitorOnly', 'casual', 'greeting', 'Hey!', 'skip')
)
foreach ($case in $policyCases) {
    $policyConfig = @{
        enabled = $true; maxMessageAgeMinutes = 30; cooldownSeconds = 120; groupChats = @{}
        people = @{ $person = (New-TargetRule $case[0] $now.AddMinutes(-10).ToString('o')) }
    }
    Assert-Config $policyConfig
    $policyState = New-MonitorState
    $policyBegin = Start-Poll $policyConfig $policyState $now
    $policyPlan = Get-PollPlan $policyConfig $policyState @{
        runId = $policyBegin.runId; selfId = $self; chats = @($dm)
    } $now
    $policyMessage = @{
        id = 'policy-message'; messageType = 'message'; createdDateTime = $now.AddMinutes(-1).ToString('o')
        from = @{ user = @{ id = $person } }; body = @{ contentType = 'text'; content = 'An incoming message' }
        attachments = @(); mentions = @()
    }
    $policyCandidate = @{
        runId = $policyBegin.runId; chat = $dm; message = $policyMessage
        classification = $case[1]; topic = $case[2]; reply = $case[3]
    }
    $policyResult = Add-Candidate $policyConfig $policyState $policyCandidate $now
    Assert ($policyResult.action -eq $case[4]) "$($case[0]) routes $($case[1])/$($case[2]) to $($case[4])"
    if ($case[4] -eq 'skip') {
        Assert ($policyState.entries.Count -eq 0) "$($case[0]) does not save excluded content as a draft"
        continue
    }
    $policyFresh = @{
        runId = $policyBegin.runId; id = $policyResult.id; chat = $dm
        message = $policyMessage; latestMessageId = $policyMessage.id
    }
    if ($case[4] -eq 'draft') {
        Assert-Throws { Reserve-Reply $policyConfig $policyState $policyFresh $now } "$($case[0]) requires approval for this draft"
        $null = Reserve-Reply $policyConfig $policyState $policyFresh $now $true
    } else {
        $null = Reserve-Reply $policyConfig $policyState $policyFresh $now
    }
    Assert ($policyState.entries[$policyResult.id].status -eq 'reserved') "$($case[0]) permits reservation only through its configured route"
}
Assert-Throws { New-TargetRule '' $now.ToString('o') } 'whitelisting cannot silently choose a policy'
Assert-Throws { New-TargetRule 'unknown' $now.ToString('o') } 'unknown policy is rejected'
Assert-Throws { New-TargetRule 'workDraft' $now.ToString('o') 'auto' } 'mode override cannot broaden draft-only policy'
Assert-Throws { New-TargetRule 'casualCautious' $now.ToString('o') '' @('social') } 'topic override cannot broaden cautious automatic replies'
$narrowed = Get-EffectiveRule (New-TargetRule 'casualRelaxed' $now.ToString('o') 'draft' @())
Assert ($narrowed.mode -eq 'draft' -and $narrowed.autoTopics.Count -eq 0) 'explicit draft and empty topics narrow a preset'
$policyConfig.people[$person] = New-TargetRule 'disabled' $now.AddMinutes(-10).ToString('o')
Assert ((Start-Poll $policyConfig (New-MonitorState) $now).action -eq 'skip') 'all disabled targets cause no metadata reads'
$policyConfig.groupChats.group = New-TargetRule 'monitorOnly' $now.AddMinutes(-10).ToString('o')
$disabledState = New-MonitorState
$disabledBegin = Start-Poll $policyConfig $disabledState $now
$disabledPlan = Get-PollPlan $policyConfig $disabledState @{
    runId = $disabledBegin.runId; selfId = $self; chats = @($dm, $group)
} $now
Assert ($disabledBegin.metadata.Count -eq 1 -and $disabledBegin.metadata[0].kind -eq 'group' -and
    $disabledPlan.chats.Count -eq 1 -and $disabledPlan.chats[0].rule.policy -eq 'monitorOnly') 'disabled DM is excluded while monitor-only group remains readable'
$policyConfig.people[$person] = New-TargetRule 'casualRelaxed' $now.AddMinutes(-10).ToString('o')
$policyState = New-MonitorState
$policyBegin = Start-Poll $policyConfig $policyState $now
$null = Get-PollPlan $policyConfig $policyState @{
    runId = $policyBegin.runId; selfId = $self; chats = @($dm)
} $now
$policyCandidate.runId = $policyBegin.runId
$policyCandidate.classification = 'casual'; $policyCandidate.topic = 'greeting'; $policyCandidate.reply = 'Hey!'
$policyResult = Add-Candidate $policyConfig $policyState $policyCandidate $now
$policyFresh.runId = $policyBegin.runId; $policyFresh.id = $policyResult.id
foreach ($changedPolicy in @('casualCautious', 'workDraft', 'monitorOnly', 'disabled')) {
    $policyConfig.people[$person] = New-TargetRule $changedPolicy $now.AddMinutes(-10).ToString('o')
    Assert-Throws { Reserve-Reply $policyConfig $policyState $policyFresh $now $true } "$changedPolicy blocks an old pending reply even with approval"
    Assert (-not (Test-ResumableReply $policyState.entries[$policyResult.id] (Get-EffectiveRule $policyConfig.people[$person]))) "$changedPolicy cannot reopen an automatic reply from a different policy"
}
$policyConfig.people[$person].policy = 'unknown'
Assert-Throws { Assert-Config $policyConfig } 'invalid persisted policies fail closed'
$config.people[$person].autoTopics = @('project')
Assert-Throws { Assert-Config $config } 'unknown automatic topics fail closed'
$freshRoot = Join-Path ([IO.Path]::GetTempPath()) "teams-plugin-install-$([guid]::NewGuid())"
try {
    $null = New-Item -ItemType Directory -Path $freshRoot
    foreach ($name in @('Monitor.ps1', 'config.example.json')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $freshRoot
    }
    $freshMonitor = Join-Path $freshRoot 'Monitor.ps1'
    $initial = & pwsh -NoProfile -File $freshMonitor -Command Status | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and -not $initial.enabled -and
        $initial.people.Count -eq 0 -and $initial.groupChats.Count -eq 0) 'fresh install creates a disabled empty local configuration'
    $idle = & pwsh -NoProfile -File $freshMonitor -Command Begin | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and $idle.action -eq 'skip' -and
        -not (Test-Path -LiteralPath (Join-Path $freshRoot '.data'))) 'fresh install polling skips without creating a ledger'
    $initial.enabled = $true
    $initial.people[$person] = @{
        mode = 'draft'; autoTopics = @(); addedAt = $now.ToString('o')
    }
    $freshConfig = Join-Path $freshRoot 'config.json'
    [IO.File]::WriteAllText($freshConfig, ($initial | ConvertTo-Json -Depth 20))
    $preserved = & pwsh -NoProfile -File $freshMonitor -Command Status | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and $preserved.enabled -and
        $preserved.people[$person].mode -eq 'draft') 'existing local settings are not replaced by installation defaults'
    $beforeAllow = Get-Content -LiteralPath $freshConfig -Raw
    $null = & pwsh -NoProfile -File $freshMonitor -Command AllowPerson -TargetId $person 2>$null
    Assert ($LASTEXITCODE -ne 0 -and (Get-Content -LiteralPath $freshConfig -Raw) -ceq $beforeAllow) 'AllowPerson without a policy leaves the whitelist unchanged'
    $null = & pwsh -NoProfile -File $freshMonitor -Command AllowGroup -TargetId 'test-group' 2>$null
    Assert ($LASTEXITCODE -ne 0 -and (Get-Content -LiteralPath $freshConfig -Raw) -ceq $beforeAllow) 'AllowGroup without a policy leaves the whitelist unchanged'
    $null = & pwsh -NoProfile -File $freshMonitor -Command AllowPerson -TargetId $person -Policy casualRelaxed
    $null = & pwsh -NoProfile -File $freshMonitor -Command AllowGroup -TargetId 'test-group' -Policy workDraft
    $assigned = & pwsh -NoProfile -File $freshMonitor -Command Status | ConvertFrom-Json -AsHashtable
    Assert ($assigned.people[$person].policy -eq 'casualRelaxed' -and
        [datetimeoffset]$assigned.people[$person].addedAt -eq [datetimeoffset]$initial.people[$person].addedAt -and
        $assigned.groupChats['test-group'].policy -eq 'workDraft' -and
        $assigned.groupChats['test-group'].mode -eq 'draft') 'allow commands persist explicit policies and preserve existing consent'
} finally {
    $freshData = Join-Path $freshRoot '.data'
    foreach ($name in @('state.lock', 'state.dpapi', 'state.dpapi.tmp')) {
        $path = Join-Path $freshData $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    if (Test-Path -LiteralPath $freshData) { Remove-Item -LiteralPath $freshData }
    foreach ($name in @('Monitor.ps1', 'config.example.json', 'config.json')) {
        $path = Join-Path $freshRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    if (Test-Path -LiteralPath $freshRoot) { Remove-Item -LiteralPath $freshRoot }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "teams-plugin-test-$([guid]::NewGuid()).dpapi"
try {
    Write-ProtectedState $temp $state
    $loaded = Read-ProtectedState $temp
    Assert ($loaded.accountId -eq $self -and $loaded.entries[$result.id].status -eq 'delivery-unknown') 'delivery ledger survives encrypted reload'
    Assert ((Get-Content $temp -Raw) -notmatch 'Hey!') 'stored replies are not plaintext'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    if (Test-Path -LiteralPath "$temp.tmp") { Remove-Item -LiteralPath "$temp.tmp" }
}
$errors = @()
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    $errors += $parseErrors
}
Assert ($errors.Count -eq 0) 'PowerShell sources parse'
$commands = @('teams-allow-person', 'teams-allow-group', 'teams-remove-person',
    'teams-remove-group', 'teams-whitelist', 'teams-on', 'teams-off', 'teams-status',
    'teams-drafts', 'teams-help')
$manifest = Get-Content -LiteralPath (Join-Path $root '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json
$skillsRoot = Join-Path $root $manifest.skills
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
foreach ($name in $commands) {
    $skillPath = Join-Path (Join-Path $skillsRoot $name) 'SKILL.md'
    Assert (Test-Path -LiteralPath $skillPath) "$name is discoverable in the manifest skills directory"
    $skill = Get-Content -LiteralPath $skillPath -Raw
    Assert ($skill -match "(?m)^name: $([regex]::Escape($name))`r?$" -and
        $skill -match '(?m)^description: .+') "$name has command metadata"
    if ($name -ne 'teams-help') {
        Assert ($skill.Contains('..\teams-auto-reply\SKILL.md')) "$name loads the shared safety rules"
    }
    Assert ($readme.Contains("| ``$name`` |")) "$name is documented"
}
Write-Host 'All plugin checks passed. No Teams or Copilot calls were made.'
