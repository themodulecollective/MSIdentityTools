#requires -Version 7.0

# msExchRecipientTypeDetails for RemoteUserMailbox: the only Exchange state the merge expects to find or create.
$script:RemoteUserMailboxType = [long]2147483648


function ConvertTo-ConsistencyGuid {
    <#
    .SYNOPSIS
        Returns an AD user's mS-DS-ConsistencyGuid as a [guid], or $null when it is missing or not 16 bytes.
    .EXAMPLE
        ConvertTo-ConsistencyGuid -User (Get-ADUser -Identity 'jdoe' -Properties 'mS-DS-ConsistencyGuid')
    #>
    [CmdletBinding()]
    [OutputType([guid])]
    param(
        # An AD user read with the mS-DS-ConsistencyGuid property, or $null.
        [AllowNull()]
        [psobject]$User
    )

    if ($null -ne $User) {
        $bytes = [byte[]]$User.'mS-DS-ConsistencyGuid'
        if ($null -ne $bytes -and $bytes.Count -eq 16) {
            [guid]::new($bytes)
        }
    }
}


function Get-RecipientTypeState {
    <#
    .SYNOPSIS
        Classifies an AD user's msExchRecipientTypeDetails as None, RemoteUserMailbox, or Unexpected.
    .EXAMPLE
        Get-RecipientTypeState -User $targetUser
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # An AD user read with the msExchRecipientTypeDetails property.
        [Parameter(Mandatory)]
        [psobject]$User
    )

    $typeDetails = $User.msExchRecipientTypeDetails
    if ($null -eq $typeDetails -or [string]::IsNullOrWhiteSpace([string]$typeDetails)) {
        'None'
    }
    elseif ([long]$typeDetails -eq $script:RemoteUserMailboxType) {
        'RemoteUserMailbox'
    }
    else {
        'Unexpected'
    }
}


function Get-ForestUserMergePlan {
    <#
    .SYNOPSIS
        Works out what has to happen to merge one person's legacy-forest user into their target-forest user.
    .DESCRIPTION
        For forest consolidations where one person can have a user in each of two forests that sync to the same
        tenant: the target-forest user is kept, and the legacy-forest user, its Entra user, and any mail contacts
        for the person are folded into it. Give the command what is already known about the person, and it
        returns the facts that matter and the operations to run, in order. It reads and changes nothing itself,
        so it can be run over a whole population to size the work before anything is touched.

        Inputs (gather them however suits the environment; only these properties are read):
          - AD users, from Get-ADUser -Properties 'mS-DS-ConsistencyGuid', 'msExchRecipientTypeDetails',
            'proxyAddresses', 'legacyExchangeDN': ObjectGUID, UserPrincipalName, and those four.
          - Entra users (the one whose onPremisesImmutableId is each AD user's consistency GUID in base64), from
            Get-MgUser -Property 'userPrincipalName', 'assignedLicenses': UserPrincipalName, AssignedLicenses.
          - Contacts: only their count is used.
        Resolve duplicates before calling: each parameter is one person's single object.

        Operations, in the order they are returned:
          ManualInterventionRequestTargetUserProvisioning    no target user; nothing else is planned
          ManualInterventionTargetUserUnexpectedRecipientType / ...LegacyUser...   a mailbox or other recipient
                                                              type where only a remote mailbox or none is expected
          ManualInterventionDualLicense                       both Entra users are licensed
          LicenseUser                                         no Entra user is licensed
          SetTargetUserUpnFromLegacyUser / SetLegacyUserUpnFromTargetUser / ManualInterventionForUpn
          SetTargetConsistencyGuidFromLegacyUser / SetLegacyConsistencyGuidFromTargetUser /
          SetTargetConsistencyGuidFromObjectGuid / ResetLegacyConsistencyGuidFromTargetUser /
          ManualInterventionForConsistencyGuid
          EnableTargetRemoteMailboxFromLegacyUser / EnableTargetRemoteMailboxFromExchangeOnlineMailbox /
          EnableTargetRemoteMailbox / AddLegacyX500ToTargetUser
          MergeLegacyContactIntoTargetUser, MergeLegacyContactIntoLegacyUser,
          TransferLegacyContactMembershipToLegacyUser or WarnLegacyContactGroupMembershipLoss, RemoveLegacyContact
          MergeTargetContactIntoTargetUser, TransferTargetContactMembershipToTargetUser, RemoveTargetContact

        Set-ADConsistencyGuid (ADConsistencyGuid module) carries out the consistency GUID operations; a Reset
        also needs the legacy user taken out of sync scope first (see ResetSourceAnchor.md).
    .INPUTS
        Objects with TargetUser, LegacyUser, TargetEntraUser, LegacyEntraUser, ExchangeOnlineMailbox,
        TargetContact, and LegacyContact properties, one per person.
    .OUTPUTS
        ForestUserMerge.Plan
    .EXAMPLE
        $adProperties = 'mS-DS-ConsistencyGuid', 'msExchRecipientTypeDetails', 'proxyAddresses', 'legacyExchangeDN'
        $entraProperties = 'userPrincipalName', 'assignedLicenses'
        $planParameters = @{
            TargetUser       = Get-ADUser -Identity 'jdoe' -Server 'contoso.com' -Properties $adProperties
            LegacyUser       = Get-ADUser -Identity 'jdoe' -Server 'fabrikam.com' -Properties $adProperties
            TargetEntraUser  = Get-MgUser -UserId 'jdoe@contoso.com' -Property $entraProperties
            DesiredUpnSuffix = 'contoso.com'
        }
        Get-ForestUserMergePlan @planParameters

        Plans the merge for one person whose legacy user has no Entra user of its own.
    .EXAMPLE
        $people | Get-ForestUserMergePlan -DesiredUpnSuffix 'contoso.com' |
            Group-Object -Property RequiresManualIntervention

        Plans a population gathered earlier (one object per person with TargetUser, LegacyUser, and so on) and
        splits it into what can be automated and what needs a person to look at it.
    #>
    [CmdletBinding()]
    [OutputType('ForestUserMerge.Plan')]
    param(
        # The person's user in the forest being kept. Without it, the plan is to ask for one to be provisioned.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [psobject]$TargetUser,

        # The person's user in the forest being retired, if they have one.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [psobject]$LegacyUser,

        # The Entra user anchored to TargetUser, if it has synced.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [psobject]$TargetEntraUser,

        # The Entra user anchored to LegacyUser, if it has synced. Pass the same object as TargetEntraUser when
        # both AD users already share one anchor.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [psobject]$LegacyEntraUser,

        # An Exchange Online mailbox that already belongs to the person, used when there is no legacy user to
        # take mail attributes from.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [psobject]$ExchangeOnlineMailbox,

        # Mail contacts for the person in the target forest.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$TargetContact,

        # Mail contacts for the person in the legacy forest.
        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [psobject[]]$LegacyContact,

        # The UPN suffix every merged user should end up with, for example contoso.com.
        [Parameter(Mandatory, HelpMessage = 'The UPN suffix merged users should have, for example contoso.com.')]
        [ValidateNotNullOrEmpty()]
        [string]$DesiredUpnSuffix
    )

    process {
        $hasTarget = $null -ne $TargetUser
        $hasLegacy = $null -ne $LegacyUser
        $targetGuid = ConvertTo-ConsistencyGuid -User $TargetUser
        $legacyGuid = ConvertTo-ConsistencyGuid -User $LegacyUser
        $targetLicensed = $null -ne $TargetEntraUser -and @($TargetEntraUser.AssignedLicenses).Count -ge 1
        $legacyLicensed = $null -ne $LegacyEntraUser -and @($LegacyEntraUser.AssignedLicenses).Count -ge 1
        $targetAnchored = $null -ne $targetGuid
        $legacyAnchored = $null -ne $legacyGuid
        $guidsMatch = if ($targetAnchored -and $legacyAnchored) { $targetGuid -eq $legacyGuid }

        # With one shared anchor, both AD users already map to the same Entra user, so its license is not doubled.
        $licensedUser = switch ($true) {
            ($guidsMatch -and ($targetLicensed -or $legacyLicensed)) { 'Joined'; break }
            ($targetLicensed -and $legacyLicensed) { 'Both'; break }
            $targetLicensed { 'Target'; break }
            $legacyLicensed { 'Legacy'; break }
            default { 'None' }
        }

        $targetType = if ($hasTarget) { Get-RecipientTypeState -User $TargetUser }
        $legacyType = if ($hasLegacy) { Get-RecipientTypeState -User $LegacyUser }
        $suffixPattern = "*@$DesiredUpnSuffix"
        $targetSuffixCorrect = if ($hasTarget) { $TargetUser.UserPrincipalName -like $suffixPattern }
        $legacySuffixCorrect = if ($hasLegacy) { $LegacyUser.UserPrincipalName -like $suffixPattern }
        $legacyX500 = if ($hasLegacy -and -not [string]::IsNullOrWhiteSpace($LegacyUser.legacyExchangeDN)) {
            "x500:$($LegacyUser.legacyExchangeDN)"
        }

        $facts = [ordered]@{
            TargetUserExists                = $hasTarget
            LegacyUserExists                = $hasLegacy
            TargetConsistencyGuid           = $targetGuid
            LegacyConsistencyGuid           = $legacyGuid
            ConsistencyGuidsMatch           = $guidsMatch
            TargetEntraUserExists           = $null -ne $TargetEntraUser
            LegacyEntraUserExists           = $null -ne $LegacyEntraUser
            TargetEntraUpnMatches           = if ($hasTarget -and $null -ne $TargetEntraUser) {
                $TargetEntraUser.UserPrincipalName -eq $TargetUser.UserPrincipalName
            }
            LicensedUser                    = $licensedUser
            TargetRecipientType             = $targetType
            LegacyRecipientType             = $legacyType
            TargetUpnSuffixCorrect          = $targetSuffixCorrect
            LegacyUpnSuffixCorrect          = $legacySuffixCorrect
            TargetHasLegacyX500             = if ($hasTarget -and $null -ne $legacyX500) {
                @($TargetUser.proxyAddresses) -contains $legacyX500
            }
            TargetContactCount              = @($TargetContact).Where({ $null -ne $_ }).Count
            LegacyContactCount              = @($LegacyContact).Where({ $null -ne $_ }).Count
            ExchangeOnlineMailboxExists     = $null -ne $ExchangeOnlineMailbox
        }

        $operations = [System.Collections.Generic.List[string]]::new()
        if (-not $hasTarget) {
            $operations.Add('ManualInterventionRequestTargetUserProvisioning')
        }
        else {
            if ($targetType -eq 'Unexpected') {
                $operations.Add('ManualInterventionTargetUserUnexpectedRecipientType')
            }
            if ($legacyType -eq 'Unexpected') {
                $operations.Add('ManualInterventionLegacyUserUnexpectedRecipientType')
            }

            switch ($licensedUser) {
                'Both' { $operations.Add('ManualInterventionDualLicense') }
                'None' { $operations.Add('LicenseUser') }
                default { }
            }

            $upnNeedsWork = -not $targetSuffixCorrect -or ($hasLegacy -and -not $legacySuffixCorrect)
            if ($upnNeedsWork) {
                $upnOperation = switch ($true) {
                    ($hasLegacy -and $legacySuffixCorrect) { 'SetTargetUserUpnFromLegacyUser'; break }
                    ($hasLegacy -and $targetSuffixCorrect) { 'SetLegacyUserUpnFromTargetUser'; break }
                    default { 'ManualInterventionForUpn' }
                }
                $operations.Add($upnOperation)
            }

            # Re-anchoring the legacy user is only safe when the target user's Entra object is clearly the keeper.
            $targetEntraIsKeeper = $facts.TargetEntraUpnMatches -and $licensedUser -eq 'Target'
            $anchorOperation = switch ($true) {
                (-not $hasLegacy -and -not $targetAnchored) { 'SetTargetConsistencyGuidFromObjectGuid'; break }
                (-not $hasLegacy) { $null; break }
                (-not $targetAnchored -and $legacyAnchored) { 'SetTargetConsistencyGuidFromLegacyUser'; break }
                ($targetAnchored -and -not $legacyAnchored) { 'SetLegacyConsistencyGuidFromTargetUser'; break }
                # Neither user has an anchor yet: which one should own the person's Entra user is a judgment call.
                (-not $targetAnchored) { 'ManualInterventionForConsistencyGuid'; break }
                $guidsMatch { $null; break }
                $targetEntraIsKeeper { 'ResetLegacyConsistencyGuidFromTargetUser'; break }
                default { 'ManualInterventionForConsistencyGuid' }
            }
            if ($null -ne $anchorOperation) {
                $operations.Add($anchorOperation)
            }

            $mailboxOperation = switch ($true) {
                ($targetType -eq 'Unexpected') { $null; break }
                ($targetType -eq 'RemoteUserMailbox') {
                    if ($legacyType -eq 'RemoteUserMailbox' -and $facts.TargetHasLegacyX500 -eq $false) {
                        'AddLegacyX500ToTargetUser'
                    }
                    break
                }
                ($legacyType -eq 'RemoteUserMailbox') { 'EnableTargetRemoteMailboxFromLegacyUser'; break }
                (-not $hasLegacy -and $null -ne $ExchangeOnlineMailbox) {
                    'EnableTargetRemoteMailboxFromExchangeOnlineMailbox'
                    break
                }
                default { 'EnableTargetRemoteMailbox' }
            }
            if ($null -ne $mailboxOperation) {
                $operations.Add($mailboxOperation)
            }

            if ($facts.LegacyContactCount -ge 1) {
                $operations.Add('MergeLegacyContactIntoTargetUser')
                if ($hasLegacy) {
                    if ($legacyType -eq 'RemoteUserMailbox') {
                        $operations.Add('MergeLegacyContactIntoLegacyUser')
                    }
                    $operations.Add('TransferLegacyContactMembershipToLegacyUser')
                }
                else {
                    $operations.Add('WarnLegacyContactGroupMembershipLoss')
                }
                $operations.Add('RemoveLegacyContact')
            }
            if ($facts.TargetContactCount -ge 1) {
                $operations.Add('MergeTargetContactIntoTargetUser')
                $operations.Add('TransferTargetContactMembershipToTargetUser')
                $operations.Add('RemoveTargetContact')
            }
        }

        $plan = [ordered]@{
            PSTypeName                 = 'ForestUserMerge.Plan'
            TargetUserPrincipalName    = if ($hasTarget) { $TargetUser.UserPrincipalName }
            LegacyUserPrincipalName    = if ($hasLegacy) { $LegacyUser.UserPrincipalName }
            Operations                 = $operations.ToArray()
            RequiresManualIntervention = $operations.Where({ $_ -like 'ManualIntervention*' }).Count -gt 0
        }
        foreach ($fact in $facts.GetEnumerator()) {
            $plan[$fact.Key] = $fact.Value
        }
        [PSCustomObject]$plan
    }
}
