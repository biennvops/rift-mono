[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExternalLocation,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\app-flutter\build\rift-identity'),
    [string]$PackageName = 'Rift.Desktop',
    [string]$ApplicationId = 'Rift',
    [string]$Publisher = 'CN=Rift Development',
    [string]$PublisherDisplayName = 'Rift Development',
    [string]$DisplayName = 'Rift',
    [string]$Description = 'Rift desktop continuity client',
    [string]$Version = '1.0.0.0',
    [string]$CertificatePath,
    [System.Security.SecureString]$CertificatePassword,
    [string]$LogoPath = (Join-Path $PSScriptRoot '..\..\app-flutter\assets\dev.rift.Rift.png')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-WindowsSdkTool([string]$Name) {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    ) | Where-Object { $_ -and (Test-Path $_) }

    $tool = Get-ChildItem -Path $roots -Filter $Name -File -Recurse |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($null -eq $tool) {
        throw "Could not find $Name in the installed Windows SDK."
    }
    return $tool.FullName
}

function Escape-Xml([string]$Value) {
    return [System.Security.SecurityElement]::Escape($Value)
}

function Convert-SecureStringToPlainText([System.Security.SecureString]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function New-DevelopmentCertificate(
    [string]$Subject,
    [string]$PfxPath,
    [string]$CerPath,
    [ref]$Password
) {
    $existing = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
    if ($null -eq $existing) {
        $existing = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $Subject `
            -CertStoreLocation Cert:\CurrentUser\My `
            -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(2)
    }

    $generatedPassword = ConvertTo-SecureString `
        -String ([Guid]::NewGuid().ToString('N')) `
        -AsPlainText `
        -Force
    Export-PfxCertificate -Cert $existing -FilePath $PfxPath -Password $generatedPassword | Out-Null
    Export-Certificate -Cert $existing -FilePath $CerPath | Out-Null
    $Password.Value = $generatedPassword
    return $existing
}

function Trust-DevelopmentCertificate(
    [string]$CerPath
) {
    $trusted = Get-ChildItem Cert:\CurrentUser\Root |
        Where-Object { $_.Thumbprint -eq (Get-PfxCertificate -FilePath $CerPath).Thumbprint }
    if ($null -eq $trusted) {
        Import-Certificate -FilePath $CerPath -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    }
}

$externalPath = (Resolve-Path -LiteralPath $ExternalLocation).Path
$executablePath = Join-Path $externalPath 'Rift.exe'
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "ExternalLocation must contain Rift.exe: $externalPath"
}
if (-not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
    throw "Logo file was not found: $LogoPath"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stageDirectory = Join-Path $OutputDirectory 'package'
if (Test-Path -LiteralPath $stageDirectory) {
    Remove-Item -LiteralPath $stageDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $stageDirectory 'Assets') | Out-Null

$templatePath = Join-Path $PSScriptRoot '..\..\app-flutter\windows\identity\AppxManifest.template.xml'
$template = Get-Content -LiteralPath $templatePath -Raw
$replacements = @{
    '__PACKAGE_NAME__' = (Escape-Xml $PackageName)
    '__APPLICATION_ID__' = (Escape-Xml $ApplicationId)
    '__PUBLISHER__' = (Escape-Xml $Publisher)
    '__PUBLISHER_DISPLAY_NAME__' = (Escape-Xml $PublisherDisplayName)
    '__DISPLAY_NAME__' = (Escape-Xml $DisplayName)
    '__DESCRIPTION__' = (Escape-Xml $Description)
    '__VERSION__' = (Escape-Xml $Version)
}
foreach ($placeholder in $replacements.Keys) {
    $template = $template.Replace($placeholder, $replacements[$placeholder])
}
$manifestPath = Join-Path $stageDirectory 'AppxManifest.xml'
Set-Content -LiteralPath $manifestPath -Value $template -Encoding UTF8 -NoNewline
Copy-Item -LiteralPath $LogoPath -Destination (Join-Path $stageDirectory 'Assets\Rift.png')

$publisherXml = Escape-Xml $Publisher
$packageNameXml = Escape-Xml $PackageName
$applicationIdXml = Escape-Xml $ApplicationId
$runnerManifest = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="Rift" version="1.0.0.0" />
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <msix xmlns="urn:schemas-microsoft-com:msix.v1"
        publisher="$publisherXml"
        packageName="$packageNameXml"
        applicationId="$applicationIdXml" />
</assembly>
"@
# The side-by-side manifest is generated beside the exact executable used for
# registration, allowing -Publisher to remain a local development choice.
Set-Content -LiteralPath (Join-Path $externalPath 'Rift.exe.manifest') `
    -Value $runnerManifest -Encoding UTF8 -NoNewline

$signTool = Find-WindowsSdkTool 'signtool.exe'
$makeAppx = Find-WindowsSdkTool 'makeappx.exe'
$certificatePasswordPlain = ''
$certificateCerPath = $null
if ([string]::IsNullOrWhiteSpace($CertificatePath)) {
    $CertificatePath = Join-Path $OutputDirectory 'Rift.Development.pfx'
    $certificateCerPath = Join-Path $OutputDirectory 'Rift.Development.cer'
    $generatedPassword = $null
    New-DevelopmentCertificate `
        -Subject $Publisher `
        -PfxPath $CertificatePath `
        -CerPath $certificateCerPath `
        -Password ([ref]$generatedPassword) | Out-Null
    $CertificatePassword = $generatedPassword
    Trust-DevelopmentCertificate -CerPath $certificateCerPath
} elseif (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    throw "CertificatePath was not found: $CertificatePath"
} elseif ($null -eq $CertificatePassword) {
    throw 'CertificatePassword is required when CertificatePath is supplied.'
} else {
    if ([IO.Path]::GetExtension($CertificatePath).ToLowerInvariant() -ne '.pfx') {
        throw 'CertificatePath must point to a PFX containing a private signing key.'
    }
    $certificateCerPath = Join-Path $OutputDirectory 'Rift.Development.cer'
    $pfxData = Get-PfxData -FilePath $CertificatePath -Password $CertificatePassword
    $endEntity = $pfxData.EndEntityCertificates | Select-Object -First 1
    if ($null -eq $endEntity) {
        throw "No end-entity certificate was found in $CertificatePath."
    }
    Export-Certificate -Cert $endEntity -FilePath $certificateCerPath | Out-Null
    Trust-DevelopmentCertificate -CerPath $certificateCerPath
}
$certificatePasswordPlain = Convert-SecureStringToPlainText $CertificatePassword

$packagePath = Join-Path $OutputDirectory 'rift-identity.msix'
if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}
& $makeAppx pack /d $stageDirectory /p $packagePath /nv
if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE."
}
& $signTool sign /fd SHA256 /f $CertificatePath /p $certificatePasswordPlain $packagePath
if ($LASTEXITCODE -ne 0) {
    throw "SignTool failed with exit code $LASTEXITCODE."
}

Write-Host "Built signed identity package: $packagePath"
Write-Host "External location: $externalPath"
Write-Host "Publisher: $Publisher"
if ($null -ne $certificateCerPath) {
    Write-Host "Trusted development certificate: $certificateCerPath"
}
