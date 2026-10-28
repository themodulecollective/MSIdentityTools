#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Offline tests. The planner only reads the objects it is given, so plain objects stand in for AD, Entra, and
    Exchange Online.
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll/BeforeEach are read in It blocks, which the analyzer cannot see.'
)]
param()

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\ForestUserMerge.psd1') -Force

    function Get-TestADUser {
        param(
            [string]$UserPrincipalName = 'jdoe@contoso.com',
            [guid]$ConsistencyGuid,
            [long]$RecipientTypeDetails,
            [string[]]$ProxyAddresses = @(),
            [string]$LegacyExchangeDN
        )

        [PSCustomObject]@{
            ObjectGUID                 = [guid]::NewGuid()
            UserPrincipalName          = $UserPrincipalName
            'mS-DS-ConsistencyGuid'    = if ($PSBoundParameters.ContainsKey('ConsistencyGuid')) {
                $ConsistencyGuid.ToByteArray()
            }
            msExchRecipientTypeDetails = if ($PSBoundParameters.ContainsKey('RecipientTypeDetails')) {
                $RecipientTypeDetails
            }
            proxyAddresses             = $ProxyAddresses
            legacyExchangeDN           = $LegacyExchangeDN
        }
    }

    function Get-TestEntraUser {
        param(
            [string]$UserPrincipalName = 'jdoe@contoso.com',
            [switch]$Licensed
        )

        [PSCustomObject]@{
            UserPrincipalName = $UserPrincipalName
            AssignedLicenses  = if ($Licensed) { @([PSCustomObject]@{ SkuId = [guid]::NewGuid() }) } else { @() }
        }
    }

    # msExchRecipientTypeDetails for RemoteUserMailbox.
    $remote = [long]2147483648
    $legacyDN = '/o=Fabrikam/ou=Exchange Administrative Group/cn=Recipients/cn=jdoe'
}

Describe 'Get-ForestUserMergePlan' {
    BeforeEach {
        $targetAnchor = [guid]::NewGuid()
        $legacyAnchor = [guid]::NewGuid()
        $planParameters = @{ DesiredUpnSuffix = 'contoso.com' }
    }

    It 'asks for a target user, and nothing else, when there is none' {
        $legacyUser = Get-TestADUser -ConsistencyGuid $legacyAnchor -RecipientTypeDetails $remote

        $contact = [PSCustomObject]@{ Name = 'Jane Doe' }
        $plan = Get-ForestUserMergePlan -LegacyUser $legacyUser -LegacyContact $contact @planParameters

        $plan.Operations | Should -Be @('ManualInterventionRequestTargetUserProvisioning')
        $plan.RequiresManualIntervention | Should -BeTrue
        $plan.PSObject.TypeNames | Should -Contain 'ForestUserMerge.Plan'
    }

    It 'anchors and mail-enables a lone target user' {
        $planParameters.TargetUser = Get-TestADUser
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.Operations | Should -Be @('SetTargetConsistencyGuidFromObjectGuid', 'EnableTargetRemoteMailbox')
        $plan.LicensedUser | Should -Be 'Target'
        $plan.RequiresManualIntervention | Should -BeFalse
    }

    It 'takes mail attributes from an existing Exchange Online mailbox when there is no legacy user' {
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed
        $planParameters.ExchangeOnlineMailbox = [PSCustomObject]@{ Alias = 'jdoe' }

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.Operations | Should -Be @('EnableTargetRemoteMailboxFromExchangeOnlineMailbox')
    }

    It 'copies the anchor and mailbox from a synced legacy user to a new target user' {
        $planParameters.TargetUser = Get-TestADUser
        $planParameters.LegacyUser = Get-TestADUser -ConsistencyGuid $legacyAnchor -RecipientTypeDetails $remote
        $planParameters.LegacyEntraUser = Get-TestEntraUser -Licensed

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.LicensedUser | Should -Be 'Legacy'
        $plan.Operations | Should -Be @(
            'SetTargetConsistencyGuidFromLegacyUser'
            'EnableTargetRemoteMailboxFromLegacyUser'
        )
    }

    It 're-anchors the legacy user only when the target Entra user is clearly the one to keep' {
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor -RecipientTypeDetails $remote
        $planParameters.LegacyUser = Get-TestADUser -ConsistencyGuid $legacyAnchor
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed
        $planParameters.LegacyEntraUser = Get-TestEntraUser

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.ConsistencyGuidsMatch | Should -BeFalse
        $plan.Operations | Should -Be @('ResetLegacyConsistencyGuidFromTargetUser')

        $planParameters.LegacyEntraUser = Get-TestEntraUser -Licensed
        $dualPlan = Get-ForestUserMergePlan @planParameters

        $dualPlan.Operations | Should -Be @(
            'ManualInterventionDualLicense'
            'ManualInterventionForConsistencyGuid'
        )
    }

    It 'treats users that already share an anchor as joined and only adds the missing x500 address' {
        $entraUser = Get-TestEntraUser -Licensed
        $legacyParameters = @{
            ConsistencyGuid      = $targetAnchor
            RecipientTypeDetails = $remote
            LegacyExchangeDN     = $legacyDN
        }
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor -RecipientTypeDetails $remote
        $planParameters.LegacyUser = Get-TestADUser @legacyParameters
        $planParameters.TargetEntraUser = $entraUser
        $planParameters.LegacyEntraUser = $entraUser

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.LicensedUser | Should -Be 'Joined'
        $plan.TargetHasLegacyX500 | Should -BeFalse
        $plan.Operations | Should -Be @('AddLegacyX500ToTargetUser')

        $planParameters.TargetUser.proxyAddresses = @('SMTP:jdoe@contoso.com', "X500:$legacyDN")
        (Get-ForestUserMergePlan @planParameters).Operations | Should -BeNullOrEmpty
    }

    It 'fixes the UPN from whichever user already has the right suffix, once' {
        $wrongSuffix = 'jdoe@fabrikam.com'
        $planParameters.TargetUser = Get-TestADUser -UserPrincipalName $wrongSuffix -ConsistencyGuid $targetAnchor
        $planParameters.LegacyUser = Get-TestADUser -ConsistencyGuid $targetAnchor
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.Operations.Where({ $_ -like '*Upn*' }) | Should -Be @('SetTargetUserUpnFromLegacyUser')

        $planParameters.LegacyUser.UserPrincipalName = $wrongSuffix
        $bothWrong = Get-ForestUserMergePlan @planParameters

        $bothWrong.Operations.Where({ $_ -like '*Upn*' }) | Should -Be @('ManualInterventionForUpn')
    }

    It 'flags an unexpected recipient type instead of planning mailbox changes for it' {
        # 1 is UserMailbox: an on-premises mailbox where a remote mailbox is expected.
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor -RecipientTypeDetails 1
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.TargetRecipientType | Should -Be 'Unexpected'
        $plan.Operations | Should -Be @('ManualInterventionTargetUserUnexpectedRecipientType')
    }

    It 'asks for a license when no Entra user has one' {
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor -RecipientTypeDetails $remote

        (Get-ForestUserMergePlan @planParameters).Operations | Should -Be @('LicenseUser')
    }

    It 'folds in contacts from both forests' {
        $planParameters.TargetUser = Get-TestADUser -ConsistencyGuid $targetAnchor -RecipientTypeDetails $remote
        $planParameters.TargetEntraUser = Get-TestEntraUser -Licensed
        $planParameters.LegacyContact = [PSCustomObject]@{ Name = 'Jane Doe (legacy)' }
        $planParameters.TargetContact = [PSCustomObject]@{ Name = 'Jane Doe (target)' }

        $plan = Get-ForestUserMergePlan @planParameters

        $plan.Operations | Should -Be @(
            'MergeLegacyContactIntoTargetUser'
            'WarnLegacyContactGroupMembershipLoss'
            'RemoveLegacyContact'
            'MergeTargetContactIntoTargetUser'
            'TransferTargetContactMembershipToTargetUser'
            'RemoveTargetContact'
        )
    }

    It 'plans each person piped in by property name' {
        $people = @(
            [PSCustomObject]@{ TargetUser = Get-TestADUser -UserPrincipalName 'jdoe@contoso.com' }
            [PSCustomObject]@{ LegacyUser = Get-TestADUser -UserPrincipalName 'asmith@contoso.com' }
        )

        $plans = @($people | Get-ForestUserMergePlan -DesiredUpnSuffix 'contoso.com')

        $plans.Count | Should -Be 2
        $plans[0].TargetUserPrincipalName | Should -Be 'jdoe@contoso.com'
        $plans[1].LegacyUserPrincipalName | Should -Be 'asmith@contoso.com'
        $plans[1].Operations | Should -Be @('ManualInterventionRequestTargetUserProvisioning')
    }
}
