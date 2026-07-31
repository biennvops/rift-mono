param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Release\app_flutter.exe')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
    throw "Rift executable not found at '$ExecutablePath'. Run 'flutter build windows' or pass -ExecutablePath."
}

$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$verbPath = 'Software\Classes\*\shell\Rift.Send'
$commandPath = "$verbPath\command"
$command = '"{0}" "%1"' -f $resolvedExecutable

$verbKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($verbPath)
try {
    $verbKey.SetValue('', 'Send with Rift', [Microsoft.Win32.RegistryValueKind]::String)
    $verbKey.SetValue('Icon', ('"{0}",0' -f $resolvedExecutable), [Microsoft.Win32.RegistryValueKind]::String)
    # Player mode lets Explorer invoke the verb for a multi-file selection.
    $verbKey.SetValue('MultiSelectModel', 'Player', [Microsoft.Win32.RegistryValueKind]::String)
}
finally {
    $verbKey.Dispose()
}

$commandKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($commandPath)
try {
    $commandKey.SetValue('', $command, [Microsoft.Win32.RegistryValueKind]::String)
}
finally {
    $commandKey.Dispose()
}

Write-Host "Registered 'Send with Rift' for the current user."
Write-Host "Executable: $resolvedExecutable"
