<#
.SYNOPSIS
    Grants the alerting app Mail.Send in Exchange Online, scoped to the sender
    mailboxes (RBAC for Applications, one scope covering every cluster's sender), and
    proves the scope holds.

.DESCRIPTION
    The part of infra/product-a/alerting that OpenTofu cannot express: no provider and no
    Graph API manage Exchange Online RBAC. Every input is the stack's: in the stack
    folder, `tofu output -raw exchange_sender_scope_command` prints the complete
    invocation. Whoever runs it needs neither tofu nor read access to the state, which
    holds every cluster's Graph client secret and Teams trigger URL. Hand them this file
    and that line.

      -AppId                     -> New-ServicePrincipal -AppId
      -ServicePrincipalObjectId  -> New-ServicePrincipal -ObjectId, -App, -Identity
      -DisplayName               -> names of the pointer, the scope, the assignment
      -SenderMailbox             -> the scope's recipient filter (one or more mailboxes)

    Idempotent: creates what is missing, corrects a scope or assignment that drifted,
    changes nothing that is already right. Re-run it whenever the SET of senders
    changes, i.e. a cluster entry in the stack introduces a mailbox no other cluster
    uses (apply first, then take the line from the output again). Exchange stores a
    normalised form of the filter, so the drift check compares both sides without
    parentheses and surplus whitespace.

    Refuses to run while the service principal holds ANY Entra app-role assignment.
    Entra-granted permissions are additive with Exchange RBAC: an Entra Mail.Send
    (for example from a portal "Grant admin consent") lets the app send as every
    mailbox regardless of this scope, and Test-ServicePrincipalAuthorization does not
    see Entra grants. That check is what keeps this setup fail-closed.

    Ends by asserting, with Test-ServicePrincipalAuthorization:
      - the app's only Exchange grant is "Application Mail.Send" on this scope;
      - every sender is in scope;
      - another real mailbox is not.

    Requirements, for whoever runs it
      - Exchange Administrator (Entra) or Organization Management (Exchange).
      - Windows PowerShell 5.1 or PowerShell 7, with module ExchangeOnlineManagement 3.x
        (Install-Module ExchangeOnlineManagement -Scope CurrentUser).
      - Azure CLI signed in to the organisation's tenant, for the Entra check only:
        `az login --allow-no-subscriptions`. No subscription or state access.
      - A copy received by mail, Teams or browser download is marked as from the
        internet, and RemoteSigned refuses to run it unsigned: Unblock-File it first.

    Exchange caches app permissions for 30 minutes to 2 hours. The test cmdlet
    bypasses that cache; real sendMail calls may get 403 until it expires.

.PARAMETER AppId
    Client (application) ID of the app registration.

.PARAMETER ServicePrincipalObjectId
    Object ID of the app's service principal (Enterprise application), NOT of the app
    registration.

.PARAMETER DisplayName
    Display name of the app registration. Also names the Exchange pointer, scope and
    assignment.

.PARAMETER SenderMailbox
    The mailboxes the app may send as: every distinct clusters[*].sender of the stack.
    One or more, comma-separated on the command line ('a@x','b@x').

.PARAMETER OutOfScopeMailbox
    A real mailbox the app must NOT be able to send as (the negative test). Defaults to
    the mailbox of the signed-in `az` user; an admin account without a mailbox, or one
    whose mailbox is itself a sender, must pass one.

.EXAMPLE
    tofu output -raw exchange_sender_scope_command

    STEP 1 of 2 -- anyone who can read the state, in the infra/product-a/alerting folder.
    Prints the complete command for step 2, with this stack's values filled in (the
    values below are illustrative; always use the printed line):

      ./Set-AlertingSenderScope.ps1 -AppId '55555555-5555-5555-5555-555555555555' -DisplayName 'platform-alerting' -SenderMailbox 'alerts@example.com' -ServicePrincipalObjectId '66666666-6666-6666-6666-666666666666'

    Send that one line and this file to the Exchange administrator. Nothing in the line
    is secret; the state itself is, and they do not need it.

.EXAMPLE
    Unblock-File .\Set-AlertingSenderScope.ps1
    az login --allow-no-subscriptions
    ./Set-AlertingSenderScope.ps1 -AppId '55555555-5555-5555-5555-555555555555' -DisplayName 'platform-alerting' -SenderMailbox 'alerts@example.com' -ServicePrincipalObjectId '66666666-6666-6666-6666-666666666666' -WhatIf
    ./Set-AlertingSenderScope.ps1 -AppId '55555555-5555-5555-5555-555555555555' -DisplayName 'platform-alerting' -SenderMailbox 'alerts@example.com' -ServicePrincipalObjectId '66666666-6666-6666-6666-666666666666'

    STEP 2 of 2 -- the Exchange administrator, in the folder this file was saved to, in
    this order:

      1. Unblock-File            once per downloaded copy; otherwise RemoteSigned refuses it.
      2. az login                Azure CLI into the organisation's tenant, for the Entra check.
                                 No subscription needed.
      3. the line + " -WhatIf"   dry run: paste the printed line, append -WhatIf. It
                                 signs in to Exchange Online (browser prompt), checks
                                 the Entra grants and lists what it WOULD create or
                                 change. Nothing is written.
      4. the line as printed     the real run. Creates or corrects the pointer, scope
                                 and assignment, then proves the scope and ends with
                                 "OK: platform-alerting may send as ... and not as ...".

    Steps 3 and 4 are the same line; -WhatIf is the only difference. The real run is
    idempotent: running it again changes nothing and ends with the same "OK".

.EXAMPLE
    ./Set-AlertingSenderScope.ps1 -AppId '55555555-5555-5555-5555-555555555555' -DisplayName 'platform-alerting' -SenderMailbox 'alerts@example.com' -ServicePrincipalObjectId '66666666-6666-6666-6666-666666666666' -OutOfScopeMailbox 'approver@example.com'

    The administrator's own account has no mailbox (a dedicated admin account). The
    negative test needs a real mailbox that is none of the senders to prove the app CANNOT
    send as it: append -OutOfScopeMailbox to the printed line. Without it the script
    stops with "Pass -OutOfScopeMailbox ...".

.EXAMPLE
    tofu apply
    tofu output -raw exchange_sender_scope_command

    A cluster entry in variables.tf introduced a sender no other cluster uses (or the
    last cluster using one was removed). Apply first, so the state and the app
    description carry the new set, THEN take the printed line again (its
    -SenderMailbox now lists every current sender) and repeat step 2. The run re-points
    the existing scope to that set; nothing has to be removed by hand. A new cluster
    that reuses an existing sender needs no run at all.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AppId,
    [Parameter(Mandatory)] [string] $ServicePrincipalObjectId,
    [Parameter(Mandatory)] [string] $DisplayName,
    [Parameter(Mandatory)] [string[]] $SenderMailbox,
    [string] $OutOfScopeMailbox
)

$ErrorActionPreference = 'Stop'
$roleName       = 'Application Mail.Send'
$scopeName      = "$DisplayName sender"
$assignmentName = "$DisplayName Mail.Send"
# Sorted and de-duplicated, so the filter text is the same whatever order the senders
# arrive in. One clause per mailbox, OR-ed.
$senders = @($SenderMailbox | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
if ($senders.Count -eq 0) { throw "-SenderMailbox holds no mailbox." }
$filter  = ($senders | ForEach-Object { "(PrimarySmtpAddress -eq '$_')" }) -join ' -or '

# Exchange re-serialises a stored filter (parentheses, spacing), so compare both sides
# in a normalised form or every run would rewrite a scope that is already right.
function Get-NormalizedFilter([string] $Text) {
    (($Text -replace '[()]', '') -replace '\s+', ' ').Trim().ToLowerInvariant()
}

if (-not $OutOfScopeMailbox) {
    $OutOfScopeMailbox = (& az ad signed-in-user show --query mail -o tsv).Trim()
}
if (-not $OutOfScopeMailbox -or $senders -contains $OutOfScopeMailbox.ToLowerInvariant()) {
    throw "Pass -OutOfScopeMailbox: a real mailbox that is none of $($senders -join ', '), for the negative test."
}

Write-Host "App            $DisplayName (client id $AppId, service principal $ServicePrincipalObjectId)"
Write-Host "Sender scope   $filter"

# ---- fail closed: no Entra application permissions on this app ------------------------
$raw = & az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$ServicePrincipalObjectId/appRoleAssignments" --query "value[].{resource:resourceDisplayName, appRoleId:appRoleId}" -o json | Out-String
if ($LASTEXITCODE -ne 0) { throw "Could not read the service principal's Entra app-role assignments (az rest)." }
$entraGrants = @($raw | ConvertFrom-Json | ForEach-Object { $_ })   # 5.1 emits a JSON array as ONE object; enumerate it
if ($entraGrants.Count -gt 0) {
    $list = ($entraGrants | ForEach-Object { "$($_.resource) $($_.appRoleId)" }) -join '; '
    throw "Service principal $ServicePrincipalObjectId holds Entra app-role assignments ($list). Entra grants are unscoped and add to Exchange RBAC, so the sender scope would mean nothing. Revoke them (Enterprise applications -> $DisplayName -> Permissions) and re-run."
}
Write-Host "Entra grants   none (required)"

# ---- Exchange Online ------------------------------------------------------------------
if (-not (Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
    throw "Module ExchangeOnlineManagement 3.x is not installed: Install-Module ExchangeOnlineManagement -Scope CurrentUser"
}

# Only an Exchange Online connection made without -Prefix provides the cmdlets below under
# these names; a Security & Compliance connection (IsEopSession) provides none of them.
function Get-ExoConnection {
    @(Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' -and -not $_.IsEopSession -and -not $_.ModulePrefix })
}
$exo = Get-ExoConnection
if (-not $exo) {
    Connect-ExchangeOnline -ShowBanner:$false
    $exo = Get-ExoConnection
    if (-not $exo) { throw "Connect-ExchangeOnline returned without an Exchange Online connection." }
}

# Exchange loads only the cmdlets the signed-in account's roles allow, fixed at connect
# time. A cmdlet this script calls that does not resolve is therefore a missing role, not
# a missing module; every Exchange cmdlet here is in the Role Management role.
$missing = @($MyInvocation.MyCommand.ScriptBlock.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique |
    Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    throw "Exchange Online session of $($exo[0].UserPrincipalName) lacks $($missing -join ', '): that account does not hold the Role Management role. It needs Exchange Administrator (Entra; activate it first if PIM-eligible) or Organization Management (Exchange). Then Disconnect-ExchangeOnline -Confirm:`$false and re-run, so the session reloads its cmdlets."
}

# 1. Exchange's pointer to the Entra service principal (Enterprise application IDs,
#    not the app registration's object ID).
$pointer = Get-ServicePrincipal | Where-Object { $_.AppId -eq $AppId }
if (-not $pointer) {
    if ($PSCmdlet.ShouldProcess($DisplayName, 'New-ServicePrincipal')) {
        New-ServicePrincipal -AppId $AppId -ObjectId $ServicePrincipalObjectId -DisplayName $DisplayName | Out-Null
    }
} elseif ($pointer.ObjectId -ne $ServicePrincipalObjectId) {
    throw "Exchange has a service principal for app $AppId with object id $($pointer.ObjectId), but the stack's is $ServicePrincipalObjectId. The app was recreated: Remove-ServicePrincipal -Identity $($pointer.ObjectId), then re-run."
}

# 2. The scope: exactly the sender mailbox.
$scope = Get-ManagementScope | Where-Object { $_.Name -eq $scopeName }
if (-not $scope) {
    if ($PSCmdlet.ShouldProcess($scopeName, "New-ManagementScope ($filter)")) {
        New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $filter | Out-Null
    }
} elseif ((Get-NormalizedFilter $scope.RecipientFilter) -ne (Get-NormalizedFilter $filter)) {
    if ($PSCmdlet.ShouldProcess($scopeName, "Set-ManagementScope ($($scope.RecipientFilter) -> $filter)")) {
        Set-ManagementScope -Identity $scopeName -RecipientRestrictionFilter $filter
    }
}

# 3. The grant: Application Mail.Send, on that scope only.
$assignment = Get-ManagementRoleAssignment -Role $roleName | Where-Object { $_.Name -eq $assignmentName }
if (-not $assignment) {
    if ($PSCmdlet.ShouldProcess($assignmentName, "New-ManagementRoleAssignment ($roleName on '$scopeName')")) {
        New-ManagementRoleAssignment -Name $assignmentName -App $ServicePrincipalObjectId -Role $roleName -CustomResourceScope $scopeName | Out-Null
    }
} elseif ($assignment.CustomResourceScope -ne $scopeName) {
    if ($PSCmdlet.ShouldProcess($assignmentName, "Set-ManagementRoleAssignment -CustomResourceScope '$scopeName'")) {
        Set-ManagementRoleAssignment -Identity $assignmentName -CustomResourceScope $scopeName
    }
}

if ($WhatIfPreference) { return }

# ---- prove it -------------------------------------------------------------------------
$asSender = @()
foreach ($m in $senders) {
    $rows = @(Test-ServicePrincipalAuthorization -Identity $ServicePrincipalObjectId -Resource $m)
    $rows | ForEach-Object { $_ | Add-Member -NotePropertyName Sender -NotePropertyValue $m -PassThru }
    $asSender += $rows
}
$asOther  = @(Test-ServicePrincipalAuthorization -Identity $ServicePrincipalObjectId -Resource $OutOfScopeMailbox)
$asSender | Format-Table Sender, RoleName, GrantedPermissions, AllowedResourceScope, InScope -AutoSize | Out-String | Write-Host

$unexpected = @($asSender | Where-Object { $_.RoleName -ne $roleName -or $_.AllowedResourceScope -ne $scopeName })
if ($unexpected.Count -gt 0) {
    throw "The app holds Exchange grants other than '$roleName' on '$scopeName': $(($unexpected | ForEach-Object { "$($_.RoleName) on $($_.AllowedResourceScope)" }) -join '; '). Remove them; this app needs nothing else."
}
$notInScope = @($senders | Where-Object { $m = $_; -not ($asSender | Where-Object { $_.Sender -eq $m -and $_.InScope -eq $true }) })
if ($notInScope.Count -gt 0) {
    throw "$($notInScope -join ', ') NOT in scope for '$roleName'. Check the scope filter and that each mailbox exists."
}
if ($asOther | Where-Object { $_.InScope -eq $true }) {
    throw "$OutOfScopeMailbox IS in scope: the app can send as more than $($senders -join ', '). Fix the scope before enabling any cluster."
}

Write-Host "OK: $DisplayName may send as $($senders -join ', ') and not as $OutOfScopeMailbox."
Write-Host "Exchange caches app permissions for 30 min to 2 h; sendMail may answer 403 until then."
