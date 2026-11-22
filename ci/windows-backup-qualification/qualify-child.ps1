# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
#
# Runs as the separate STANDARD user that qualify-admin.ps1 created (Start-Process -Credential -LoadUserProfile).
# First it proves what it is: not an administrator, not elevated, no enabled backup or restore privilege, and its own
# profile and temporary folders (not the runner account's). Then it runs the harness with the runner's Python.
#   exit 10  the identity is not an ordinary user
#   exit 11  Python could not be run
#   else     the harness exit code (0 pass, 1 failed case, 3 unresolved case)
param(
    [Parameter(Mandatory = $true)][string]$Layout,
    [Parameter(Mandatory = $true)][string]$Results,
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [Parameter(Mandatory = $true)][string]$HarnessDir
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Results | Out-Null

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# whoami /all is the record the plan asks for
$all = (& whoami.exe /all | Out-String)
Write-Utf8NoBom (Join-Path $Results 'child-whoami-all.txt') $all

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

# whoami /priv /fo csv: "Privilege Name","Description","State"
$enabledBackupRestore = @()
$privileges = (& whoami.exe /priv /fo csv | Out-String) | ConvertFrom-Csv
foreach ($row in $privileges) {
    if (($row.'Privilege Name' -eq 'SeBackupPrivilege' -or $row.'Privilege Name' -eq 'SeRestorePrivilege') -and $row.State -eq 'Enabled') {
        $enabledBackupRestore += $row.'Privilege Name'
    }
}
# High mandatory level (S-1-16-12288) is an elevated token, whoever owns it
$elevated = $false
foreach ($group in $identity.Groups) {
    if ($group.Value -eq 'S-1-16-12288') { $elevated = $true }
}

$record = [ordered]@{
    name = $identity.Name
    sid = $identity.User.Value
    is_administrator = $isAdministrator
    elevated = $elevated
    enabled_backup_restore_privileges = @($enabledBackupRestore)
    userprofile = $env:USERPROFILE
    localappdata = $env:LOCALAPPDATA
    temp = $env:TEMP
    session_id = (Get-Process -Id $PID).SessionId
    powershell = $PSVersionTable.PSVersion.ToString()
    recorded = (Get-Date).ToUniversalTime().ToString('o')
}
Write-Utf8NoBom (Join-Path $Results 'child-identity.json') (ConvertTo-Json -InputObject $record -Depth 4)
Write-Host ("child identity: {0} administrator={1} elevated={2} backup/restore privileges enabled={3}" -f $identity.Name, $isAdministrator, $elevated, @($enabledBackupRestore).Count)

$layoutDocument = Get-Content -Raw -Path $Layout | ConvertFrom-Json
if ($isAdministrator -or $elevated -or @($enabledBackupRestore).Count -gt 0 -or $identity.Name -notlike "*\$($layoutDocument.username)") {
    Write-Host 'the child is not an ordinary user (or is not the user the administrator created)'
    exit 10
}
if (-not $env:LOCALAPPDATA -or $env:LOCALAPPDATA -notlike "*$($layoutDocument.username)*") {
    Write-Host "the child's own profile was not loaded: LOCALAPPDATA=$env:LOCALAPPDATA"
    exit 10
}

# native stderr text must not end the script (Windows PowerShell 5.1 turns it into an error record)
$ErrorActionPreference = 'Continue'
$python = & $PythonExe -X utf8 --version 2>&1 | Out-String
Write-Host "python: $($python.Trim())"
if ($LASTEXITCODE -ne 0) { exit 11 }
Write-Utf8NoBom (Join-Path $Results 'child-python.txt') $python

& $PythonExe -X utf8 (Join-Path $HarnessDir 'harness.py') --layout $Layout --results $Results 2>&1 |
    Tee-Object -FilePath (Join-Path $Results 'harness-console.txt')
exit $LASTEXITCODE
