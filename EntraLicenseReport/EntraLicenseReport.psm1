#requires -Version 7.0


function Assert-GraphConnection {
    <#
    .SYNOPSIS
        Throws a terminating error, attributed to the calling command, when no Microsoft Graph session exists.
    .EXAMPLE
        Assert-GraphConnection -Caller $PSCmdlet

        Called from a public function's process block; the error names that public function, not this helper.
    #>
    [CmdletBinding()]
    param(
        # The calling advanced function's $PSCmdlet, so the error is attributed to the command the user ran.
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$Caller
    )

    if ($null -eq (Get-MgContext)) {
        $Caller.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    'Not connected to Microsoft Graph. Run Connect-MgGraph with the scopes listed in this ' +
                    "command's help first."
                ),
                'GraphNotConnected',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )
        )
    }
}


function Write-UnknownSkuWarning {
    <#
    .SYNOPSIS
        Warns about requested SKU part numbers that the tenant does not subscribe to.
    .DESCRIPTION
        A typo in a SKU part number would otherwise just produce an empty report, which looks the same as
        "nobody holds this license".
    .EXAMPLE
        Write-UnknownSkuWarning -Requested 'ENTERPRISEPAK' -Known $skus.SkuPartNumber

        Warns that ENTERPRISEPAK is not a subscribed SKU.
    #>
    [CmdletBinding()]
    param(
        # SKU part numbers the caller asked for.
        [Parameter(Mandatory)]
        [string[]]$Requested,

        # SKU part numbers the tenant actually subscribes to.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Known
    )

    foreach ($skuPartNumber in $Requested) {
        if ($skuPartNumber -notin $Known) {
            Write-Warning -Message "SKU [$skuPartNumber] is not subscribed in this tenant; nothing will match it."
        }
    }
}


function Get-EntraLicenseAvailability {
    <#
    .SYNOPSIS
        Reports purchased, consumed, and available units for each license SKU in the tenant.
    .DESCRIPTION
        Emits one object per subscribed SKU, sorted by SKU part number. AvailableUnits is EnabledUnits minus
        ConsumedUnits. WarningUnits, SuspendedUnits, and LockedOutUnits are units in the expiry grace states:
        they are not counted as enabled, but a SKU with any of them is about to lose capacity.

        Requires an existing Connect-MgGraph session with Organization.Read.All (or LicenseAssignment.Read.All).
    .OUTPUTS
        EntraLicenseReport.SkuAvailability
    .EXAMPLE
        Connect-MgGraph -Scopes 'Organization.Read.All'
        Get-EntraLicenseAvailability | Format-Table -Property SkuPartNumber, EnabledUnits, AvailableUnits

        Shows license availability for every SKU in the tenant.
    .EXAMPLE
        Get-EntraLicenseAvailability -SkuPartNumber 'ENTERPRISEPACK', 'SPE_E5' |
            Where-Object -Property AvailableUnits -LT -Value 25

        Returns Office 365 E3 or Microsoft 365 E5 if fewer than 25 units are left.
    .LINK
        Get-EntraUserLicenseAssignment
    #>
    [CmdletBinding()]
    [OutputType('EntraLicenseReport.SkuAvailability')]
    param(
        # Limit output to these SKU part numbers (for example, ENTERPRISEPACK). Omit for every SKU.
        [ValidateNotNullOrEmpty()]
        [string[]]$SkuPartNumber
    )

    process {
        Assert-GraphConnection -Caller $PSCmdlet

        try {
            $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }

        if ($PSBoundParameters.ContainsKey('SkuPartNumber')) {
            Write-UnknownSkuWarning -Requested $SkuPartNumber -Known $skus.SkuPartNumber
            $skus = $skus.Where({ $_.SkuPartNumber -in $SkuPartNumber })
        }

        foreach ($sku in $skus | Sort-Object -Property SkuPartNumber) {
            [PSCustomObject]@{
                PSTypeName       = 'EntraLicenseReport.SkuAvailability'
                SkuPartNumber    = $sku.SkuPartNumber
                SkuId            = $sku.SkuId
                CapabilityStatus = $sku.CapabilityStatus
                AppliesTo        = $sku.AppliesTo
                EnabledUnits     = $sku.PrepaidUnits.Enabled
                ConsumedUnits    = $sku.ConsumedUnits
                AvailableUnits   = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
                WarningUnits     = $sku.PrepaidUnits.Warning
                SuspendedUnits   = $sku.PrepaidUnits.Suspended
                LockedOutUnits   = $sku.PrepaidUnits.LockedOut
            }
        }
    }
}


function Get-EntraUserLicenseAssignment {
    <#
    .SYNOPSIS
        Lists licensed users as one row per user per SKU, including how and whether each license applied.
    .DESCRIPTION
        Emits one row for each SKU a licensed user holds, so users with several SKUs appear several times.
        That shape makes per-SKU counts a single Group-Object and per-SKU user lists a single Where-Object.

        Each row also shows whether the license was assigned directly, by group (with the group ids), or both,
        and the assignment state and error from group-based licensing (for example, CountViolation when a
        group tries to assign more licenses than are available).

        With -SkuPartNumber, only rows for those SKUs are emitted. Add -IncludeOtherLicensedUsers to also get
        one row (with an empty SkuPartNumber) for each licensed user holding none of them.

        Requires an existing Connect-MgGraph session with User.Read.All and Organization.Read.All.
    .OUTPUTS
        EntraLicenseReport.UserLicenseAssignment
    .EXAMPLE
        Connect-MgGraph -Scopes 'User.Read.All', 'Organization.Read.All'
        Get-EntraUserLicenseAssignment | Group-Object -Property SkuPartNumber -NoElement

        Counts licensed users per SKU.
    .EXAMPLE
        Get-EntraUserLicenseAssignment -SkuPartNumber 'STANDARDPACK', 'ENTERPRISEPACK', 'ENTERPRISEPREMIUM' |
            Group-Object -Property UserPrincipalName |
            Where-Object -Property Count -GT -Value 1

        Finds users holding more than one Office 365 E-plan, a common source of wasted licenses.
    .EXAMPLE
        Get-EntraUserLicenseAssignment | Where-Object -Property AssignmentError -NE -Value ''

        Lists group-based license assignments that failed to apply, with the reason.
    .LINK
        Get-EntraLicenseAvailability
    #>
    [CmdletBinding()]
    [OutputType('EntraLicenseReport.UserLicenseAssignment')]
    param(
        # Only report these SKU part numbers (for example, ENTERPRISEPACK). Omit to report every SKU.
        [ValidateNotNullOrEmpty()]
        [string[]]$SkuPartNumber,

        # With -SkuPartNumber, also emit one row for each licensed user who holds none of those SKUs.
        [switch]$IncludeOtherLicensedUsers
    )

    process {
        Assert-GraphConnection -Caller $PSCmdlet

        <#
        Filtering on assignedLicenses/$count is an advanced query: Graph requires the eventual consistency
        level and a count request with it, which is what -ConsistencyLevel and -CountVariable provide.
        #>
        $userParameters = @{
            All              = $true
            Filter           = 'assignedLicenses/$count ne 0'
            ConsistencyLevel = 'eventual'
            CountVariable    = 'licensedUserCount'
            Property         = @(
                'id', 'displayName', 'userPrincipalName', 'accountEnabled', 'assignedLicenses',
                'licenseAssignmentStates'
            )
            ErrorAction      = 'Stop'
        }
        try {
            $skus = @(Get-MgSubscribedSku -All -ErrorAction Stop)
            $users = @(Get-MgUser @userParameters)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
        Write-Verbose -Message "Found [$($users.Count)] licensed users and [$($skus.Count)] subscribed SKUs"

        $skuNameIndex = @{}
        foreach ($sku in $skus) {
            $skuNameIndex[$sku.SkuId] = $sku.SkuPartNumber
        }
        $reportAllSkus = -not $PSBoundParameters.ContainsKey('SkuPartNumber')
        if (-not $reportAllSkus) {
            Write-UnknownSkuWarning -Requested $SkuPartNumber -Known $skus.SkuPartNumber
        }

        foreach ($user in $users) {
            $heldSkuIds = @($user.AssignedLicenses.SkuId)
            # A SKU the tenant no longer subscribes to has no part number to look up, so show its id instead.
            $allSkus = $heldSkuIds.ForEach({ $skuNameIndex[$_] ?? $_ }) -join ';'
            $userColumns = [ordered]@{
                PSTypeName        = 'EntraLicenseReport.UserLicenseAssignment'
                UserId            = $user.Id
                DisplayName       = $user.DisplayName
                UserPrincipalName = $user.UserPrincipalName
                AccountEnabled    = $user.AccountEnabled
            }

            $reportSkuIds = if ($reportAllSkus) {
                $heldSkuIds
            }
            else {
                $heldSkuIds.Where({ $skuNameIndex[$_] -in $SkuPartNumber })
            }

            if ($reportSkuIds.Count -eq 0 -and $IncludeOtherLicensedUsers) {
                $row = $userColumns + [ordered]@{
                    SkuPartNumber      = $null
                    SkuId              = $null
                    AssignedBy         = $null
                    AssignmentGroupIds = $null
                    AssignmentState    = $null
                    AssignmentError    = $null
                    AllSkus            = $allSkus
                }
                [PSCustomObject]$row
            }

            foreach ($skuId in $reportSkuIds) {
                <#
                A user can hold the same SKU both directly and from one or more groups; each source is a
                separate assignment state, and an empty AssignedByGroup means the direct one.
                #>
                $states = @($user.LicenseAssignmentStates.Where({ $_.SkuId -eq $skuId }))
                $groupIds = @($states.AssignedByGroup.Where({ $_ }))
                $assignedBy = @(
                    if ($states.Where({ -not $_.AssignedByGroup }).Count -gt 0) {
                        'Direct'
                    }
                    if ($groupIds.Count -gt 0) {
                        'Group'
                    }
                )

                $assignmentErrors = $states.Error.Where({ $_ -and $_ -ne 'None' }) | Sort-Object -Unique

                $row = $userColumns + [ordered]@{
                    SkuPartNumber      = $skuNameIndex[$skuId] ?? $skuId
                    SkuId              = $skuId
                    AssignedBy         = $assignedBy -join ';'
                    AssignmentGroupIds = $groupIds -join ';'
                    AssignmentState    = ($states.State | Sort-Object -Unique) -join ';'
                    AssignmentError    = $assignmentErrors -join ';'
                    AllSkus            = $allSkus
                }
                [PSCustomObject]$row
            }
        }
    }
}
