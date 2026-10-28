@{
    RootModule           = 'EntraAppInventory.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '309725b7-8102-42dd-a08c-012126575cdc'
    Author               = 'Mike Campbell'
    Description          = 'Inventories Entra ID app registrations and enterprise applications to CSV and JSON.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    RequiredModules      = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
        @{ ModuleName = 'Microsoft.Graph.Applications'; ModuleVersion = '2.0.0' }
        @{ ModuleName = 'Microsoft.Graph.Identity.SignIns'; ModuleVersion = '2.0.0' }
    )
    FunctionsToExport    = @(
        'Get-EntraAppRegistrationInventory'
        'Get-EntraEnterpriseAppInventory'
        'Export-EntraAppInventory'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
