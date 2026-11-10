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
Assert ((Add-Candidate $config $state $candidate $now).action -eq 'skip') 'candidate deduplication survives repeated polls'
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
$discoveryConfig.enabled = $false
Assert (-not (Start-Poll $discoveryConfig (New-MonitorState) $now).Contains('metadata')) 'disabled polling exposes no discovery requests'
$inputData.runId = $new.runId
$next = Get-PollPlan $config $state $inputData $now.AddMinutes(5)
Assert ([datetimeoffset]$next.chats[0].since -eq $now) 'next poll resumes from previous checkpoint'
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
} finally {
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
