#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Microsoft.Graph.Users.Actions'; ModuleVersion = '2.0.0' }

<#
.SYNOPSIS
    Writes a dated license availability report and emails an alert when any watched SKU runs low.
.DESCRIPTION
    Controller script meant to run daily as a scheduled task. Each run:

      1. Connects to Microsoft Graph app-only with a certificate when TenantId, ClientId, and
         CertificateThumbprint are given; otherwise uses the session that is already connected.
      2. Writes <yyyyMMdd>-LicenseAvailability.csv for every SKU to ReportFolder.
      3. Deletes earlier reports in ReportFolder last written more than RetentionDays ago.
      4. If any SKU in MinimumAvailable has fewer available units than its threshold, sends one alert from
         MailFrom to MailTo listing the low SKUs, with the full report attached. No mail is sent otherwise.

    Graph permissions needed (application permissions for an unattended run): Organization.Read.All and
    Mail.Send. Scope Mail.Send to the MailFrom mailbox with an Exchange Online application access policy or
    RBAC for Applications, so the app cannot send as any other mailbox.

    Outputs the report file that was written.
.EXAMPLE
    $checkParameters = @{
        ReportFolder          = '\\fileserver01\Reports\Licensing'
        MinimumAvailable      = @{ ENTERPRISEPACK = 200; EMS = 50 }
        MailFrom              = 'license-alerts@contoso.com'
        MailTo                = 'm365-admins@contoso.com'
        TenantId              = 'contoso.onmicrosoft.com'
        ClientId              = '00000000-0000-0000-0000-000000000000'
        CertificateThumbprint = '0000000000000000000000000000000000000000'
    }
    .\Invoke-LicenseAvailabilityCheck.ps1 @checkParameters

    Unattended run: writes today's report, prunes reports older than 30 days, and alerts if fewer than 200
    Office 365 E3 or 50 EMS licenses are left.
.EXAMPLE
    Connect-MgGraph -Scopes 'Organization.Read.All', 'Mail.Send'
    $checkParameters = @{
        ReportFolder     = 'D:\Reports'
        MinimumAvailable = @{ SPE_E5 = 10 }
        MailFrom         = 'jdoe@contoso.com'
        MailTo           = 'jdoe@contoso.com'
    }
    .\Invoke-LicenseAvailabilityCheck.ps1 @checkParameters -WhatIf

    Interactive dry run with an existing session: shows what would be written, deleted, and sent.
.LINK
    Get-EntraLicenseAvailability
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ExistingSession')]
[OutputType([System.IO.FileInfo])]
param(
    # Folder for the dated CSV reports. Must already exist.
    [Parameter(Mandatory)]
    [ValidateScript(
        { Test-Path -LiteralPath $_ -PathType Container },
        ErrorMessage = 'Folder [{0}] does not exist.'
    )]
    [string]$ReportFolder,

    # SKU part number to minimum available units, for example @{ ENTERPRISEPACK = 200 }. An alert is sent when
    # any listed SKU has fewer available units than its value.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [hashtable]$MinimumAvailable,

    # Address of the mailbox the alert is sent from.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MailFrom,

    # Alert recipients.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$MailTo,

    # Reports last written more than this many days ago are deleted.
    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 30,

    # Tenant id or initial domain, for an app-only connection.
    [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    # Application (client) id of the app registration, for an app-only connection.
    [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    # Thumbprint of the app's certificate in the running account's certificate store.
    [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
    [ValidateNotNullOrEmpty()]
    [string]$CertificateThumbprint
)

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\EntraLicenseReport.psd1') -ErrorAction Stop

if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
    $connectParameters = @{
        TenantId              = $TenantId
        ClientId              = $ClientId
        CertificateThumbprint = $CertificateThumbprint
        NoWelcome             = $true
        ErrorAction           = 'Stop'
    }
    Connect-MgGraph @connectParameters
}

$availability = @(Get-EntraLicenseAvailability -ErrorAction Stop)

$reportPath = Join-Path -Path $ReportFolder -ChildPath ('{0:yyyyMMdd}-LicenseAvailability.csv' -f (Get-Date))
if ($PSCmdlet.ShouldProcess($reportPath, 'Write license availability report')) {
    $availability | Export-Csv -LiteralPath $reportPath -Encoding utf8 -Confirm:$false -ErrorAction Stop
    Get-Item -LiteralPath $reportPath
}

# Prune by age rather than by the date in the name, so the cutoff is correct across a year boundary.
$cutoff = (Get-Date).Date.AddDays(-$RetentionDays)
$expiredReports = Get-ChildItem -LiteralPath $ReportFolder -File -Filter '????????-LicenseAvailability.csv' |
    Where-Object -Property LastWriteTime -LT -Value $cutoff
foreach ($expiredReport in $expiredReports) {
    if ($PSCmdlet.ShouldProcess($expiredReport.FullName, 'Delete expired report')) {
        Remove-Item -LiteralPath $expiredReport.FullName -Confirm:$false -ErrorAction Stop
    }
}

$availabilityBySku = @{}
foreach ($sku in $availability) {
    $availabilityBySku[$sku.SkuPartNumber] = $sku
}
$lowSkus = foreach ($watched in $MinimumAvailable.GetEnumerator()) {
    $sku = $availabilityBySku[$watched.Key]
    if ($null -eq $sku) {
        Write-Warning -Message "Watched SKU [$($watched.Key)] is not subscribed in this tenant."
        continue
    }
    if ($sku.AvailableUnits -lt $watched.Value) {
        [PSCustomObject]@{
            SkuPartNumber    = $sku.SkuPartNumber
            AvailableUnits   = $sku.AvailableUnits
            MinimumAvailable = $watched.Value
            EnabledUnits     = $sku.EnabledUnits
            ConsumedUnits    = $sku.ConsumedUnits
        }
    }
}

if (@($lowSkus).Count -eq 0) {
    Write-Verbose -Message 'All watched SKUs are at or above their thresholds; no alert sent.'
}
else {
    $subject = 'License availability below threshold: {0}' -f ($lowSkus.SkuPartNumber -join ', ')
    $body = $lowSkus | ConvertTo-Html -Fragment -PreContent "<p>$subject</p>" | Out-String
    $attachments = @(
        if (Test-Path -LiteralPath $reportPath) {
            @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                Name          = Split-Path -Path $reportPath -Leaf
                ContentType   = 'text/csv'
                ContentBytes  = [System.Convert]::ToBase64String(
                    (Get-Content -LiteralPath $reportPath -AsByteStream -Raw)
                )
            }
        }
    )
    $mail = @{
        Message         = @{
            Subject      = $subject
            Importance   = 'High'
            Body         = @{
                ContentType = 'HTML'
                Content     = $body
            }
            ToRecipients = @($MailTo.ForEach({ @{ EmailAddress = @{ Address = $_ } } }))
            Attachments  = $attachments
        }
        SaveToSentItems = $false
    }
    if ($PSCmdlet.ShouldProcess(($MailTo -join ', '), "Send low-license alert for [$($lowSkus.Count)] SKUs")) {
        Send-MgUserMail -UserId $MailFrom -BodyParameter $mail -ErrorAction Stop
    }
}
