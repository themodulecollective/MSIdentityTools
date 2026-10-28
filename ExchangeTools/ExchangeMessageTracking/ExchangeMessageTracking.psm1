#requires -Version 7.0

<#
One field of a protocol log line: either a double-quoted value (with "" as an escaped quote, and commas allowed)
or an unquoted run up to the next comma.
#>
$script:ProtocolLogFieldPattern = [regex]::new('(?<=^|,)("(?:[^"]|"")*"|[^,]*)', 'Compiled')


function ConvertFrom-ProtocolLogClientAddress {
    <#
    .SYNOPSIS
        Strips the port from a protocol log's cIp value, leaving the client IP address.
    .EXAMPLE
        ConvertFrom-ProtocolLogClientAddress -Address '[2001:db8::5]:50112'

        Returns '2001:db8::5'. '10.0.0.5:50112' returns '10.0.0.5'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The cIp value, such as 10.0.0.5:50112 or [2001:db8::5]:50112.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Address
    )

    switch -Regex ($Address) {
        '^\[(?<Ip>.+)\]:\d+$' {
            $Matches.Ip
            break
        }
        # A single colon means IPv4 with a port; bare IPv6 has several colons and no port to strip.
        '^(?<Ip>[^:]+):\d+$' {
            $Matches.Ip
            break
        }
        default {
            $Address
        }
    }
}


function Get-ExchangeProtocolLogClient {
    <#
    .SYNOPSIS
        Summarizes which users connect with POP3 or IMAP4, and from which client IP addresses, from Exchange
        protocol logs.
    .DESCRIPTION
        Before disabling POP3 or IMAP4, or decommissioning the servers that offer them, you need to know who still
        uses them. With protocol logging enabled (Set-PopSettings / Set-ImapSettings -ProtocolLogEnabled $true),
        each Exchange server writes CSV logs of every session. This command reads those logs and returns one row
        per protocol, user, and client IP address, with when they were first and last seen and how many sessions
        they made.

        Each file's #Log-type header identifies the protocol, and its #Fields header locates the columns, so it
        does not depend on column positions. Files are read line by line and only the summary is kept in memory, so
        large log folders are fine; the logs themselves are never changed. Results are emitted once every file has
        been read. A file that cannot be read or is not a protocol log produces a non-terminating error and the
        rest are still read.

        Lines with no user, from sessions that never authenticated, are skipped. SessionCount is the number of
        distinct session IDs per log file, added up across files, so a session that spans a log rollover counts
        twice.
    .INPUTS
        System.String, or file objects from Get-ChildItem.
    .OUTPUTS
        ExchangeMessageTracking.ProtocolLogClient
    .EXAMPLE
        Get-ExchangeProtocolLogClient -Path '\\EX01\d$\Exchange\Logging\Pop3', '\\EX02\d$\Exchange\Logging\Pop3'

        Summarizes POP3 use from two servers' log folders, read in place over their admin shares.
    .EXAMPLE
        Get-ChildItem -Path 'D:\Investigation\ProtocolLogs' -Filter '*.log' -Recurse |
            Get-ExchangeProtocolLogClient |
            Sort-Object -Property LastSeen -Descending |
            Export-Csv -Path 'D:\Investigation\PopImapClients.csv'

        Summarizes a folder of collected POP3 and IMAP4 logs, most recently active first, and saves the report.
    #>
    [CmdletBinding()]
    [OutputType('ExchangeMessageTracking.ProtocolLogClient')]
    param(
        # Log files or folders to read. Wildcards are allowed; a folder means the files directly in it.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    begin {
        $client = @{}
    }

    process {
        foreach ($inputPath in $Path) {
            try {
                $logFile = @(Get-ChildItem -Path $inputPath -File -ErrorAction Stop)
            }
            catch {
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $PSItem.Exception,
                        'ProtocolLogPathNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $inputPath
                    )
                )
                continue
            }

            foreach ($file in $logFile) {
                Write-Verbose -Message "Reading [$($file.FullName)]"
                $protocol = 'Unknown'
                $column = $null
                $sessionSeen = [System.Collections.Generic.HashSet[string]]::new()
                try {
                    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
                        if ($line.StartsWith('#')) {
                            if ($line -match '^#Log-type:\s*(?<Protocol>\S+)') {
                                $protocol = $Matches.Protocol
                            }
                            elseif ($line.StartsWith('#Fields:')) {
                                $fieldName = $line.Substring(8).Trim() -split ','
                                $column = @{}
                                for ($i = 0; $i -lt $fieldName.Count; $i++) {
                                    $column[$fieldName[$i].Trim()] = $i
                                }
                                foreach ($required in 'dateTime', 'sessionId', 'cIp', 'user') {
                                    if (-not $column.ContainsKey($required)) {
                                        throw [System.IO.InvalidDataException]::new(
                                            "The #Fields header has no [$required] column."
                                        )
                                    }
                                }
                            }
                            continue
                        }
                        if ([string]::IsNullOrWhiteSpace($line)) {
                            continue
                        }
                        if ($null -eq $column) {
                            throw [System.IO.InvalidDataException]::new(
                                'Data comes before any #Fields header, so this is not an Exchange protocol log.'
                            )
                        }

                        $value = $script:ProtocolLogFieldPattern.Matches($line).ForEach({
                                $field = $_.Value
                                if ($field.StartsWith('"')) {
                                    $field.Substring(1, $field.Length - 2).Replace('""', '"')
                                }
                                else {
                                    $field
                                }
                            })

                        $user = $value[$column.user]
                        if ([string]::IsNullOrWhiteSpace($user)) {
                            continue
                        }
                        $clientIp = ConvertFrom-ProtocolLogClientAddress -Address $value[$column.cIp]
                        $key = "$protocol|$user|$clientIp"

                        $timestamp = [datetime]::MinValue
                        $hasTimestamp = [datetime]::TryParse(
                            $value[$column.dateTime],
                            [cultureinfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AdjustToUniversal,
                            [ref]$timestamp
                        )

                        $entry = $client[$key]
                        if ($null -eq $entry) {
                            $entry = [PSCustomObject]@{
                                PSTypeName   = 'ExchangeMessageTracking.ProtocolLogClient'
                                Protocol     = $protocol
                                User         = $user
                                ClientIp     = $clientIp
                                FirstSeen    = $null
                                LastSeen     = $null
                                SessionCount = 0
                            }
                            $client[$key] = $entry
                        }
                        if ($hasTimestamp) {
                            if ($null -eq $entry.FirstSeen -or $timestamp -lt $entry.FirstSeen) {
                                $entry.FirstSeen = $timestamp
                            }
                            if ($null -eq $entry.LastSeen -or $timestamp -gt $entry.LastSeen) {
                                $entry.LastSeen = $timestamp
                            }
                        }
                        if ($sessionSeen.Add("$key|$($value[$column.sessionId])")) {
                            $entry.SessionCount++
                        }
                    }
                }
                catch {
                    $readError = $PSItem
                    $PSCmdlet.WriteError(
                        [System.Management.Automation.ErrorRecord]::new(
                            $readError.Exception,
                            'ProtocolLogReadFailed',
                            [System.Management.Automation.ErrorCategory]::ReadError,
                            $file.FullName
                        )
                    )
                }
            }
        }
    }

    end {
        $client.Values
    }
}


function Get-RedirectedMessage {
    <#
    .SYNOPSIS
        Finds messages that Exchange redirected away from their intended recipient, and where each one went.
    .DESCRIPTION
        When Exchange delivers a message to someone other than the addressed recipient, for example because the
        recipient has a forwarding address (altRecipient) set, the transport service logs a REDIRECT event. On that
        event, Recipients holds the address the sender used and RelatedRecipientAddress holds the address the
        message went to instead.

        This command reads the REDIRECT events once from each transport server and keeps the ones that match:
          - -RedirectedTo answers "why is this mailbox getting mail meant for someone else?"
          - -IntendedRecipient answers "where did mail sent to this person actually go?"

        Addresses are matched without regard to case. Each server is queried once for the whole search, no matter
        how many addresses are given, so the addresses are collected from the pipeline first and the results are
        emitted at the end.

        Get-MessageTrackingLog searches only one server unless it is given one, so by default this command
        searches every transport service in the organization (Get-TransportService). A server that cannot be
        searched produces a non-terminating error and the others are still searched.

        Requires the on-premises Exchange Management Shell cmdlets, without a cmdlet prefix. Exchange Online has no
        message tracking logs; use message trace there instead.
    .INPUTS
        System.String
    .OUTPUTS
        ExchangeMessageTracking.RedirectedMessage
    .EXAMPLE
        Get-RedirectedMessage -RedirectedTo 'jdoe@contoso.mail.onmicrosoft.com' -Start (Get-Date).AddDays(-7)

        Lists the messages from the last 7 days that were redirected to that address, with the address each one
        was actually sent to.
    .EXAMPLE
        Get-RedirectedMessage -IntendedRecipient 'jdoe@contoso.com' -Server 'EX01', 'EX02'

        Shows where mail addressed to Jane Doe was redirected, searching only two transport servers.
    .EXAMPLE
        Get-Content -Path 'D:\Investigation\UnexpectedRecipients.txt' |
            Get-RedirectedMessage -Start '2026-10-01' |
            Select-Object -Property Timestamp, Sender, Subject, RedirectedTo,
                @{ Name = 'IntendedRecipient'; Expression = { $_.IntendedRecipient -join ';' } } |
            Export-Csv -Path 'D:\Investigation\RedirectedMessages.csv'

        Checks a list of addresses that received mail they should not have and saves a report, joining the
        intended recipients into one column for the CSV.
    #>
    [CmdletBinding(DefaultParameterSetName = 'RedirectedTo')]
    [OutputType('ExchangeMessageTracking.RedirectedMessage')]
    param(
        # Addresses that received redirected mail. Matches each REDIRECT event's RelatedRecipientAddress.
        [Parameter(Mandatory, ParameterSetName = 'RedirectedTo', ValueFromPipeline,
            ValueFromPipelineByPropertyName)]
        [Alias('PrimarySmtpAddress')]
        [ValidateNotNullOrEmpty()]
        [string[]]$RedirectedTo,

        # Addresses that mail was sent to before Exchange redirected it. Matches each REDIRECT event's Recipients.
        [Parameter(Mandatory, ParameterSetName = 'IntendedRecipient', ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$IntendedRecipient,

        # Start of the search window. Defaults to the oldest entry in each server's tracking logs.
        [datetime]$Start,

        # End of the search window. Defaults to now.
        [datetime]$End,

        # Transport servers to search. Defaults to every transport service in the organization.
        [ValidateNotNullOrEmpty()]
        [string[]]$Server
    )

    begin {
        $requiredCommand = @('Get-MessageTrackingLog')
        if (-not $PSBoundParameters.ContainsKey('Server')) {
            $requiredCommand += 'Get-TransportService'
        }
        foreach ($commandName in $requiredCommand) {
            if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.Management.Automation.CommandNotFoundException]::new(
                            "[$commandName] is not available. Run this from an on-premises Exchange Management " +
                            'Shell session without a cmdlet prefix.'
                        ),
                        'RequiredCommandNotFound',
                        [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                        $commandName
                    )
                )
            }
        }

        $searchAddress = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    }

    process {
        $address = if ($PSCmdlet.ParameterSetName -eq 'RedirectedTo') { $RedirectedTo } else { $IntendedRecipient }
        foreach ($a in $address) {
            $null = $searchAddress.Add($a)
        }
    }

    end {
        $searchServer = if ($PSBoundParameters.ContainsKey('Server')) {
            $Server
        }
        else {
            try {
                @(Get-TransportService -ErrorAction Stop).ForEach({ [string]$_.Name })
            }
            catch {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $PSItem.Exception,
                        'TransportServiceLookupFailed',
                        [System.Management.Automation.ErrorCategory]::ConnectionError,
                        $null
                    )
                )
            }
        }

        $trackingLogParameters = @{
            EventId     = 'REDIRECT'
            ResultSize  = 'Unlimited'
            ErrorAction = 'Stop'
        }
        foreach ($name in 'Start', 'End') {
            if ($PSBoundParameters.ContainsKey($name)) {
                $trackingLogParameters[$name] = $PSBoundParameters[$name]
            }
        }

        foreach ($serverName in $searchServer) {
            Write-Verbose -Message "Reading REDIRECT events from [$serverName]"
            try {
                $redirectEvent = @(Get-MessageTrackingLog @trackingLogParameters -Server $serverName)
            }
            catch {
                $searchError = $PSItem
                $PSCmdlet.WriteError(
                    [System.Management.Automation.ErrorRecord]::new(
                        $searchError.Exception,
                        'MessageTrackingSearchFailed',
                        [System.Management.Automation.ErrorCategory]::ReadError,
                        $serverName
                    )
                )
                continue
            }

            foreach ($trackingEvent in $redirectEvent) {
                $intended = @($trackingEvent.Recipients).ForEach({ [string]$_ })
                $redirectedAddress = [string]$trackingEvent.RelatedRecipientAddress

                $isMatch = if ($PSCmdlet.ParameterSetName -eq 'RedirectedTo') {
                    $searchAddress.Contains($redirectedAddress)
                }
                else {
                    $intended.Where({ $searchAddress.Contains($_) }, 'First').Count -gt 0
                }

                if ($isMatch) {
                    [PSCustomObject]@{
                        PSTypeName        = 'ExchangeMessageTracking.RedirectedMessage'
                        Timestamp         = $trackingEvent.Timestamp
                        Server            = [string]$trackingEvent.ServerHostname
                        MessageId         = [string]$trackingEvent.MessageId
                        Sender            = [string]$trackingEvent.Sender
                        ReturnPath        = [string]$trackingEvent.ReturnPath
                        Subject           = [string]$trackingEvent.MessageSubject
                        IntendedRecipient = $intended
                        RedirectedTo      = $redirectedAddress
                    }
                }
            }
        }
    }
}
