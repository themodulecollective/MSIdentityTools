#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Offline smoke tests: every Graph cmdlet is mocked, so no tenant or connection is needed.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll/BeforeEach are read in It blocks, which the analyzer cannot see.'
)]
param()

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\EntraAppInventory.psd1') -Force
    $moduleName = 'EntraAppInventory'
    $registrationAppId = '11111111-1111-1111-1111-111111111111'
    $enterpriseAppId = '22222222-2222-2222-2222-222222222222'

    Mock -ModuleName $moduleName -CommandName Get-MgContext -MockWith {
        [PSCustomObject]@{ TenantId = 'tenant' }
    }

    Mock -ModuleName $moduleName -CommandName Get-MgApplication -MockWith {
        [PSCustomObject]@{
            Id                     = 'a1'
            AppId                  = '11111111-1111-1111-1111-111111111111'
            DisplayName            = 'HR [Prod]: Payroll'
            Api                    = [PSCustomObject]@{
                Oauth2PermissionScopes = @([PSCustomObject]@{ Value = 'read' })
            }
            RequiredResourceAccess = @()
            PasswordCredentials    = @(
                [PSCustomObject]@{ DisplayName = 'secret'; KeyId = 'k1'; EndDateTime = [datetime]'2027-01-01' }
            )
            KeyCredentials         = @(
                [PSCustomObject]@{
                    DisplayName = 'cert'
                    KeyId       = 'k2'
                    Usage       = 'Verify'
                    EndDateTime = [datetime]'2026-12-01'
                }
            )
        }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgApplicationOwner -MockWith {
        [PSCustomObject]@{
            Id                   = 'o1'
            AdditionalProperties = @{
                '@odata.type'     = '#microsoft.graph.user'
                displayName       = 'Jane Doe'
                userPrincipalName = 'jdoe@contoso.com'
            }
        }
        [PSCustomObject]@{
            Id                   = 'o2'
            AdditionalProperties = @{
                '@odata.type' = '#microsoft.graph.servicePrincipal'
                displayName   = 'Automation SP'
            }
        }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgApplicationFederatedIdentityCredential -MockWith {
        throw 'Forbidden'
    }

    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipal -MockWith {
        [PSCustomObject]@{
            Id                        = 's1'
            AppId                     = '22222222-2222-2222-2222-222222222222'
            DisplayName               = 'Saml App'
            PreferredSingleSignOnMode = 'saml'
            AppRoleAssignmentRequired = $false
            PasswordCredentials       = $null
            KeyCredentials            = $null
        }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgIdentityConditionalAccessPolicy -MockWith {
        [PSCustomObject]@{
            DisplayName = 'Require MFA'
            Conditions  = [PSCustomObject]@{
                Applications = [PSCustomObject]@{ IncludeApplications = @('22222222-2222-2222-2222-222222222222') }
            }
        }
        [PSCustomObject]@{
            DisplayName = 'All apps'
            Conditions  = [PSCustomObject]@{
                Applications = [PSCustomObject]@{ IncludeApplications = @('All') }
            }
        }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipalOwner -MockWith { }
    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipalAppRoleAssignedTo -MockWith {
        [PSCustomObject]@{ PrincipalDisplayName = 'Group 1' }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipalMemberOf -MockWith { }
    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipalOauth2PermissionGrant -MockWith { }
    Mock -ModuleName $moduleName -CommandName Get-MgServicePrincipalAppRoleAssignment -MockWith { }
    # A single job, to prove the @() wrapping stops a lone hashtable from being counted by its keys.
    Mock -ModuleName $moduleName -CommandName Invoke-MgGraphRequest -MockWith {
        @{ value = @(@{ id = 'job1'; status = 'Active' }) }
    }
}

Describe 'Get-EntraAppRegistrationInventory' {
    BeforeAll {
        $record = Get-EntraAppRegistrationInventory -WarningVariable lookupWarnings -WarningAction SilentlyContinue
    }

    It 'Emits a typed summary record' {
        $record.PSObject.TypeNames[0] | Should -Be 'EntraAppInventory.AppRegistration'
        $record.AppId | Should -Be $registrationAppId
        $record.Owners | Should -Be 'jdoe@contoso.com;Automation SP'
        $record.SecretCount | Should -Be 1
        $record.CertificateCount | Should -Be 1
        $record.CredentialExpiresSoonest | Should -Be ([datetime]'2026-12-01')
        $record.ExposesApi | Should -BeTrue
        $record.HasApiPermissions | Should -BeFalse
    }

    It 'Records a failed lookup without losing the record' {
        $record.LookupErrorCount | Should -Be 1
        $record.Detail.LookupErrors[0] | Should -BeLike '*FederatedCredentials*Forbidden*'
        $lookupWarnings.Count | Should -Be 1
    }

    It 'Keeps non-user owners' {
        $record.Detail.Owners[1].ObjectType | Should -Be 'servicePrincipal'
    }
}

Describe 'Get-EntraEnterpriseAppInventory' {
    It 'Summarizes SSO, assignments, provisioning, and directly-targeted CA policies' {
        $record = Get-EntraEnterpriseAppInventory

        $record.AppId | Should -Be $enterpriseAppId
        $record.ConditionalAccessPolicies | Should -Be 'Require MFA'
        $record.HasProvisioning | Should -BeTrue
        $record.Detail.ProvisioningJobs.Count | Should -Be 1
        $record.AssignedPrincipalCount | Should -Be 1
        $record.SecretCount | Should -Be 0
        $record.CredentialExpiresSoonest | Should -BeNullOrEmpty
        $record.SsoMode | Should -Be 'saml'
        $record.LookupErrorCount | Should -Be 0
    }

    It 'Records a tenant-wide Conditional Access failure on every record' {
        Mock -ModuleName $moduleName -CommandName Get-MgIdentityConditionalAccessPolicy -MockWith {
            throw 'Missing Policy.Read.All'
        }

        $record = Get-EntraEnterpriseAppInventory -WarningAction SilentlyContinue

        $record.LookupErrorCount | Should -Be 1
        $record.Detail.LookupErrors[0] | Should -BeLike '*tenant*Missing Policy.Read.All*'
    }
}

Describe 'Export-EntraAppInventory' {
    It 'Writes one CSV per record type and one JSON file per app' {
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'out'

        $files = & {
            Get-EntraAppRegistrationInventory -WarningAction SilentlyContinue
            Get-EntraEnterpriseAppInventory
        } | Export-EntraAppInventory -Path $outputPath

        $files.Name | Sort-Object | Should -Be @('AppRegistration-Summary.csv', 'EnterpriseApp-Summary.csv')
        $row = Import-Csv -LiteralPath (Join-Path -Path $outputPath -ChildPath 'AppRegistration-Summary.csv')
        $row.PSObject.Properties.Name | Should -Not -Contain 'Detail'
        $row.DetailFile | Should -Be "AppRegistration\$registrationAppId-HR _Prod__ Payroll.json"
        $detailPath = Join-Path -Path $outputPath -ChildPath $row.DetailFile
        $detail = Get-Content -LiteralPath $detailPath -Raw | ConvertFrom-Json
        $detail.BasicInfo.DisplayName | Should -Be 'HR [Prod]: Payroll'
        Join-Path -Path $outputPath -ChildPath 'EnterpriseApp' | Should -Exist
    }

    It 'Writes nothing under -WhatIf' {
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'whatif'

        Get-EntraAppRegistrationInventory -WarningAction SilentlyContinue |
            Export-EntraAppInventory -Path $outputPath -WhatIf

        $outputPath | Should -Not -Exist
    }

    It 'Rejects input that did not come from this module' {
        { [PSCustomObject]@{ Name = 'x' } | Export-EntraAppInventory -Path $TestDrive -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Get-Entra*Inventory*'
    }
}

Describe 'Graph connection guard' {
    It 'Throws a clear error when not connected' {
        Mock -ModuleName $moduleName -CommandName Get-MgContext -MockWith { }

        { Get-EntraAppRegistrationInventory } | Should -Throw -ExpectedMessage '*Connect-MgGraph*'
    }
}
