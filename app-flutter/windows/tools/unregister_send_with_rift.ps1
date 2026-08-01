$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$verbPath = 'Software\Classes\*\shell\Rift.Send'
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($verbPath, $false)

Write-Host "Removed 'Send with Rift' for the current user."
