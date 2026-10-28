#requires -Version 7.0

<#
The AD attribute values Exchange writes for each remote mailbox type, keyed by the on-premises mailbox type being
converted. msExchRemoteRecipientType is a flag set: Migrated (4) plus Room (32), Equipment (64), or Shared (96).
msExchRecipientDisplayType is the Synced* display type that matches each kind of mailbox.
#>
$script:RemoteMailboxAttribute = @{
    UserMailbox      = @{
        RecipientTypeDetails       = 'RemoteUserMailbox'
        msExchRecipientTypeDetails = [long]2147483648
        msExchRecipientDisplayType = -2147483642
        msExchRemoteRecipientType  = 4
    }
    SharedMailbox    = @{
        RecipientTypeDetails       = 'RemoteSharedMailbox'
        msExchRecipientTypeDetails = [long]34359738368
        msExchRecipientDisplayType = -2147483642
        msExchRemoteRecipientType  = 100
    }
    RoomMailbox      = @{
        RecipientTypeDetails       = 'RemoteRoomMailbox'
        msExchRecipientTypeDetails = [long]8589934592
        msExchRecipientDisplayType = -2147481850
        msExchRemoteRecipientType  = 36
    }
    EquipmentMailbox = @{
        RecipientTypeDetails       = 'RemoteEquipmentMailbox'
        msExchRecipientTypeDetails = [long]17179869184
        msExchRecipientDisplayType = -2147481594
        msExchRemoteRecipientType  = 68
    }
}


function Get-DomainFromDistinguishedName {
    <#
    .SYNOPSIS
        Returns the DNS domain name encoded in a distinguished name's DC= components.
    .EXAMPLE
        Get-DomainFromDistinguishedName -DistinguishedName 'CN=Jane Doe,OU=Users,DC=corp,DC=contoso,DC=com'

        Returns 'corp.contoso.com'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The distinguished name of any object in the domain.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DistinguishedName
    )

    # Splitting on commas is safe for the DC= components, which cannot contain escaped commas.
    $domainComponents = ($DistinguishedName -split ',').ForEach({ $_.Trim() }).Where({ $_ -like 'DC=*' })
    $domainComponents.ForEach({ $_.Substring(3) }) -join '.'
}


function ConvertTo-RemoteMailbox {
    <#
    .SYNOPSIS
        Converts on-premises mailboxes whose content now lives in Exchange Online into remote mailboxes, in place.
    .DESCRIPTION
        After a mailbox is moved to Exchange Online by something other than a hybrid (MRS) move, such as a
        third-party migration tool or a cross-tenant move, the on-premises object is still a mailbox. On-premises
        mail then keeps delivering to the old database. Disable-Mailbox followed by Enable-RemoteMailbox would fix
        the type but drop the Exchange GUID that ties the object to its cloud mailbox.

        This command instead rewrites the AD user in place, keeping its Exchange GUID and every address:
          - sets msExchRecipientTypeDetails, msExchRecipientDisplayType, and msExchRemoteRecipientType to the
            matching remote type (user, shared, room, and equipment mailboxes are supported);
          - sets targetAddress to the mailbox's address in the tenant routing domain, so on-premises mail
            routes to Exchange Online;
          - clears homeMDB, homeMTA, and msExchHomeServerName, detaching the object from its on-premises
            database. The old on-premises mailbox becomes disconnected and is purged under that database's
            deleted-mailbox retention.

        msExchVersion is left as it is: an existing mailbox already carries a valid version.

        Only run this once the Exchange Online mailbox exists with the same Exchange GUID, or mail to the user
        will be undeliverable. A mailbox with an on-premises archive is refused, because conversion would
        disconnect the archive; move or remove the archive first.

        Each conversion is confirmed (ConfirmImpact is High); use -WhatIf to preview or -Confirm:$false to
        skip the prompts. A mailbox that cannot be converted produces a non-terminating error and the rest
        continue.

        Requires the on-premises Exchange Management Shell cmdlets (an unprefixed Get-Mailbox) and the
        ActiveDirectory module, with rights to write those attributes.
    .INPUTS
        System.String, or mailbox objects from Get-Mailbox.
    .OUTPUTS
        ExchangeHybridRecipient.RemoteMailboxConversion
    .EXAMPLE
        ConvertTo-RemoteMailbox -Identity 'jdoe@contoso.com' -RoutingDomain 'contoso.mail.onmicrosoft.com' -WhatIf

        Shows the change that would convert Jane Doe's mailbox, without making it.
    .EXAMPLE
        Import-Csv -Path 'D:\Migration\Wave3-Completed.csv' |
            ConvertTo-RemoteMailbox -RoutingDomain 'contoso.mail.onmicrosoft.com' -Confirm:$false |
            Export-Csv -Path 'D:\Migration\Wave3-Converted.csv'

        Converts every mailbox in a CSV with an Identity column, without prompting, and records the results.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('ExchangeHybridRecipient.RemoteMailboxConversion')]
    param(
        # Mailboxes to convert: any identity Get-Mailbox accepts, or mailbox objects piped from Get-Mailbox.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Identity,

        # The tenant mail routing domain, for example contoso.mail.onmicrosoft.com. Each mailbox must have
        # exactly one address in it, which becomes targetAddress. Defaults to any *.mail.onmicrosoft.com address.
        [ValidateNotNullOrEmpty()]
        [string]$RoutingDomain,

        # Domain controller or domain to write to. Defaults to each mailbox's own domain, from its
        # distinguished name.
        [ValidateNotNullOrEmpty()]
        [string]$Server
    )

    begin {
        foreach ($commandName in 'Get-Mailbox', 'Set-ADUser') {
            if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.Management.Automation.CommandNotFoundException]::new(
                            "[$commandName] is not available. Run this from an on-premises Exchange Management " +
                            'Shell session (without a cmdlet prefix) that also has the ActiveDirectory module.'
                        ),
                        'RequiredCommandNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $commandName
                    )
                )
            }
        }

        $routingAddressPattern = if ($PSBoundParameters.ContainsKey('RoutingDomain')) {
            "smtp:*@$RoutingDomain"
        }
        else {
            'smtp:*@*.mail.onmicrosoft.com'
        }
    }

    process {
        foreach ($mailboxIdentity in $Identity) {
            try {
                $mailbox = Get-Mailbox -Identity $mailboxIdentity -ErrorAction Stop
                $sourceType = [string]$mailbox.RecipientTypeDetails

                $remoteAttribute = $script:RemoteMailboxAttribute[$sourceType]
                if ($null -eq $remoteAttribute) {
                    throw [System.InvalidOperationException]::new(
                        "[$mailboxIdentity] is a [$sourceType]; only user, shared, room, and equipment " +
                        'mailboxes can be converted.'
                    )
                }
                if ($mailbox.ArchiveDatabase) {
                    throw [System.InvalidOperationException]::new(
                        "[$mailboxIdentity] has an on-premises archive in [$($mailbox.ArchiveDatabase)], which " +
                        'conversion would disconnect. Move or remove the archive first.'
                    )
                }

                $routingAddresses = @($mailbox.EmailAddresses.Where({ $_ -like $routingAddressPattern }))
                if ($routingAddresses.Count -ne 1) {
                    throw [System.InvalidOperationException]::new(
                        "[$mailboxIdentity] has [$($routingAddresses.Count)] addresses matching " +
                        "[$($routingAddressPattern.Substring(5))]; exactly one is needed for targetAddress."
                    )
                }
                # Proxy addresses carry their type prefix; targetAddress always uses the primary-form SMTP: prefix.
                $targetAddress = 'SMTP:' + ([string]$routingAddresses[0]).Split(':', 2)[1]

                $domainController = if ($PSBoundParameters.ContainsKey('Server')) {
                    $Server
                }
                else {
                    Get-DomainFromDistinguishedName -DistinguishedName $mailbox.DistinguishedName
                }

                $setParameters = @{
                    Identity    = $mailbox.Guid.ToString()
                    Server      = $domainController
                    Clear       = 'homeMDB', 'homeMTA', 'msExchHomeServerName'
                    Replace     = @{
                        msExchRecipientTypeDetails = $remoteAttribute.msExchRecipientTypeDetails
                        msExchRecipientDisplayType = $remoteAttribute.msExchRecipientDisplayType
                        msExchRemoteRecipientType  = $remoteAttribute.msExchRemoteRecipientType
                        targetAddress              = $targetAddress
                    }
                    Confirm     = $false
                    ErrorAction = 'Stop'
                }
                $target = "$mailboxIdentity ($($mailbox.ExchangeGuid))"
                $remoteType = $remoteAttribute.RecipientTypeDetails
                $action = "Convert $sourceType to $remoteType, targetAddress $targetAddress"
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    Set-ADUser @setParameters

                    [PSCustomObject]@{
                        PSTypeName                   = 'ExchangeHybridRecipient.RemoteMailboxConversion'
                        Identity                     = $mailboxIdentity
                        PrimarySmtpAddress           = [string]$mailbox.PrimarySmtpAddress
                        ExchangeGuid                 = $mailbox.ExchangeGuid
                        PreviousRecipientTypeDetails = $sourceType
                        RecipientTypeDetails         = $remoteAttribute.RecipientTypeDetails
                        TargetAddress                = $targetAddress
                        DomainController             = $domainController
                    }
                }
            }
            catch {
                $conversionError = $PSItem
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $conversionError.Exception,
                        'RemoteMailboxConversionFailed',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation,
                        $mailboxIdentity
                    )
                )
            }
        }
    }
}
