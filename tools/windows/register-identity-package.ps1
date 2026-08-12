[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$ExternalLocation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$package = (Resolve-Path -LiteralPath $PackagePath).Path
$externalPath = (Resolve-Path -LiteralPath $ExternalLocation).Path
if ([IO.Path]::GetExtension($package).ToLowerInvariant() -ne '.msix') {
    throw "PackagePath must point to an MSIX file: $package"
}
if (-not (Test-Path -LiteralPath (Join-Path $externalPath 'Rift.exe') -PathType Leaf)) {
    throw "ExternalLocation must contain Rift.exe: $externalPath"
}

Add-AppxPackage -Path $package -ExternalLocation $externalPath
Write-Host "Registered package with external location: $externalPath"
