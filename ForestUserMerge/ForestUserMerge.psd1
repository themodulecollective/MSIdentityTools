@{
    RootModule           = 'ForestUserMerge.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'da17149e-f455-4a47-a55b-b19d775f1f6c'
    Author               = 'Mike Campbell'
    Description          = 'Plans merging a person''s legacy-forest user into their target-forest user.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')
    # The planner works only on objects it is given, so it needs no other modules.
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Get-ForestUserMergePlan'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
