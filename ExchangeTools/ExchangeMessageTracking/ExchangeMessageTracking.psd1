@{
    RootModule           = 'ExchangeMessageTracking.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '9a2b03f6-afda-4ac6-a7da-96f30c3f7bcc'
    Author               = 'Mike Campbell'
    Description          = 'On-premises Exchange log investigations: redirected mail and POP3/IMAP4 client use.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    <#
    The Exchange Management Shell cmdlets come from a remote session, so they cannot be a RequiredModule;
    Get-RedirectedMessage checks for them when it runs.
    Get-ExchangeProtocolLogClient only reads log files and needs no Exchange cmdlets.
    #>
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Get-ExchangeProtocolLogClient'
        'Get-RedirectedMessage'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
