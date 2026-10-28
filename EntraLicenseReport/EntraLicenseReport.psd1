@{
    RootModule           = 'EntraLicenseReport.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6504516e-6125-48d1-80ed-6f359c6275c4'
    Author               = 'Mike Campbell'
    Description          = 'Reports Microsoft 365 license SKU availability and per-user license assignments.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    RequiredModules      = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.0.0' }
        @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; ModuleVersion = '2.0.0' }
        @{ ModuleName = 'Microsoft.Graph.Users'; ModuleVersion = '2.0.0' }
    )
    FunctionsToExport    = @(
        'Get-EntraLicenseAvailability'
        'Get-EntraUserLicenseAssignment'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
