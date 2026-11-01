# Purview DLP: block Anyone links on files containing credit card numbers in SharePoint
# Run in Windows PowerShell with Business Premium + E5 Information Protection and Governance assigned.
# Install-Module ExchangeOnlineManagement -Scope CurrentUser   (once)

param(
    [Parameter(Mandatory)] [string] $AlertTo   # admin mailbox that receives DLP alerts
)

Connect-IPPSSession

New-DlpCompliancePolicy -Name "Lab - Card data external sharing" `
    -SharePointLocation All `
    -Mode Enable

New-DlpComplianceRule -Name "Lab - Block Anyone links on card data" `
    -Policy "Lab - Card data external sharing" `
    -ContentContainsSensitiveInformation @{Name = "Credit Card Number"; minCount = "1"} `
    -BlockAccess $true `
    -BlockAccessScope PerAnonymousUser `
    -NotifyUser Owner `
    -GenerateAlert $AlertTo `
    -GenerateIncidentReport $AlertTo `
    -ReportSeverityLevel High

Get-DlpCompliancePolicy "Lab - Card data external sharing" | Format-List Name, Mode, DistributionStatus
