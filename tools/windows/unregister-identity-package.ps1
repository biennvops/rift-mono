[CmdletBinding()]
param(
    [string]$PackageName = 'Rift.Desktop'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packages = @(Get-AppxPackage -Name $PackageName)
if ($packages.Count -eq 0) {
    Write-Host "No registered package found for $PackageName."
    exit 0
}

foreach ($package in $packages) {
    Remove-AppxPackage -Package $package.PackageFullName
    Write-Host "Unregistered $($package.PackageFullName)."
}
