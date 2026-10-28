#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Offline smoke tests. Exchange and ActiveDirectory cmdlets are replaced with stubs and mocks, so neither is
    needed to run them.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll/BeforeEach are read in It blocks, which the analyzer cannot see.'
)]
param()

BeforeAll {
    # Pester can only mock commands that exist, so stand in for them when the real ones are not installed.
    if ($null -eq (Get-Command -Name Get-Mailbox -ErrorAction SilentlyContinue)) {
        function global:Get-Mailbox {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [CmdletBinding()]
            param($Identity)
        }
    }
    if ($null -eq (Get-Command -Name Set-ADUser -ErrorAction SilentlyContinue)) {
        function global:Set-ADUser {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSShouldProcess', '', Justification = 'Stub; accepts -Confirm like the real cmdlet.'
            )]
            [CmdletBinding(SupportsShouldProcess)]
            param($Identity, $Server, $Clear, $Replace)
        }
    }

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ExchangeHybridRecipient.psd1') -Force
    $moduleName = 'ExchangeHybridRecipient'
    $routingDomain = 'contoso.mail.onmicrosoft.com'

    function Get-TestMailbox {
        param(
            [string]$Name,
            [string]$Type,
            [string[]]$EmailAddresses,
            [string]$ArchiveDatabase
        )

        [PSCustomObject]@{
            Guid                 = [guid]::NewGuid()
            ExchangeGuid         = [guid]::NewGuid()
            PrimarySmtpAddress   = "$Name@contoso.com"
            RecipientTypeDetails = $Type
            EmailAddresses       = $EmailAddresses
            ArchiveDatabase      = $ArchiveDatabase
            DistinguishedName    = "CN=$Name,OU=Resources,DC=corp,DC=contoso,DC=com"
        }
    }

    function Get-OwnConversionError {
        param($ErrorList)

        # -ErrorVariable also collects the inner errors the function caught, so keep only its own records.
        $ErrorList.Where({ $_.FullyQualifiedErrorId -like 'RemoteMailboxConversionFailed*' })
    }
}

Describe 'ConvertTo-RemoteMailbox' {
    BeforeEach {
        $mailboxes = @{
            'shared'   = Get-TestMailbox -Name 'shared' -Type 'SharedMailbox' -EmailAddresses @(
                'SMTP:shared@contoso.com'
                'smtp:shared@contoso.mail.onmicrosoft.com'
                'X500:/o=Contoso/ou=Exchange/cn=Recipients/cn=shared'
            )
            'room'     = Get-TestMailbox -Name 'room' -Type 'RoomMailbox' -EmailAddresses @(
                'SMTP:room@contoso.com'
                'smtp:room@contoso.mail.onmicrosoft.com'
                'smtp:room@fabrikam.mail.onmicrosoft.com'
            )
            'jdoe'     = Get-TestMailbox -Name 'jdoe' -Type 'UserMailbox' -EmailAddresses @(
                'SMTP:jdoe@contoso.com'
                'smtp:jdoe@contoso.mail.onmicrosoft.com'
            )
            'archived' = Get-TestMailbox -Name 'archived' -Type 'UserMailbox' -EmailAddresses @(
                'SMTP:archived@contoso.com'
                'smtp:archived@contoso.mail.onmicrosoft.com'
            )
            'noroute'  = Get-TestMailbox -Name 'noroute' -Type 'UserMailbox' -EmailAddresses @(
                'SMTP:noroute@contoso.com'
            )
            'discover' = Get-TestMailbox -Name 'discover' -Type 'DiscoveryMailbox' -EmailAddresses @(
                'smtp:discover@contoso.mail.onmicrosoft.com'
            )
        }
        $mailboxes['archived'].ArchiveDatabase = 'DB02'
        Mock -ModuleName $moduleName -CommandName Get-Mailbox -MockWith { $mailboxes[$Identity] }
        Mock -ModuleName $moduleName -CommandName Set-ADUser -MockWith { }
    }

    It 'Rewrites a shared mailbox to a remote shared mailbox, keeping its identity' {
        $result = ConvertTo-RemoteMailbox -Identity 'shared' -Confirm:$false

        $result.PSObject.TypeNames[0] | Should -Be 'ExchangeHybridRecipient.RemoteMailboxConversion'
        $result.RecipientTypeDetails | Should -Be 'RemoteSharedMailbox'
        $result.TargetAddress | Should -BeExactly 'SMTP:shared@contoso.mail.onmicrosoft.com'
        $result.DomainController | Should -Be 'corp.contoso.com'
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Identity -eq $mailboxes['shared'].Guid.ToString() -and
            $Server -eq 'corp.contoso.com' -and
            ($Clear -join ',') -eq 'homeMDB,homeMTA,msExchHomeServerName' -and
            $Replace.msExchRecipientTypeDetails -eq 34359738368 -and
            $Replace.msExchRecipientDisplayType -eq -2147483642 -and
            $Replace.msExchRemoteRecipientType -eq 100 -and
            $Replace.targetAddress -ceq 'SMTP:shared@contoso.mail.onmicrosoft.com'
        }
    }

    It 'Uses -RoutingDomain to pick one address when a mailbox has several routing addresses' {
        $result = ConvertTo-RemoteMailbox -Identity 'room' -RoutingDomain $routingDomain -Confirm:$false

        $result.RecipientTypeDetails | Should -Be 'RemoteRoomMailbox'
        $result.TargetAddress | Should -Be 'SMTP:room@contoso.mail.onmicrosoft.com'
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Replace.msExchRemoteRecipientType -eq 36 -and $Replace.msExchRecipientDisplayType -eq -2147481850
        }
    }

    It 'Refuses ambiguous routing addresses without -RoutingDomain' {
        $conversionParameters = @{
            Identity      = 'room'
            Confirm       = $false
            ErrorVariable = 'conversionErrors'
            ErrorAction   = 'SilentlyContinue'
        }

        $result = ConvertTo-RemoteMailbox @conversionParameters

        $result | Should -BeNullOrEmpty
        (Get-OwnConversionError -ErrorList $conversionErrors)[0].Exception.Message |
            Should -BeLike '*`[2`] addresses*'
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 0 -Exactly
    }

    It 'Writes an error for each mailbox it refuses and converts the rest' {
        $results = 'discover', 'archived', 'noroute', 'jdoe' |
            ConvertTo-RemoteMailbox -Confirm:$false -ErrorVariable conversionErrors -ErrorAction SilentlyContinue

        $results.Identity | Should -Be 'jdoe'
        $results.RecipientTypeDetails | Should -Be 'RemoteUserMailbox'
        $ownErrors = Get-OwnConversionError -ErrorList $conversionErrors
        $ownErrors.TargetObject | Should -Be @('discover', 'archived', 'noroute')
        $ownErrors[0].Exception.Message | Should -BeLike '*DiscoveryMailbox*'
        $ownErrors[1].Exception.Message | Should -BeLike '*on-premises archive*DB02*'
        $ownErrors[2].Exception.Message | Should -BeLike '*`[0`] addresses*'
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 1 -Exactly
    }

    It 'Writes to the server given by -Server' {
        $result = ConvertTo-RemoteMailbox -Identity 'jdoe' -Server 'dc01.corp.contoso.com' -Confirm:$false

        $result.DomainController | Should -Be 'dc01.corp.contoso.com'
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 1 -Exactly -ParameterFilter {
            $Server -eq 'dc01.corp.contoso.com'
        }
    }

    It 'Changes nothing under -WhatIf' {
        $result = ConvertTo-RemoteMailbox -Identity 'shared', 'jdoe' -WhatIf

        $result | Should -BeNullOrEmpty
        Should -Invoke -ModuleName $moduleName -CommandName Set-ADUser -Times 0 -Exactly
    }

    It 'Stops with a clear error when the Exchange or AD cmdlets are missing' {
        Mock -ModuleName $moduleName -CommandName Get-Command -MockWith { } -ParameterFilter {
            $Name -eq 'Set-ADUser'
        }

        { ConvertTo-RemoteMailbox -Identity 'jdoe' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*Set-ADUser*not available*'
    }
}
