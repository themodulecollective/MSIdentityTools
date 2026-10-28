#requires -Version 7.0

$script:ConsistencyGuidAttribute = 'mS-DS-ConsistencyGuid'
$script:ReadProperty = @('mS-DS-ConsistencyGuid', 'sAMAccountName', 'userPrincipalName')

<#
On both public commands, -Identity's aliases list DistinguishedName first. It is a plain string on AD objects, so
pipeline binding by property name picks it up; ObjectGUID is a [guid], and if it came first the whole object would
be converted to a string by value instead.
#>


function Assert-ADCommand {
    <#
    .SYNOPSIS
        Throws a terminating error, attributed to the caller, when an ActiveDirectory cmdlet is not available.
    .EXAMPLE
        Assert-ADCommand -Name 'Get-ADObject', 'Set-ADObject' -Cmdlet $PSCmdlet
    #>
    [CmdletBinding()]
    param(
        # The ActiveDirectory module cmdlets the caller needs.
        [Parameter(Mandatory)]
        [string[]]$Name,

        # The calling command's $PSCmdlet, so the error is reported against the command the user ran.
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    foreach ($commandName in $Name) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
            $Cmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.Management.Automation.CommandNotFoundException]::new(
                        "[$commandName] is not available. Install the ActiveDirectory module (RSAT) first."
                    ),
                    'RequiredCommandNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $commandName
                )
            )
        }
    }
}


function Get-IdentifiedADObject {
    <#
    .SYNOPSIS
        Finds exactly one AD object by ObjectGUID, distinguished name, or sAMAccountName.
    .DESCRIPTION
        Get-ADObject -Identity takes only a GUID or distinguished name, so a sAMAccountName is looked up with an
        escaped LDAP filter instead. sAMAccountName cannot contain '=', which is how a distinguished name is told
        apart from it. Throws when nothing, or more than one object, matches.
    .EXAMPLE
        Get-IdentifiedADObject -Identity 'jdoe' -ConnectionParameter @{ Server = 'dc01.contoso.com' }
    #>
    [CmdletBinding()]
    param(
        # An ObjectGUID string, distinguished name, or sAMAccountName.
        [Parameter(Mandatory)]
        [string]$Identity,

        # Server and Credential parameters to pass through to Get-ADObject.
        [Parameter(Mandatory)]
        [hashtable]$ConnectionParameter
    )

    $getParameters = @{
        Properties  = $script:ReadProperty
        ErrorAction = 'Stop'
    }
    $objectGuid = [guid]::Empty
    if ([guid]::TryParse($Identity, [ref]$objectGuid)) {
        $getParameters.Identity = $objectGuid
    }
    elseif ($Identity.Contains('=')) {
        $getParameters.Identity = $Identity
    }
    else {
        # RFC 4515 escaping, so a name containing *, (, ), or \ cannot widen the filter.
        $escapedName = $Identity -replace '([\\*()\x00])', { '\{0:x2}' -f [int][char]$_.Groups[1].Value }
        $getParameters.LDAPFilter = "(sAMAccountName=$escapedName)"
    }

    $adObject = @(Get-ADObject @getParameters @ConnectionParameter)
    switch ($adObject.Count) {
        1 {
            $adObject[0]
        }
        0 {
            throw [System.Management.Automation.ItemNotFoundException]::new("No AD object matches [$Identity].")
        }
        default {
            throw [System.InvalidOperationException]::new(
                "[$Identity] matches [$($adObject.Count)] AD objects; use an ObjectGUID or distinguished name."
            )
        }
    }
}


function ConvertTo-ConsistencyGuidStatus {
    <#
    .SYNOPSIS
        Builds an ADConsistencyGuid.Status object from an AD object read with the consistency GUID property.
    .EXAMPLE
        Get-IdentifiedADObject -Identity 'jdoe' -ConnectionParameter @{} |
            ConvertTo-ConsistencyGuidStatus -Identity 'jdoe'
    #>
    [CmdletBinding()]
    [OutputType('ADConsistencyGuid.Status')]
    param(
        # The AD object, as returned by Get-IdentifiedADObject.
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject]$ADObject,

        # The identity the caller asked for, carried through so results can be matched to input.
        [Parameter(Mandatory)]
        [string]$Identity
    )

    process {
        $consistencyGuidBytes = [byte[]]$ADObject.$script:ConsistencyGuidAttribute
        $consistencyGuid = if ($null -ne $consistencyGuidBytes -and $consistencyGuidBytes.Count -eq 16) {
            [guid]::new($consistencyGuidBytes)
        }

        [PSCustomObject]@{
            PSTypeName        = 'ADConsistencyGuid.Status'
            Identity          = $Identity
            DistinguishedName = $ADObject.DistinguishedName
            ObjectClass       = $ADObject.ObjectClass
            SamAccountName    = $ADObject.sAMAccountName
            UserPrincipalName = $ADObject.userPrincipalName
            ObjectGuid        = [guid]$ADObject.ObjectGUID
            ConsistencyGuid   = $consistencyGuid
            # Entra stores the source anchor as the base64 of the GUID's bytes (onPremisesImmutableId).
            ImmutableId       = if ($null -ne $consistencyGuid) {
                [System.Convert]::ToBase64String($consistencyGuid.ToByteArray())
            }
            MatchesObjectGuid = $null -ne $consistencyGuid -and $consistencyGuid -eq [guid]$ADObject.ObjectGUID
        }
    }
}


function Get-ADConsistencyGuid {
    <#
    .SYNOPSIS
        Reports an AD object's mS-DS-ConsistencyGuid and the Entra ImmutableID it gives the synced object.
    .DESCRIPTION
        When Entra Connect (AAD Connect) uses mS-DS-ConsistencyGuid as the source anchor, the synced object's
        ImmutableID (onPremisesImmutableId) is the base64 form of that GUID. This shows, for users, groups,
        contacts, or any other object class, whether the attribute is set, the ImmutableID to expect in Entra,
        and whether the value is the object's own ObjectGUID (the usual case) or came from somewhere else, such
        as an object in another forest.

        An identity that does not match exactly one object produces a non-terminating error and the rest are
        still read.
    .INPUTS
        System.String, or objects with an ObjectGUID, DistinguishedName, or SamAccountName property.
    .OUTPUTS
        ADConsistencyGuid.Status
    .EXAMPLE
        Get-ADConsistencyGuid -Identity 'jdoe', 'CN=Sales Team,OU=Groups,DC=contoso,DC=com'

        Shows the consistency GUID and expected ImmutableID for a user and a group.
    .EXAMPLE
        Get-ADUser -Filter * -SearchBase 'OU=Wave3,DC=contoso,DC=com' |
            Get-ADConsistencyGuid -Server 'dc01.contoso.com' |
            Where-Object -Property ConsistencyGuid -EQ $null

        Lists the users in an OU that do not have a consistency GUID yet.
    #>
    [CmdletBinding()]
    [OutputType('ADConsistencyGuid.Status')]
    param(
        # Objects to read: an ObjectGUID, distinguished name, or sAMAccountName, or AD objects from the pipeline.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('DistinguishedName', 'ObjectGUID', 'SamAccountName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Identity,

        # Domain controller or domain to read from. Defaults to the computer's domain.
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        # Credential for the domain, if the current user cannot read it.
        [System.Management.Automation.Credential()]
        [pscredential]$Credential = [pscredential]::Empty
    )

    begin {
        Assert-ADCommand -Name 'Get-ADObject' -Cmdlet $PSCmdlet

        $connection = @{}
        foreach ($parameterName in 'Server', 'Credential') {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $connection[$parameterName] = $PSBoundParameters[$parameterName]
            }
        }
    }

    process {
        foreach ($objectIdentity in $Identity) {
            try {
                Get-IdentifiedADObject -Identity $objectIdentity -ConnectionParameter $connection |
                    ConvertTo-ConsistencyGuidStatus -Identity $objectIdentity
            }
            catch {
                $readError = $PSItem
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $readError.Exception,
                        'ADConsistencyGuidReadFailed',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $objectIdentity
                    )
                )
            }
        }
    }
}


function Set-ADConsistencyGuid {
    <#
    .SYNOPSIS
        Sets mS-DS-ConsistencyGuid on AD objects, then reads it back to confirm the write.
    .DESCRIPTION
        Stamps the attribute that Entra Connect (AAD Connect) uses as the source anchor when it is configured
        for mS-DS-ConsistencyGuid. By default each object gets its own ObjectGUID, which is what Entra Connect
        would write for a user. Do this ahead of time for objects it does not write back, such as groups and
        contacts, or before switching the source anchor from objectGUID.

        With -ConsistencyGuid, one object gets a value you supply instead. This is how an object in a new forest
        takes over an existing Entra object during a cross-forest move: give it the value the old forest's object
        synced with (Get-ADConsistencyGuid's ConsistencyGuid, or the old ObjectGUID).

        An object that already has the target value is left alone and reported as it is. An object with a
        different value is refused unless -Overwrite is given, because changing a synced object's source anchor
        detaches it from its Entra object. Each write is confirmed (ConfirmImpact is High); use -WhatIf to
        preview or -Confirm:$false to skip the prompts.

        The value is read back from the same domain controller that wrote it. Without -Server, one domain
        controller in the computer's domain is picked for the whole run so that read-back is reliable; pass a
        domain controller name, not a domain name, when you choose -Server yourself. An object that cannot be
        set or confirmed produces a non-terminating error and the rest continue.
    .INPUTS
        System.String, or objects with an ObjectGUID, DistinguishedName, or SamAccountName property.
    .OUTPUTS
        ADConsistencyGuid.Status, read back after the write.
    .EXAMPLE
        Set-ADConsistencyGuid -Identity 'CN=Sales Team,OU=Groups,DC=contoso,DC=com' -WhatIf

        Shows the write that would stamp the group's own ObjectGUID, without making it.
    .EXAMPLE
        $old = Get-ADConsistencyGuid -Identity 'jdoe' -Server 'dc01.fabrikam.com'
        Set-ADConsistencyGuid -Identity 'jdoe' -Server 'dc01.contoso.com' -ConsistencyGuid $old.ConsistencyGuid

        Gives the user's new account in the contoso.com forest the source anchor their fabrikam.com account
        synced with, so Entra Connect matches it to the same Entra user.
    .EXAMPLE
        Get-ADGroup -Filter * -SearchBase 'OU=Groups,DC=contoso,DC=com' |
            Set-ADConsistencyGuid -Confirm:$false |
            Export-Csv -Path 'D:\Sync\GroupConsistencyGuid.csv'

        Stamps every group in an OU that does not have a value yet, without prompting, and records the results.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('ADConsistencyGuid.Status')]
    param(
        # Objects to set: an ObjectGUID, distinguished name, or sAMAccountName, or AD objects from the pipeline.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('DistinguishedName', 'ObjectGUID', 'SamAccountName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Identity,

        # The value to write. Defaults to each object's own ObjectGUID. Allowed with one object only, since two
        # objects with the same source anchor cannot both sync.
        [ValidateScript({ $_ -ne [guid]::Empty })]
        [guid]$ConsistencyGuid,

        # Replace a value that is already set to something else.
        [switch]$Overwrite,

        # Domain controller to write to and read back from. Defaults to one found in the computer's domain.
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        # Credential for the domain, if the current user cannot write the attribute.
        [System.Management.Automation.Credential()]
        [pscredential]$Credential = [pscredential]::Empty
    )

    begin {
        Assert-ADCommand -Name 'Get-ADObject', 'Set-ADObject', 'Get-ADDomainController' -Cmdlet $PSCmdlet

        $connection = @{}
        if ($PSBoundParameters.ContainsKey('Credential')) {
            $connection.Credential = $Credential
        }
        if ($PSBoundParameters.ContainsKey('Server')) {
            $connection.Server = $Server
        }
        else {
            try {
                $connection.Server = [string](Get-ADDomainController -Discover -ErrorAction Stop).HostName
            }
            catch {
                $discoverError = $PSItem
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $discoverError.Exception,
                        'DomainControllerNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $null
                    )
                )
            }
        }
        Write-Verbose -Message "Writing to and reading back from [$($connection.Server)]."

        $objectCount = 0
    }

    process {
        foreach ($objectIdentity in $Identity) {
            $objectCount++
            if ($PSBoundParameters.ContainsKey('ConsistencyGuid') -and $objectCount -gt 1) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            '-ConsistencyGuid can be given to one object only; two objects with the same ' +
                            'source anchor cannot both sync.'
                        ),
                        'ConsistencyGuidForMultipleObjects',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $objectIdentity
                    )
                )
            }

            try {
                $current = Get-IdentifiedADObject -Identity $objectIdentity -ConnectionParameter $connection |
                    ConvertTo-ConsistencyGuidStatus -Identity $objectIdentity
                $targetGuid = if ($PSBoundParameters.ContainsKey('ConsistencyGuid')) {
                    $ConsistencyGuid
                }
                else {
                    $current.ObjectGuid
                }

                if ($current.ConsistencyGuid -eq $targetGuid) {
                    Write-Verbose -Message "[$objectIdentity] already has consistency GUID [$targetGuid]."
                    $current
                    continue
                }
                if ($null -ne $current.ConsistencyGuid -and -not $Overwrite) {
                    throw [System.InvalidOperationException]::new(
                        "[$objectIdentity] already has consistency GUID [$($current.ConsistencyGuid)]. Changing " +
                        'it detaches a synced object from its Entra object; use -Overwrite if that is intended.'
                    )
                }

                $immutableId = [System.Convert]::ToBase64String($targetGuid.ToByteArray())
                $action = "Set $script:ConsistencyGuidAttribute to [$targetGuid] (ImmutableID [$immutableId])"
                if ($null -ne $current.ConsistencyGuid) {
                    $action = "$action, replacing [$($current.ConsistencyGuid)]"
                }
                if ($PSCmdlet.ShouldProcess($current.DistinguishedName, $action)) {
                    $setParameters = @{
                        Identity    = $current.ObjectGuid
                        Replace     = @{ $script:ConsistencyGuidAttribute = $targetGuid.ToByteArray() }
                        Confirm     = $false
                        ErrorAction = 'Stop'
                    }
                    Set-ADObject @setParameters @connection

                    $updatedIdentity = $current.ObjectGuid.ToString()
                    $updated = Get-IdentifiedADObject -Identity $updatedIdentity -ConnectionParameter $connection |
                        ConvertTo-ConsistencyGuidStatus -Identity $objectIdentity
                    if ($updated.ConsistencyGuid -ne $targetGuid) {
                        throw [System.InvalidOperationException]::new(
                            "[$objectIdentity] reads back consistency GUID [$($updated.ConsistencyGuid)] from " +
                            "[$($connection.Server)] after writing [$targetGuid]."
                        )
                    }
                    $updated
                }
            }
            catch {
                $setError = $PSItem
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $setError.Exception,
                        'ADConsistencyGuidSetFailed',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation,
                        $objectIdentity
                    )
                )
            }
        }
    }
}
