#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Offline smoke tests. The ActiveDirectory cmdlets are replaced with stubs and mocks backed by an in-memory
    directory, so neither AD nor RSAT is needed to run them.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll/BeforeEach are read in It blocks, which the analyzer cannot see.'
)]
param()

BeforeAll {
    # Pester can only mock commands that exist, so stand in for them when the real ones are not installed.
    if ($null -eq (Get-Command -Name Get-ADObject -ErrorAction SilentlyContinue)) {
        function global:Get-ADObject {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [CmdletBinding()]
            param($Identity, $LDAPFilter, $Properties, $Server, [pscredential]$Credential)
        }
    }
    if ($null -eq (Get-Command -Name Set-ADObject -ErrorAction SilentlyContinue)) {
        function global:Set-ADObject {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSShouldProcess', '', Justification = 'Stub; accepts -Confirm like the real cmdlet.'
            )]
            [CmdletBinding(SupportsShouldProcess)]
            param($Identity, $Replace, $Server, [pscredential]$Credential)
        }
    }
    if ($null -eq (Get-Command -Name Get-ADDomainController -ErrorAction SilentlyContinue)) {
        function global:Get-ADDomainController {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSReviewUnusedParameter', '', Justification = 'Stub; every call is mocked.'
            )]
            [CmdletBinding()]
            param([switch]$Discover)
        }
    }

    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ADConsistencyGuid.psd1') -Force
    $moduleName = 'ADConsistencyGuid'

    function Get-TestADObject {
        param(
            [string]$Name,
            [string]$ObjectClass = 'user',
            [guid]$ConsistencyGuid
        )

        [PSCustomObject]@{
            ObjectGUID              = [guid]::NewGuid()
            DistinguishedName       = "CN=$Name,OU=Staff,DC=contoso,DC=com"
            ObjectClass             = $ObjectClass
            sAMAccountName          = $Name
            userPrincipalName       = "$Name@contoso.com"
            'mS-DS-ConsistencyGuid' = if ($PSBoundParameters.ContainsKey('ConsistencyGuid')) {
                $ConsistencyGuid.ToByteArray()
            }
        }
    }

    function Get-OwnError {
        param($ErrorList, [string]$ErrorId)

        # -ErrorVariable also collects the inner errors the function caught, so keep only its own records.
        $errorIdPattern = "$ErrorId*"
        $ErrorList.Where({ $_.FullyQualifiedErrorId -like $errorIdPattern })
    }
}

Describe 'ADConsistencyGuid' {
    BeforeEach {
        $foreignGuid = [guid]::NewGuid()
        $directory = @(
            Get-TestADObject -Name 'jdoe'
            Get-TestADObject -Name 'asmith' -ConsistencyGuid $foreignGuid
            Get-TestADObject -Name 'sales(team)' -ObjectClass 'group'
        )
        $jdoe, $asmith, $salesTeam = $directory

        # Find by ObjectGUID or distinguished name, as -Identity does, or by the sAMAccountName in -LDAPFilter.
        Mock -CommandName Get-ADObject -ModuleName $moduleName -MockWith {
            if ($null -ne $LDAPFilter) {
                $directory.Where({
                    $escapedName = $_.sAMAccountName -replace '\(', '\28' -replace '\)', '\29'
                    $LDAPFilter -eq "(sAMAccountName=$escapedName)"
                })
            }
            else {
                $match = $directory.Where({
                    $_.ObjectGUID.ToString() -eq [string]$Identity -or $_.DistinguishedName -eq [string]$Identity
                })
                if ($match.Count -eq 0) {
                    throw [System.InvalidOperationException]::new("Cannot find an object [$Identity].")
                }
                $match
            }
        }
        Mock -CommandName Set-ADObject -ModuleName $moduleName -MockWith {
            $target = $directory.Where({ $_.ObjectGUID.ToString() -eq [string]$Identity })[0]
            $target.'mS-DS-ConsistencyGuid' = $Replace['mS-DS-ConsistencyGuid']
        }
        Mock -CommandName Get-ADDomainController -ModuleName $moduleName -MockWith {
            [PSCustomObject]@{ HostName = @('dc01.contoso.com') }
        }
    }

    Describe 'Get-ADConsistencyGuid' {
        It 'reports an unset value, and a value from elsewhere with its ImmutableID' {
            $result = @(Get-ADConsistencyGuid -Identity 'jdoe', $asmith.DistinguishedName)

            $result.Count | Should -Be 2
            $result[0].ConsistencyGuid | Should -BeNullOrEmpty
            $result[0].ImmutableId | Should -BeNullOrEmpty
            $result[0].MatchesObjectGuid | Should -BeFalse
            $result[1].ConsistencyGuid | Should -Be $foreignGuid
            $result[1].ImmutableId | Should -Be ([System.Convert]::ToBase64String($foreignGuid.ToByteArray()))
            $result[1].MatchesObjectGuid | Should -BeFalse
            $result[1].PSObject.TypeNames | Should -Contain 'ADConsistencyGuid.Status'
        }

        It 'looks up a GUID by identity and escapes a sAMAccountName in the LDAP filter' {
            $result = @(Get-ADConsistencyGuid -Identity $jdoe.ObjectGUID.ToString(), 'sales(team)')

            $result.SamAccountName | Should -Be 'jdoe', 'sales(team)'
            $invokeParameters = @{
                CommandName     = 'Get-ADObject'
                ModuleName      = $moduleName
                Times           = 1
                Exactly         = $true
                ParameterFilter = { $LDAPFilter -eq '(sAMAccountName=sales\28team\29)' }
            }
            Should -Invoke @invokeParameters
        }

        It 'binds AD objects from the pipeline by property name' {
            $result = @($jdoe, $salesTeam | Get-ADConsistencyGuid)

            $result.ObjectGuid | Should -Be $jdoe.ObjectGUID, $salesTeam.ObjectGUID
        }

        It 'reports an identity that is not found and still reads the rest' {
            $readParameters = @{
                Identity      = 'nobody', 'jdoe'
                ErrorVariable = 'readErrors'
                ErrorAction   = 'SilentlyContinue'
            }
            $result = @(Get-ADConsistencyGuid @readParameters)

            $result.Count | Should -Be 1
            $ownErrors = Get-OwnError -ErrorList $readErrors -ErrorId 'ADConsistencyGuidReadFailed'
            $ownErrors.Count | Should -Be 1
            $ownErrors[0].TargetObject | Should -Be 'nobody'
        }

        It 'stops with a clear error when the ActiveDirectory module is not loaded' {
            Mock -CommandName Get-Command -ModuleName $moduleName -MockWith { $null }

            { Get-ADConsistencyGuid -Identity 'jdoe' -ErrorAction Stop } |
                Should -Throw -ErrorId 'RequiredCommandNotFound*'
        }
    }

    Describe 'Set-ADConsistencyGuid' {
        It 'stamps each object''s own ObjectGUID on one discovered DC and returns the read-back value' {
            $result = @(Set-ADConsistencyGuid -Identity 'jdoe', 'sales(team)' -Confirm:$false)

            $result.Count | Should -Be 2
            $result[0].ConsistencyGuid | Should -Be $jdoe.ObjectGUID
            $result[0].MatchesObjectGuid | Should -BeTrue
            $result[1].ConsistencyGuid | Should -Be $salesTeam.ObjectGUID
            Should -Invoke -CommandName Get-ADDomainController -ModuleName $moduleName -Times 1 -Exactly
            $invokeParameters = @{
                CommandName     = 'Set-ADObject'
                ModuleName      = $moduleName
                Times           = 2
                Exactly         = $true
                ParameterFilter = { $Server -eq 'dc01.contoso.com' }
            }
            Should -Invoke @invokeParameters
        }

        It 'leaves an object that already has the target value alone' {
            $null = Set-ADConsistencyGuid -Identity 'jdoe' -Confirm:$false
            $result = @(Set-ADConsistencyGuid -Identity 'jdoe' -Confirm:$false)

            $result[0].ConsistencyGuid | Should -Be $jdoe.ObjectGUID
            Should -Invoke -CommandName Set-ADObject -ModuleName $moduleName -Times 1 -Exactly
        }

        It 'refuses to replace a different value unless -Overwrite is given' {
            $setParameters = @{
                Identity      = 'asmith'
                Confirm       = $false
                ErrorVariable = 'setErrors'
                ErrorAction   = 'SilentlyContinue'
            }
            $refused = @(Set-ADConsistencyGuid @setParameters)

            $refused.Count | Should -Be 0
            (Get-OwnError -ErrorList $setErrors -ErrorId 'ADConsistencyGuidSetFailed').Count | Should -Be 1
            Should -Invoke -CommandName Set-ADObject -ModuleName $moduleName -Times 0 -Exactly

            $replaced = @(Set-ADConsistencyGuid -Identity 'asmith' -Overwrite -Confirm:$false)

            $replaced[0].ConsistencyGuid | Should -Be $asmith.ObjectGUID
        }

        It 'writes a supplied value to the named server' {
            $sourceAnchor = [guid]::NewGuid()

            $setParameters = @{
                Identity        = 'jdoe'
                ConsistencyGuid = $sourceAnchor
                Server          = 'dc02.contoso.com'
                Confirm         = $false
            }
            $result = @(Set-ADConsistencyGuid @setParameters)

            $result[0].ConsistencyGuid | Should -Be $sourceAnchor
            $result[0].MatchesObjectGuid | Should -BeFalse
            Should -Invoke -CommandName Get-ADDomainController -ModuleName $moduleName -Times 0 -Exactly
            $invokeParameters = @{
                CommandName     = 'Set-ADObject'
                ModuleName      = $moduleName
                Times           = 1
                Exactly         = $true
                ParameterFilter = { $Server -eq 'dc02.contoso.com' }
            }
            Should -Invoke @invokeParameters
        }

        It 'refuses a supplied value for more than one object' {
            $setParameters = @{
                Identity        = 'jdoe', 'sales(team)'
                ConsistencyGuid = [guid]::NewGuid()
                Confirm         = $false
                ErrorAction     = 'Stop'
            }

            { Set-ADConsistencyGuid @setParameters } | Should -Throw -ErrorId 'ConsistencyGuidForMultipleObjects*'
            Should -Invoke -CommandName Set-ADObject -ModuleName $moduleName -Times 1 -Exactly
        }

        It 'makes no change with -WhatIf' {
            $result = @(Set-ADConsistencyGuid -Identity 'jdoe' -WhatIf)

            $result.Count | Should -Be 0
            Should -Invoke -CommandName Set-ADObject -ModuleName $moduleName -Times 0 -Exactly
        }

        It 'reports a write that does not read back' {
            # The write "succeeds" but the value never lands, as when the read-back hits a DC that lacks it.
            Mock -CommandName Set-ADObject -ModuleName $moduleName -MockWith { }

            $setParameters = @{
                Identity      = 'jdoe'
                Confirm       = $false
                ErrorVariable = 'setErrors'
                ErrorAction   = 'SilentlyContinue'
            }
            $result = @(Set-ADConsistencyGuid @setParameters)

            $result.Count | Should -Be 0
            $ownErrors = Get-OwnError -ErrorList $setErrors -ErrorId 'ADConsistencyGuidSetFailed'
            $ownErrors.Count | Should -Be 1
            $ownErrors[0].Exception.Message | Should -BeLike '*reads back*'
        }
    }
}
