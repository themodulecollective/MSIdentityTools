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


function Invoke-InventoryLookup {
    <#
    .SYNOPSIS
        Runs one per-object Graph lookup, turning a failure into a warning plus a recorded error message.
    .DESCRIPTION
        One app's inventory makes many independent Graph calls (owners, assignments, provisioning, ...). A
        permission gap or transient failure in one of them should not lose the rest of that app's record, so
        each call runs through this wrapper: on failure it warns, appends the message to ErrorList, and emits
        nothing. Callers wrap the result in @() so a failed lookup reads as an empty collection.
    .EXAMPLE
        $lookup = @{ ObjectName = $app.DisplayName; Section = 'Owners'; ErrorList = $errors }
        $owners = @(Invoke-InventoryLookup @lookup -ScriptBlock {
            Get-MgApplicationOwner -ApplicationId $app.Id -All -ErrorAction Stop
        })

        Returns the owners, or an empty array plus a warning and an entry in $errors if the call fails.
    #>
    [CmdletBinding()]
    param(
        # Display name of the object being inventoried, used in the warning text.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ObjectName,

        # Name of the section being looked up (for example, 'Owners'), used in the warning text.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Section,

        # The lookup to run. Cmdlets inside it must use -ErrorAction Stop or failures are not caught.
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        # List that receives the failure message, so it can be stored with the object's record.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$ErrorList
    )

    try {
        & $ScriptBlock
    }
    catch {
        $lookupError = $PSItem
        $message = "Could not read [$Section] for [$ObjectName]: $($lookupError.Exception.Message)"
        Write-Warning -Message $message
        $ErrorList.Add($message)
    }
}


function ConvertTo-InventoryOwner {
    <#
    .SYNOPSIS
        Flattens Graph directoryObject owners into small, serializable records.
    .EXAMPLE
        ConvertTo-InventoryOwner -InputObject (Get-MgApplicationOwner -ApplicationId $app.Id -All)

        Returns one record per owner with Id, ObjectType, DisplayName, and UserPrincipalName.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # Owner objects as returned by Get-MgApplicationOwner or Get-MgServicePrincipalOwner.
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    foreach ($owner in $InputObject) {
        <#
        The owners endpoints return the generic directoryObject type, so the SDK only surfaces the
        user/service-principal properties through AdditionalProperties. Owners are not always users, which is
        why ObjectType is kept and UserPrincipalName may be empty.
        #>
        [PSCustomObject]@{
            Id                = $owner.Id
            ObjectType        = $owner.AdditionalProperties['@odata.type'] -replace '^#microsoft\.graph\.'
            DisplayName       = $owner.AdditionalProperties['displayName']
            UserPrincipalName = $owner.AdditionalProperties['userPrincipalName']
        }
    }
}


function ConvertTo-InventoryCredential {
    <#
    .SYNOPSIS
        Reduces Graph key/password credentials to non-sensitive metadata.
    .DESCRIPTION
        Keeps only what an inventory needs (name, id, validity window, usage). The certificate key blob is
        dropped to keep exports small; Graph never returns secret values on read.
    .EXAMPLE
        ConvertTo-InventoryCredential -InputObject $app.KeyCredentials -Kind Certificate

        Returns one metadata record per certificate on the application.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # The PasswordCredentials or KeyCredentials collection from an application or service principal.
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        # Which collection InputObject came from.
        [Parameter(Mandatory)]
        [ValidateSet('Certificate', 'Secret')]
        [string]$Kind
    )

    foreach ($credential in $InputObject) {
        [PSCustomObject]@{
            CredentialType = $Kind
            DisplayName    = $credential.DisplayName
            KeyId          = $credential.KeyId
            Usage          = $credential.Usage
            StartDateTime  = $credential.StartDateTime
            EndDateTime    = $credential.EndDateTime
        }
    }
}


function ConvertTo-SafeFileName {
    <#
    .SYNOPSIS
        Replaces characters that are invalid in a file name and truncates to a safe length.
    .EXAMPLE
        ConvertTo-SafeFileName -Name 'HR [Prod]: Payroll'

        Returns 'HR _Prod__ Payroll'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The candidate file name, typically built from an object's display name.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        # Maximum length of the returned name; keeps full paths well under the legacy 260-character limit.
        [ValidateRange(1, 255)]
        [int]$MaximumLength = 200
    )

    # Square brackets are legal in file names but are wildcard characters to every -Path parameter.
    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]'[]'
    $safeName = $Name
    foreach ($character in $invalidCharacters) {
        $safeName = $safeName.Replace($character, '_')
    }
    $safeName.Substring(0, [System.Math]::Min($safeName.Length, $MaximumLength))
}


function Get-EntraAppRegistrationInventory {
    <#
    .SYNOPSIS
        Inventories Entra ID app registrations as summary rows with a detailed configuration attached.
    .DESCRIPTION
        Emits one object per app registration (application object). Each object has flat summary
        properties suitable for a CSV, plus a Detail property holding the full configuration: authentication,
        exposed API, requested permissions, owners, credential metadata, and federated identity credentials.
        Pipe the output to Export-EntraAppInventory to write it to disk.

        A lookup that fails for one application (for example, reading its owners) produces a warning and an
        entry in Detail.LookupErrors; the rest of that application's record is still emitted.

        Requires an existing Connect-MgGraph session with Application.Read.All.
    .OUTPUTS
        EntraAppInventory.AppRegistration
    .EXAMPLE
        Connect-MgGraph -Scopes 'Application.Read.All'
        Get-EntraAppRegistrationInventory | Export-EntraAppInventory -Path "$Env:UserProfile\AppInventory"

        Inventories every app registration and writes a summary CSV plus one JSON file per app.
    .EXAMPLE
        Get-EntraAppRegistrationInventory -Filter "startswith(displayName, 'HR-')" |
            Where-Object -Property CredentialExpiresSoonest -LT -Value (Get-Date).AddDays(30)

        Lists HR app registrations with a secret or certificate expiring within 30 days.
    .LINK
        Get-EntraEnterpriseAppInventory
    .LINK
        Export-EntraAppInventory
    #>
    [CmdletBinding()]
    [OutputType('EntraAppInventory.AppRegistration')]
    param(
        # OData filter passed to Get-MgApplication. Omit to inventory every app registration.
        [ValidateNotNullOrEmpty()]
        [string]$Filter
    )

    process {
        Assert-GraphConnection -Caller $PSCmdlet

        $getParameters = @{
            All         = $true
            ErrorAction = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Filter')) {
            $getParameters.Filter = $Filter
        }
        try {
            $applications = @(Get-MgApplication @getParameters)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
        Write-Verbose -Message "Found [$($applications.Count)] app registrations"

        $index = 0
        foreach ($application in $applications) {
            $index++
            if ($index % 25 -eq 1) {
                $progressParameters = @{
                    Activity        = 'Inventorying app registrations'
                    Status          = "[$index/$($applications.Count)] $($application.DisplayName)"
                    PercentComplete = 100 * $index / $applications.Count
                }
                Write-Progress @progressParameters
            }

            $lookupErrors = [System.Collections.Generic.List[string]]::new()
            $lookup = @{
                ObjectName = $application.DisplayName
                ErrorList  = $lookupErrors
            }
            $owners = @(Invoke-InventoryLookup @lookup -Section 'Owners' -ScriptBlock {
                Get-MgApplicationOwner -ApplicationId $application.Id -All -ErrorAction Stop
            })
            $federated = @(Invoke-InventoryLookup @lookup -Section 'FederatedCredentials' -ScriptBlock {
                Get-MgApplicationFederatedIdentityCredential -ApplicationId $application.Id -All -ErrorAction Stop
            })

            $ownerRecords = @(ConvertTo-InventoryOwner -InputObject $owners)
            $ownerNames = $ownerRecords.ForEach({ $_.UserPrincipalName ?? $_.DisplayName }) -join ';'
            $credentials = @(
                ConvertTo-InventoryCredential -InputObject $application.PasswordCredentials -Kind Secret
                ConvertTo-InventoryCredential -InputObject $application.KeyCredentials -Kind Certificate
            )

            $detail = [ordered]@{
                BasicInfo                    = [ordered]@{
                    DisplayName     = $application.DisplayName
                    ObjectId        = $application.Id
                    AppId           = $application.AppId
                    SignInAudience  = $application.SignInAudience
                    PublisherDomain = $application.PublisherDomain
                    CreatedDateTime = $application.CreatedDateTime
                    IdentifierUris  = $application.IdentifierUris
                    Notes           = $application.Notes
                    Tags            = $application.Tags
                }
                Authentication               = [ordered]@{
                    WebRedirectUris             = $application.Web.RedirectUris
                    WebLogoutUrl                = $application.Web.LogoutUrl
                    SpaRedirectUris             = $application.Spa.RedirectUris
                    PublicClientRedirectUris    = $application.PublicClient.RedirectUris
                    ImplicitGrantSettings       = $application.Web.ImplicitGrantSettings
                    DefaultRedirectUri          = $application.DefaultRedirectUri
                    FallbackPublicClientEnabled = $application.IsFallbackPublicClient
                }
                Api                          = [ordered]@{
                    Oauth2PermissionScopes      = $application.Api.Oauth2PermissionScopes
                    PreAuthorizedApplications   = $application.Api.PreAuthorizedApplications
                    AcceptMappedClaims          = $application.Api.AcceptMappedClaims
                    KnownClientApplications     = $application.Api.KnownClientApplications
                    RequestedAccessTokenVersion = $application.Api.RequestedAccessTokenVersion
                }
                Permissions                  = [ordered]@{
                    RequiredResourceAccess = $application.RequiredResourceAccess
                    AppRoles               = $application.AppRoles
                    GroupMembershipClaims  = $application.GroupMembershipClaims
                    OptionalClaims         = $application.OptionalClaims
                }
                Owners                       = $ownerRecords
                Credentials                  = $credentials
                FederatedIdentityCredentials = $federated
                LookupErrors                 = $lookupErrors
            }

            [PSCustomObject]@{
                PSTypeName               = 'EntraAppInventory.AppRegistration'
                DisplayName              = $application.DisplayName
                ObjectId                 = $application.Id
                AppId                    = $application.AppId
                SignInAudience           = $application.SignInAudience
                PublisherDomain          = $application.PublisherDomain
                CreatedDateTime          = $application.CreatedDateTime
                Owners                   = $ownerNames
                SecretCount              = $credentials.Where({ $_.CredentialType -eq 'Secret' }).Count
                CertificateCount         = $credentials.Where({ $_.CredentialType -eq 'Certificate' }).Count
                CredentialExpiresSoonest = $credentials.EndDateTime | Sort-Object | Select-Object -First 1
                FederatedCredentialCount = $federated.Count
                ExposesApi               = $application.Api.Oauth2PermissionScopes.Count -gt 0
                HasApiPermissions        = $application.RequiredResourceAccess.Count -gt 0
                LookupErrorCount         = $lookupErrors.Count
                Detail                   = $detail
            }
        }
        Write-Progress -Activity 'Inventorying app registrations' -Completed
    }
}


function Get-EntraEnterpriseAppInventory {
    <#
    .SYNOPSIS
        Inventories Entra ID enterprise applications (service principals) as summary rows with detail attached.
    .DESCRIPTION
        Emits one object per service principal. Each object has flat summary properties suitable for a CSV,
        plus a Detail property holding: SSO settings, owners, user/group assignments, group memberships,
        delegated (OAuth2) grants, application permissions granted to the app, directly-targeted Conditional
        Access policies, provisioning jobs, and credential metadata. Pipe the output to
        Export-EntraAppInventory to write it to disk.

        By default only the apps shown in the portal's Enterprise applications list are included
        (integrated applications), not Microsoft first-party or managed-identity service principals.

        Conditional Access policies are read once for the whole tenant and indexed by app id. Only policies
        that name the app explicitly are attributed to it; policies scoped to 'All' cloud apps are not.

        A lookup that fails for one app produces a warning and an entry in Detail.LookupErrors; the rest of
        that app's record is still emitted. If Conditional Access can't be read at all, that failure is
        recorded on every record.

        Requires an existing Connect-MgGraph session with Application.Read.All, Directory.Read.All,
        Policy.Read.All (Conditional Access), and Synchronization.Read.All (provisioning jobs).
    .OUTPUTS
        EntraAppInventory.EnterpriseApp
    .EXAMPLE
        $scopes = 'Application.Read.All', 'Directory.Read.All', 'Policy.Read.All', 'Synchronization.Read.All'
        Connect-MgGraph -Scopes $scopes
        Get-EntraEnterpriseAppInventory | Export-EntraAppInventory -Path "$Env:UserProfile\AppInventory"

        Inventories every enterprise app and writes a summary CSV plus one JSON file per app.
    .EXAMPLE
        Get-EntraEnterpriseAppInventory |
            Where-Object -FilterScript { -not $_.AppRoleAssignmentRequired -and $_.SsoMode -eq 'saml' }

        Lists SAML apps that any user in the tenant can sign in to without being assigned.
    .LINK
        Get-EntraAppRegistrationInventory
    .LINK
        Export-EntraAppInventory
    #>
    [CmdletBinding()]
    [OutputType('EntraAppInventory.EnterpriseApp')]
    param(
        # OData filter passed to Get-MgServicePrincipal. The default matches the portal's Enterprise
        # applications list.
        [ValidateNotNullOrEmpty()]
        [string]$Filter = "servicePrincipalType eq 'Application' and " +
            "tags/any(t:t eq 'WindowsAzureActiveDirectoryIntegratedApp')"
    )

    process {
        Assert-GraphConnection -Caller $PSCmdlet

        try {
            $servicePrincipals = @(Get-MgServicePrincipal -Filter $Filter -All -ErrorAction Stop)
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
        Write-Verbose -Message "Found [$($servicePrincipals.Count)] enterprise applications"

        # One tenant-wide read, indexed by app id, instead of re-reading every policy for every app.
        $tenantErrors = [System.Collections.Generic.List[string]]::new()
        $tenantLookup = @{
            ObjectName = 'tenant'
            Section    = 'ConditionalAccessPolicies'
            ErrorList  = $tenantErrors
        }
        $policies = @(Invoke-InventoryLookup @tenantLookup -ScriptBlock {
            Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
        })
        $policyIndex = @{}
        foreach ($policy in $policies) {
            foreach ($targetAppId in $policy.Conditions.Applications.IncludeApplications) {
                if (-not $policyIndex.ContainsKey($targetAppId)) {
                    $policyIndex[$targetAppId] = [System.Collections.Generic.List[string]]::new()
                }
                $policyIndex[$targetAppId].Add($policy.DisplayName)
            }
        }

        $index = 0
        foreach ($servicePrincipal in $servicePrincipals) {
            $index++
            if ($index % 25 -eq 1) {
                $progressParameters = @{
                    Activity        = 'Inventorying enterprise applications'
                    Status          = "[$index/$($servicePrincipals.Count)] $($servicePrincipal.DisplayName)"
                    PercentComplete = 100 * $index / $servicePrincipals.Count
                }
                Write-Progress @progressParameters
            }

            $lookupErrors = [System.Collections.Generic.List[string]]::new($tenantErrors)
            $lookup = @{
                ObjectName = $servicePrincipal.DisplayName
                ErrorList  = $lookupErrors
            }
            $spId = $servicePrincipal.Id
            $owners = @(Invoke-InventoryLookup @lookup -Section 'Owners' -ScriptBlock {
                Get-MgServicePrincipalOwner -ServicePrincipalId $spId -All -ErrorAction Stop
            })
            $assignedTo = @(Invoke-InventoryLookup @lookup -Section 'AssignedPrincipals' -ScriptBlock {
                Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $spId -All -ErrorAction Stop
            })
            $memberOf = @(Invoke-InventoryLookup @lookup -Section 'MemberOf' -ScriptBlock {
                Get-MgServicePrincipalMemberOf -ServicePrincipalId $spId -All -ErrorAction Stop
            })
            $delegatedGrants = @(Invoke-InventoryLookup @lookup -Section 'DelegatedGrants' -ScriptBlock {
                Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $spId -All -ErrorAction Stop
            })
            $applicationGrants = @(Invoke-InventoryLookup @lookup -Section 'ApplicationGrants' -ScriptBlock {
                Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $spId -All -ErrorAction Stop
            })
            $provisioningJobs = @(Invoke-InventoryLookup @lookup -Section 'ProvisioningJobs' -ScriptBlock {
                $uri = "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/synchronization/jobs"
                (Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop).value
            })

            $ownerRecords = @(ConvertTo-InventoryOwner -InputObject $owners)
            $ownerNames = $ownerRecords.ForEach({ $_.UserPrincipalName ?? $_.DisplayName }) -join ';'
            $credentials = @(
                ConvertTo-InventoryCredential -InputObject $servicePrincipal.PasswordCredentials -Kind Secret
                ConvertTo-InventoryCredential -InputObject $servicePrincipal.KeyCredentials -Kind Certificate
            )
            $policyNames = @($policyIndex[$servicePrincipal.AppId])

            $detail = [ordered]@{
                BasicInfo                 = [ordered]@{
                    DisplayName               = $servicePrincipal.DisplayName
                    ObjectId                  = $spId
                    AppId                     = $servicePrincipal.AppId
                    AppOwnerOrganizationId    = $servicePrincipal.AppOwnerOrganizationId
                    ApplicationTemplateId     = $servicePrincipal.ApplicationTemplateId
                    ServicePrincipalType      = $servicePrincipal.ServicePrincipalType
                    AccountEnabled            = $servicePrincipal.AccountEnabled
                    AppRoleAssignmentRequired = $servicePrincipal.AppRoleAssignmentRequired
                    PublisherName             = $servicePrincipal.PublisherName
                    SignInAudience            = $servicePrincipal.SignInAudience
                    Homepage                  = $servicePrincipal.Homepage
                    Notes                     = $servicePrincipal.Notes
                    Tags                      = $servicePrincipal.Tags
                }
                SingleSignOn              = [ordered]@{
                    PreferredSingleSignOnMode          = $servicePrincipal.PreferredSingleSignOnMode
                    SamlSingleSignOnSettings           = $servicePrincipal.SamlSingleSignOnSettings
                    PreferredTokenSigningKeyThumbprint = $servicePrincipal.PreferredTokenSigningKeyThumbprint
                    LoginUrl                           = $servicePrincipal.LoginUrl
                    LogoutUrl                          = $servicePrincipal.LogoutUrl
                    ReplyUrls                          = $servicePrincipal.ReplyUrls
                    NotificationEmailAddresses         = $servicePrincipal.NotificationEmailAddresses
                }
                AppRoles                  = $servicePrincipal.AppRoles
                Oauth2PermissionScopes    = $servicePrincipal.Oauth2PermissionScopes
                Owners                    = $ownerRecords
                AssignedPrincipals        = $assignedTo
                MemberOf                  = $memberOf
                DelegatedGrants           = $delegatedGrants
                ApplicationGrants         = $applicationGrants
                ConditionalAccessPolicies = $policyNames
                ProvisioningJobs          = $provisioningJobs
                Credentials               = $credentials
                LookupErrors              = $lookupErrors
            }

            [PSCustomObject]@{
                PSTypeName                = 'EntraAppInventory.EnterpriseApp'
                DisplayName               = $servicePrincipal.DisplayName
                ObjectId                  = $spId
                AppId                     = $servicePrincipal.AppId
                AppOwnerOrganizationId    = $servicePrincipal.AppOwnerOrganizationId
                AccountEnabled            = $servicePrincipal.AccountEnabled
                AppRoleAssignmentRequired = $servicePrincipal.AppRoleAssignmentRequired
                SsoMode                   = $servicePrincipal.PreferredSingleSignOnMode
                Owners                    = $ownerNames
                AssignedPrincipalCount    = $assignedTo.Count
                ConditionalAccessPolicies = $policyNames -join ';'
                HasProvisioning           = $provisioningJobs.Count -gt 0
                SecretCount               = $credentials.Where({ $_.CredentialType -eq 'Secret' }).Count
                CertificateCount          = $credentials.Where({ $_.CredentialType -eq 'Certificate' }).Count
                CredentialExpiresSoonest  = $credentials.EndDateTime | Sort-Object | Select-Object -First 1
                LookupErrorCount          = $lookupErrors.Count
                Detail                    = $detail
            }
        }
        Write-Progress -Activity 'Inventorying enterprise applications' -Completed
    }
}


function Export-EntraAppInventory {
    <#
    .SYNOPSIS
        Writes app inventory records to a summary CSV and one JSON configuration file per app.
    .DESCRIPTION
        Accepts records from Get-EntraAppRegistrationInventory and/or Get-EntraEnterpriseAppInventory. For
        each record type it writes <Type>-Summary.csv to Path (every summary property, plus a DetailFile
        column) and one JSON file per app, holding its Detail, under Path\<Type>\. JSON files are named
        <AppId>-<DisplayName>.json; the app id comes first so truncating a long display name can never make
        two file names collide.
    .OUTPUTS
        System.IO.FileInfo for each summary CSV written.
    .EXAMPLE
        Get-EntraAppRegistrationInventory | Export-EntraAppInventory -Path 'D:\Inventory\2026-10'

        Writes D:\Inventory\2026-10\AppRegistration-Summary.csv and D:\Inventory\2026-10\AppRegistration\*.json.
    .EXAMPLE
        & { Get-EntraAppRegistrationInventory; Get-EntraEnterpriseAppInventory } |
            Export-EntraAppInventory -Path 'D:\Inventory\2026-10'

        Exports both record types in one pass; each type still gets its own CSV and JSON folder.
    .LINK
        Get-EntraAppRegistrationInventory
    .LINK
        Get-EntraEnterpriseAppInventory
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.IO.FileInfo])]
    param(
        # Inventory records from Get-EntraAppRegistrationInventory or Get-EntraEnterpriseAppInventory.
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateScript(
            { $_.PSObject.TypeNames -like 'EntraAppInventory.*' },
            ErrorMessage = 'Input must come from a Get-Entra*Inventory command in this module.'
        )]
        [PSCustomObject]$InputObject,

        # Folder to write into. Created if it does not exist; existing files with the same names are overwritten.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    begin {
        $records = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    process {
        $records.Add($InputObject)
    }

    end {
        # Each record type has different columns, so each gets its own CSV rather than one ragged file.
        $recordGroups = $records | Group-Object -Property { $_.PSObject.TypeNames[0] }
        foreach ($recordGroup in $recordGroups) {
            $typeName = $recordGroup.Name -replace '^EntraAppInventory\.'
            $detailFolder = Join-Path -Path $Path -ChildPath $typeName
            $csvPath = Join-Path -Path $Path -ChildPath "$typeName-Summary.csv"

            if ($PSCmdlet.ShouldProcess($Path, "Export [$($recordGroup.Count)] $typeName records")) {
                try {
                    $null = New-Item -ItemType Directory -Path $detailFolder -Force -ErrorAction Stop
                    $summaryRows = foreach ($record in $recordGroup.Group) {
                        $baseName = ConvertTo-SafeFileName -Name "$($record.AppId)-$($record.DisplayName)"
                        $fileName = "$baseName.json"
                        $jsonParameters = @{
                            LiteralPath = Join-Path -Path $detailFolder -ChildPath $fileName
                            Encoding    = 'utf8'
                            ErrorAction = 'Stop'
                        }
                        $record.Detail | ConvertTo-Json -Depth 10 | Set-Content @jsonParameters

                        $detailFileColumn = @{
                            Name       = 'DetailFile'
                            Expression = { Join-Path -Path $typeName -ChildPath $fileName }
                        }
                        $record | Select-Object -Property *, $detailFileColumn -ExcludeProperty Detail
                    }
                    $summaryRows | Export-Csv -LiteralPath $csvPath -Encoding utf8 -ErrorAction Stop
                    Get-Item -LiteralPath $csvPath -ErrorAction Stop
                }
                catch {
                    $PSCmdlet.ThrowTerminatingError($PSItem)
                }
            }
        }
    }
}
