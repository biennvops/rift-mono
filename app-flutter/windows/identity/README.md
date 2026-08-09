# Windows package identity

Rift's ordinary `flutter build windows` output is an unpackaged Win32 build. Windows notification-listener access additionally requires package identity and the `userNotificationListener` capability, so this directory contains a small sparse identity package for development builds.

The package uses Microsoft's package-with-external-location model. Rift's executable, Flutter DLLs, daemon binaries, and data remain in the Flutter build directory; the MSIX contains only the identity manifest and a logo.

## Development flow

From the repository root, build the Flutter Windows application and then package the exact directory containing `Rift.exe`:

```powershell
Push-Location ./app-flutter
flutter build windows --debug
Pop-Location
./tools/windows/build-identity-package.ps1 `
  -ExternalLocation (Resolve-Path ./app-flutter/build/windows/x64/runner/Debug)
./tools/windows/register-identity-package.ps1 `
  -PackagePath ./app-flutter/build/rift-identity/rift-identity.msix `
  -ExternalLocation (Resolve-Path ./app-flutter/build/windows/x64/runner/Debug)
```

The exact Flutter output directory can differ by Flutter version. Pass the directory that contains `Rift.exe`; the build script validates that path before packaging. The helper creates a local development certificate when `-CertificatePath` is omitted, exports only generated certificate artifacts below the output directory, and trusts the public certificate for the current user. Generated `.msix`, `.pfx`, `.cer`, and manifest files are ignored by Git.

To use an existing certificate:

```powershell
$certificatePassword = Read-Host 'PFX password' -AsSecureString
./tools/windows/build-identity-package.ps1 `
  -ExternalLocation 'C:/path/to/Rift/build' `
  -CertificatePath 'C:/secure/rift-dev.pfx' `
  -CertificatePassword $certificatePassword `
  -Publisher 'CN=Rift Development'
```

The publisher in the package manifest, the signing certificate subject, and the generated `Rift.exe.manifest` must match. The build helper writes the generated side-by-side executable manifest into the external location so a custom development publisher can be used without changing tracked files.

Register and unregister the package with:

```powershell
./tools/windows/register-identity-package.ps1 `
  -PackagePath ./app-flutter/build/rift-identity/rift-identity.msix `
  -ExternalLocation 'C:/path/to/Rift/build'
./tools/windows/test-package-identity.ps1 -PackageName Rift.Desktop
./tools/windows/unregister-identity-package.ps1 -PackageName Rift.Desktop
```

`MakeAppx.exe`, `SignTool.exe`, and `Add-AppxPackage -ExternalLocation` must be available from the Windows SDK/PowerShell installation. This is development signing only; production package signing and distribution are out of scope.

## Runtime requirements

The identity package requires Windows 10 version 2004 (build 19041) or later. An unpackaged build continues to work, but the native bridge reports `unpackaged` for Windows notification-source capture. Permission is still requested only by the explicit Settings action; registering the package does not silently grant notification access.
