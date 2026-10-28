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
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\EntraLicenseReport.psd1') -Force
    $moduleName = 'EntraLicenseReport'
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Scripts\Invoke-LicenseAvailabilityCheck.ps1'
    $e3SkuId = '6fd2c87f-b296-42f0-b197-1e91e994b900'
    $e5SkuId = 'c7df2760-2c81-4ef7-b578-5b5392b571df'
    $removedSkuId = '99999999-9999-9999-9999-999999999999'
    $licenseGroupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

    Mock -ModuleName $moduleName -CommandName Get-MgContext -MockWith {
        [PSCustomObject]@{ TenantId = 'tenant' }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgSubscribedSku -MockWith {
        [PSCustomObject]@{
            SkuId            = '6fd2c87f-b296-42f0-b197-1e91e994b900'
            SkuPartNumber    = 'ENTERPRISEPACK'
            CapabilityStatus = 'Enabled'
            ConsumedUnits    = 180
            PrepaidUnits     = [PSCustomObject]@{ Enabled = 200; Warning = 0; Suspended = 0; LockedOut = 0 }
        }
        [PSCustomObject]@{
            SkuId            = 'c7df2760-2c81-4ef7-b578-5b5392b571df'
            SkuPartNumber    = 'ENTERPRISEPREMIUM'
            CapabilityStatus = 'Enabled'
            ConsumedUnits    = 10
            PrepaidUnits     = [PSCustomObject]@{ Enabled = 50; Warning = 5; Suspended = 0; LockedOut = 0 }
        }
    }
    Mock -ModuleName $moduleName -CommandName Get-MgUser -MockWith {
        # Holds E3 both directly and from a group (with a group-licensing error), plus a SKU no longer subscribed.
        [PSCustomObject]@{
            Id                      = 'u1'
            DisplayName             = 'Jane Doe'
            UserPrincipalName       = 'jdoe@contoso.com'
            AccountEnabled          = $true
            AssignedLicenses        = @(
                [PSCustomObject]@{ SkuId = '6fd2c87f-b296-42f0-b197-1e91e994b900' }
                [PSCustomObject]@{ SkuId = '99999999-9999-9999-9999-999999999999' }
            )
            LicenseAssignmentStates = @(
                [PSCustomObject]@{
                    SkuId           = '6fd2c87f-b296-42f0-b197-1e91e994b900'
                    AssignedByGroup = $null
                    State           = 'Active'
                    Error           = 'None'
                }
                [PSCustomObject]@{
                    SkuId           = '6fd2c87f-b296-42f0-b197-1e91e994b900'
                    AssignedByGroup = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    State           = 'Error'
                    Error           = 'CountViolation'
                }
            )
        }
        [PSCustomObject]@{
            Id                      = 'u2'
            DisplayName             = 'John Smith'
            UserPrincipalName       = 'jsmith@contoso.com'
            AccountEnabled          = $false
            AssignedLicenses        = @([PSCustomObject]@{ SkuId = 'c7df2760-2c81-4ef7-b578-5b5392b571df' })
            LicenseAssignmentStates = @(
                [PSCustomObject]@{
                    SkuId           = 'c7df2760-2c81-4ef7-b578-5b5392b571df'
                    AssignedByGroup = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    State           = 'Active'
                    Error           = 'None'
                }
            )
        }
    }
}

Describe 'Get-EntraLicenseAvailability' {
    It 'Computes available units per SKU, sorted by part number' {
        $skus = Get-EntraLicenseAvailability

        $skus.SkuPartNumber | Should -Be @('ENTERPRISEPACK', 'ENTERPRISEPREMIUM')
        $skus[0].PSObject.TypeNames[0] | Should -Be 'EntraLicenseReport.SkuAvailability'
        $skus[0].AvailableUnits | Should -Be 20
        $skus[1].WarningUnits | Should -Be 5
    }

    It 'Filters to the requested SKUs and warns about unknown ones' {
        $availabilityParameters = @{
            SkuPartNumber   = 'ENTERPRISEPACK', 'ENTERPRISEPAK'
            WarningVariable = 'skuWarnings'
            WarningAction   = 'SilentlyContinue'
        }

        $skus = Get-EntraLicenseAvailability @availabilityParameters

        $skus.SkuPartNumber | Should -Be 'ENTERPRISEPACK'
        $skuWarnings[0] | Should -BeLike '*ENTERPRISEPAK*not subscribed*'
    }
}

Describe 'Get-EntraUserLicenseAssignment' {
    It 'Emits one row per user per held SKU' {
        $rows = Get-EntraUserLicenseAssignment

        $rows.Count | Should -Be 3
        # A SKU the tenant no longer subscribes to is reported by its id.
        $expected = 'ENTERPRISEPACK', 'ENTERPRISEPREMIUM', $removedSkuId | Sort-Object
        $rows.SkuPartNumber | Sort-Object | Should -Be $expected
    }

    It 'Shows direct and group assignment, group ids, state, and errors' {
        $row = Get-EntraUserLicenseAssignment -SkuPartNumber 'ENTERPRISEPACK'

        $row.UserPrincipalName | Should -Be 'jdoe@contoso.com'
        $row.SkuId | Should -Be $e3SkuId
        $row.AssignedBy | Should -Be 'Direct;Group'
        $row.AssignmentGroupIds | Should -Be $licenseGroupId
        $row.AssignmentState | Should -Be 'Active;Error'
        $row.AssignmentError | Should -Be 'CountViolation'
        $row.AllSkus | Should -Be "ENTERPRISEPACK;$removedSkuId"
    }

    It 'Adds rows for users without the requested SKUs only when asked' {
        $rows = Get-EntraUserLicenseAssignment -SkuPartNumber 'ENTERPRISEPACK' -IncludeOtherLicensedUsers

        $rows.Count | Should -Be 2
        $otherRow = $rows.Where({ $_.UserPrincipalName -eq 'jsmith@contoso.com' })[0]
        $otherRow.SkuPartNumber | Should -BeNullOrEmpty
        $otherRow.AllSkus | Should -Be 'ENTERPRISEPREMIUM'
    }

    It 'Reports a group-only assignment as Group' {
        $row = Get-EntraUserLicenseAssignment -SkuPartNumber 'ENTERPRISEPREMIUM'

        $row.SkuId | Should -Be $e5SkuId
        $row.AssignedBy | Should -Be 'Group'
        $row.AssignmentError | Should -Be ''
    }
}

Describe 'Invoke-LicenseAvailabilityCheck.ps1' {
    BeforeEach {
        Mock -CommandName Send-MgUserMail -MockWith { }
        $reportFolder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $reportFolder
        $checkParameters = @{
            ReportFolder = $reportFolder
            MailFrom     = 'alerts@contoso.com'
            MailTo       = 'admins@contoso.com'
        }
    }

    It 'Writes the report, prunes expired reports, and alerts on a low SKU' {
        $expiredPath = Join-Path -Path $reportFolder -ChildPath '20200101-LicenseAvailability.csv'
        $recentPath = Join-Path -Path $reportFolder -ChildPath '20991231-LicenseAvailability.csv'
        $unrelatedPath = Join-Path -Path $reportFolder -ChildPath 'notes.csv'
        foreach ($path in $expiredPath, $recentPath, $unrelatedPath) {
            Set-Content -LiteralPath $path -Value 'x'
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-60)
        }
        (Get-Item -LiteralPath $recentPath).LastWriteTime = Get-Date

        $report = & $scriptPath @checkParameters -MinimumAvailable @{ ENTERPRISEPACK = 50; ENTERPRISEPREMIUM = 10 }

        $report.Name | Should -Match '^\d{8}-LicenseAvailability\.csv$'
        (Import-Csv -LiteralPath $report.FullName).Count | Should -Be 2
        $expiredPath | Should -Not -Exist
        $recentPath | Should -Exist
        $unrelatedPath | Should -Exist
        Should -Invoke -CommandName Send-MgUserMail -Times 1 -Exactly -ParameterFilter {
            $BodyParameter.Message.Subject -eq 'License availability below threshold: ENTERPRISEPACK' -and
            $BodyParameter.Message.Attachments.Count -eq 1 -and
            $UserId -eq 'alerts@contoso.com'
        }
    }

    It 'Sends nothing when every watched SKU is above its threshold' {
        $null = & $scriptPath @checkParameters -MinimumAvailable @{ ENTERPRISEPACK = 5 }

        Should -Invoke -CommandName Send-MgUserMail -Times 0 -Exactly
    }

    It 'Warns about a watched SKU the tenant does not have' {
        $checkParameters.MinimumAvailable = @{ SPE_E5 = 5 }

        $null = & $scriptPath @checkParameters -WarningVariable skuWarnings -WarningAction SilentlyContinue

        $skuWarnings[0] | Should -BeLike '*SPE_E5*not subscribed*'
    }

    It 'Changes nothing under -WhatIf' {
        $null = & $scriptPath @checkParameters -MinimumAvailable @{ ENTERPRISEPACK = 50 } -WhatIf

        Get-ChildItem -LiteralPath $reportFolder | Should -BeNullOrEmpty
        Should -Invoke -CommandName Send-MgUserMail -Times 0 -Exactly
    }
}
