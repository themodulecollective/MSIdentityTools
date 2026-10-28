@{
    RootModule           = 'ADConsistencyGuid.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'e9c35ff1-ae55-414e-b5c4-1b10b6e29260'
    Author               = 'Mike Campbell'
    Description          = 'Read and set mS-DS-ConsistencyGuid, the on-premises source of the Entra ImmutableID.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    <#
    The ActiveDirectory module is Windows-only RSAT, so it cannot be a RequiredModule; both commands check for it
    when they run.
    #>
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Get-ADConsistencyGuid'
        'Set-ADConsistencyGuid'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
