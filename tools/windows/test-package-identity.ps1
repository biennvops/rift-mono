[CmdletBinding()]
param(
    [string]$PackageName = 'Rift.Desktop'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packages = @(Get-AppxPackage -Name $PackageName)
if ($packages.Count -eq 0) {
    Write-Error "No registered package found for $PackageName."
    exit 1
}

$packages |
    Select-Object Name, PackageFullName, Publisher, Version, InstallLocation |
    Format-List
Write-Host 'The package is registered. Launch Rift from its external location and verify getRuntimeStatus reports hasPackageIdentity=true.'
