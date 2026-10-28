@{
    RootModule           = 'ExchangeHybridRecipient.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '21a022aa-6bd6-4d2f-a6c1-4e7569664288'
    Author               = 'Mike Campbell'
    Description          = 'Exchange hybrid recipient fix-ups, such as converting migrated mailboxes to remote.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    <#
    The Exchange Management Shell cmdlets come from a remote session and the ActiveDirectory module is Windows-only
    RSAT, so neither can be a RequiredModule; ConvertTo-RemoteMailbox checks for them when it runs.
    #>
    RequiredModules      = @()
    FunctionsToExport    = @(
        'ConvertTo-RemoteMailbox'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
