#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Offline smoke tests. The Exchange cmdlets are replaced with stubs and mocks, so Exchange is not needed to run
    them.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll/BeforeEach are read in It blocks, which the analyzer cannot see.'
)]
param()

BeforeAll {
    # Pester can only mock commands that exist, so stand in for them when the real ones are not installed.
    if ($null -eq (Get-Command -Name Get-MessageTrackingLog -ErrorAction SilentlyContinue)) {
        function global:Get-MessageTrackingLog {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [CmdletBinding()]
            param($Server, $EventId, $ResultSize, $Start, $End)
        }
    }
    if ($null -eq (Get-Command -Name Get-TransportService -ErrorAction SilentlyContinue)) {
        function global:Get-TransportService {
            [CmdletBinding()]
            param()
        }
    }

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ExchangeMessageTracking.psd1') -Force
    $moduleName = 'ExchangeMessageTracking'

    function Get-TestRedirectEvent {
        param(
            [string]$Server,
            [string[]]$Recipients,
            [string]$RelatedRecipientAddress,
            [string]$Subject = 'Quarterly numbers'
        )

        [PSCustomObject]@{
            Timestamp               = [datetime]'2026-10-15T09:30:00'
            ServerHostname          = $Server
            EventId                 = 'REDIRECT'
            MessageId               = "<$([guid]::NewGuid())@contoso.com>"
            Sender                  = 'sender@fabrikam.com'
            ReturnPath              = 'sender@fabrikam.com'
            MessageSubject          = $Subject
            Recipients              = $Recipients
            RelatedRecipientAddress = $RelatedRecipientAddress
        }
    }
}

Describe 'Get-ExchangeProtocolLogClient' {
    BeforeAll {
        function Write-TestProtocolLog {
            param(
                [string]$Path,
                [string]$Protocol,
                [string[]]$Line
            )

            $header = @(
                '#Software: Microsoft Exchange Server'
                '#Version: 15.02.1544.004'
                "#Log-type: $Protocol Protocol Logs"
                '#Date: 2026-10-15T00:00:00.000Z'
                '#Fields: dateTime,sessionId,seqNumber,sIp,cIp,user,duration,rqsize,rpsize,command,parameters,' +
                    'context'
            )
            Set-Content -LiteralPath $Path -Value ($header + $Line)
        }
    }

    BeforeEach {
        $logFolder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        $null = New-Item -Path $logFolder -ItemType Directory

        # Each line: dateTime, sessionId, seqNumber, then the server and client addresses, then the rest.
        $popServer = '10.0.0.10:995'
        $popLogParameters = @{
            Path     = Join-Path -Path $logFolder -ChildPath 'POP3.log'
            Protocol = 'POP3'
            Line     = @(
                "2026-10-15T08:00:00.000Z,11,1,$popServer,10.1.1.5:50112,,0,0,0,OpenSession,,"
                "2026-10-15T08:00:01.000Z,11,2,$popServer,10.1.1.5:50112,jdoe@contoso.com,5,10,20,USER,jdoe,"
                "2026-10-15T08:00:02.000Z,11,3,$popServer,10.1.1.5:50112,jdoe@contoso.com,5,10,20,RETR,1," +
                    '"R=ok, size=12"'
                "2026-10-15T17:30:00.000Z,12,1,$popServer,10.1.1.5:50999,JDOE@contoso.com,5,10,20,USER,jdoe,"
                "2026-10-15T12:00:00.000Z,13,1,$popServer,[2001:db8::5]:50200,asmith@contoso.com,5,10,20,USER,,"
            )
        }
        Write-TestProtocolLog @popLogParameters
        Write-TestProtocolLog -Path (Join-Path -Path $logFolder -ChildPath 'IMAP4.log') -Protocol 'IMAP4' -Line @(
            '2026-10-14T09:00:00.000Z,21,1,10.0.0.11:993,10.1.1.5:51000,jdoe@contoso.com,5,10,20,LOGIN,,'
        )
    }

    It 'returns one row per protocol, user, and client IP, with first/last seen and session count' {
        $result = @(Get-ExchangeProtocolLogClient -Path $logFolder)

        $result.Count | Should -Be 3
        $pop = $result.Where({ $_.Protocol -eq 'POP3' -and $_.User -eq 'jdoe@contoso.com' })[0]
        $pop.ClientIp | Should -Be '10.1.1.5'
        $pop.SessionCount | Should -Be 2
        $pop.FirstSeen | Should -Be ([datetime]'2026-10-15T08:00:01Z').ToUniversalTime()
        $pop.LastSeen | Should -Be ([datetime]'2026-10-15T17:30:00Z').ToUniversalTime()
        $pop.PSObject.TypeNames | Should -Contain 'ExchangeMessageTracking.ProtocolLogClient'
    }

    It 'strips the port from IPv6 client addresses and keeps protocols apart' {
        $result = @(Get-ExchangeProtocolLogClient -Path $logFolder)

        $result.Where({ $_.User -eq 'asmith@contoso.com' })[0].ClientIp | Should -Be '2001:db8::5'
        $result.Where({ $_.Protocol -eq 'IMAP4' }).Count | Should -Be 1
    }

    It 'accepts files piped from Get-ChildItem' {
        $result = @(Get-ChildItem -Path $logFolder -Filter 'IMAP4.log' | Get-ExchangeProtocolLogClient)

        $result.Count | Should -Be 1
        $result[0].Protocol | Should -Be 'IMAP4'
    }

    It 'reports a file that is not a protocol log and still reads the rest' {
        Set-Content -LiteralPath (Join-Path -Path $logFolder -ChildPath 'notes.txt') -Value 'just some text'

        $readParameters = @{
            Path          = $logFolder
            ErrorVariable = 'readErrors'
            ErrorAction   = 'SilentlyContinue'
        }
        $result = @(Get-ExchangeProtocolLogClient @readParameters)

        $result.Count | Should -Be 3
        $ownErrors = $readErrors.Where({ $_.FullyQualifiedErrorId -like 'ProtocolLogReadFailed*' })
        $ownErrors.Count | Should -Be 1
        $ownErrors[0].TargetObject | Should -BeLike '*notes.txt'
    }
}

Describe 'Get-RedirectedMessage' {
    BeforeEach {
        $eventsByServer = @{
            'EX01' = @(
                Get-TestRedirectEvent -Server 'EX01' -Recipients 'jdoe@contoso.com' -RelatedRecipientAddress (
                    'jdoe@contoso.mail.onmicrosoft.com'
                )
                Get-TestRedirectEvent -Server 'EX01' -Recipients 'asmith@contoso.com' -RelatedRecipientAddress (
                    'archive@contoso.com'
                )
            )
            'EX02' = @(
                Get-TestRedirectEvent -Server 'EX02' -Recipients 'jdoe@contoso.com', 'team@contoso.com' -Subject (
                    'Second server'
                ) -RelatedRecipientAddress 'JDOE@CONTOSO.MAIL.ONMICROSOFT.COM'
            )
        }

        Mock -CommandName Get-TransportService -ModuleName $moduleName -MockWith {
            [PSCustomObject]@{ Name = 'EX01' }
            [PSCustomObject]@{ Name = 'EX02' }
        }
        Mock -CommandName Get-MessageTrackingLog -ModuleName $moduleName -MockWith {
            $eventsByServer[$Server]
        }
    }

    It 'finds messages redirected to an address on every transport server, ignoring case' {
        $result = @(Get-RedirectedMessage -RedirectedTo 'jdoe@contoso.mail.onmicrosoft.com')

        $result.Count | Should -Be 2
        $result.Server | Should -Be 'EX01', 'EX02'
        $result[0].IntendedRecipient | Should -Be 'jdoe@contoso.com'
        $result[0].RedirectedTo | Should -Be 'jdoe@contoso.mail.onmicrosoft.com'
        $result[0].PSObject.TypeNames | Should -Contain 'ExchangeMessageTracking.RedirectedMessage'
        Should -Invoke -CommandName Get-MessageTrackingLog -ModuleName $moduleName -Times 2 -Exactly
    }

    It 'finds where mail for an intended recipient went, including multi-recipient messages' {
        $result = @(Get-RedirectedMessage -IntendedRecipient 'team@contoso.com')

        $result.Count | Should -Be 1
        $result[0].Subject | Should -Be 'Second server'
        $result[0].IntendedRecipient | Should -Be 'jdoe@contoso.com', 'team@contoso.com'
    }

    It 'collects piped addresses and queries each server only once' {
        $result = @('jdoe@contoso.mail.onmicrosoft.com', 'archive@contoso.com' | Get-RedirectedMessage)

        $result.Count | Should -Be 3
        Should -Invoke -CommandName Get-MessageTrackingLog -ModuleName $moduleName -Times 2 -Exactly
    }

    It 'searches only the named servers and passes the time window through' {
        $start = [datetime]'2026-10-01'
        $end = [datetime]'2026-10-20'

        $null = Get-RedirectedMessage -RedirectedTo 'archive@contoso.com' -Server 'EX01' -Start $start -End $end

        Should -Invoke -CommandName Get-TransportService -ModuleName $moduleName -Times 0 -Exactly
        $invokeParameters = @{
            CommandName     = 'Get-MessageTrackingLog'
            ModuleName      = $moduleName
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Server -eq 'EX01' -and $EventId -eq 'REDIRECT' -and $ResultSize -eq 'Unlimited' -and
                $Start -eq $start -and $End -eq $end
            }
        }
        Should -Invoke @invokeParameters
    }

    It 'reports a server that cannot be searched and still searches the rest' {
        $mockParameters = @{
            CommandName     = 'Get-MessageTrackingLog'
            ModuleName      = $moduleName
            ParameterFilter = { $Server -eq 'EX01' }
            MockWith        = { throw [System.InvalidOperationException]::new('The server is unavailable.') }
        }
        Mock @mockParameters

        $searchParameters = @{
            RedirectedTo  = 'jdoe@contoso.mail.onmicrosoft.com'
            ErrorVariable = 'searchErrors'
            ErrorAction   = 'SilentlyContinue'
        }
        $result = @(Get-RedirectedMessage @searchParameters)

        $result.Count | Should -Be 1
        $result[0].Server | Should -Be 'EX02'
        $ownErrors = $searchErrors.Where({ $_.FullyQualifiedErrorId -like 'MessageTrackingSearchFailed*' })
        $ownErrors.Count | Should -Be 1
        $ownErrors[0].TargetObject | Should -Be 'EX01'
    }

    It 'stops with a clear error when the Exchange cmdlets are not loaded' {
        Mock -CommandName Get-Command -ModuleName $moduleName -MockWith { $null }

        { Get-RedirectedMessage -RedirectedTo 'jdoe@contoso.com' -ErrorAction Stop } |
            Should -Throw -ErrorId 'RequiredCommandNotFound*'
    }
}
