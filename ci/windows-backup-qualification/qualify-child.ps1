# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
#
# Runs as the separate STANDARD user that qualify-admin.ps1 created (Start-Process -Credential -LoadUserProfile).
# First it proves what it is: not an administrator (no administrators SID in the token in any form, deny-only
# included), not elevated, no enabled backup or restore privilege. It sets its profile and temporary folders from its
# own identity, checks them against the profile the system registered for its SID, and proves a temporary file can be
# created. Only then does it record the identity and run the harness with the runner's Python.
#   exit 10  the identity is not an ordinary user (or whoami output could not be read)
#   exit 11  Python could not be run
#   exit 12  the profile and temporary folders could not be established for this user
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

# Run a native command, keep its output and its exit code, never throw on stderr text.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

function Stop-Child([int]$Code, [string]$Message) {
    Write-Host $Message
    Write-Utf8NoBom (Join-Path $Results 'child-error.txt') ("exit $Code`r`n$Message`r`n")
    exit $Code
}

# The pure part of the privilege check, kept apart so it can be exercised with canned text: `whoami /priv /fo csv`
# has the columns "Privilege Name","Description","State"; returns the enabled backup or restore privileges, and throws
# when the text is not that table (an empty or unreadable answer is never "no privileges").
function Get-EnabledBackupRestore([string]$CsvText) {
    $rows = @($CsvText | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { throw 'whoami /priv returned no rows (every token holds at least SeChangeNotifyPrivilege)' }
    foreach ($column in @('Privilege Name', 'Description', 'State')) {
        if (-not ($rows[0].PSObject.Properties.Name -contains $column)) { throw "whoami /priv has no column '$column'" }
    }
    $enabled = @()
    foreach ($row in $rows) {
        if (($row.'Privilege Name' -eq 'SeBackupPrivilege' -or $row.'Privilege Name' -eq 'SeRestorePrivilege') -and $row.State -eq 'Enabled') {
            $enabled += $row.'Privilege Name'
        }
    }
    return , @($enabled)
}

# `whoami /groups /fo csv` has "Group Name","Type","SID","Attributes". Returns the rows naming the administrators group
# (S-1-5-32-544) in ANY form: enabled, disabled, deny-only, mandatory or not.
function Get-AdministratorGroupRows([string]$CsvText) {
    $rows = @($CsvText | ConvertFrom-Csv)
    if ($rows.Count -eq 0) { throw 'whoami /groups returned no rows (every token holds at least Everyone)' }
    foreach ($column in @('Group Name', 'Type', 'SID', 'Attributes')) {
        if (-not ($rows[0].PSObject.Properties.Name -contains $column)) { throw "whoami /groups has no column '$column'" }
    }
    $found = @()
    foreach ($row in $rows) {
        if ($row.SID -eq 'S-1-5-32-544') { $found += ('{0} [{1}]' -f $row.'Group Name', $row.Attributes) }
    }
    return , @($found)
}

# ----- identity -----
$all = Invoke-Native 'whoami.exe' @('/all')
Write-Utf8NoBom (Join-Path $Results 'child-whoami-all.txt') ("exit code $($all.Code)`r`n" + $all.Output)
if ($all.Code -ne 0) { Stop-Child 10 "whoami /all failed with exit code $($all.Code)" }

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

$groupsResult = Invoke-Native 'whoami.exe' @('/groups', '/fo', 'csv')
if ($groupsResult.Code -ne 0) { Stop-Child 10 "whoami /groups failed with exit code $($groupsResult.Code)" }
try { $administratorRows = Get-AdministratorGroupRows $groupsResult.Output } catch { Stop-Child 10 $_.Exception.Message }
# the token's own group list as well (a deny-only membership is listed there with its SID although IsInRole ignores it)
$administratorInToken = $false
foreach ($group in $identity.Groups) {
    if ($group.Value -eq 'S-1-5-32-544') { $administratorInToken = $true }
}
$hasAdministratorsSid = (@($administratorRows).Count -gt 0) -or $administratorInToken

$privilegesResult = Invoke-Native 'whoami.exe' @('/priv', '/fo', 'csv')
if ($privilegesResult.Code -ne 0) { Stop-Child 10 "whoami /priv failed with exit code $($privilegesResult.Code)" }
try { $enabledBackupRestore = Get-EnabledBackupRestore $privilegesResult.Output } catch { Stop-Child 10 $_.Exception.Message }

# High mandatory level (S-1-16-12288) is an elevated token, whoever owns it
$elevated = $false
foreach ($group in $identity.Groups) {
    if ($group.Value -eq 'S-1-16-12288') { $elevated = $true }
}

$layoutDocument = Get-Content -Raw -Path $Layout | ConvertFrom-Json
$sid = $identity.User.Value

# ----- profile and temporary folders, from this user's own identity -----
# -LoadUserProfile does not make the inherited environment variables name the new user: set them, then check them
# against the profile the system registered for this SID (a user name substring would prove nothing).
$profileEvidence = [ordered]@{ sid = $sid; ok = $false; error = '' }
try {
    $registered = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath).ProfileImagePath
    $registered = [Environment]::ExpandEnvironmentVariables($registered).TrimEnd('\')
    $profileEvidence.registered_profile_image_path = $registered
    $env:USERPROFILE = [Environment]::GetFolderPath('UserProfile')
    $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
    $env:APPDATA = [Environment]::GetFolderPath('ApplicationData')
    $env:TEMP = Join-Path $env:LOCALAPPDATA 'Temp'
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
    $profileEvidence.userprofile = $env:USERPROFILE
    $profileEvidence.localappdata = $env:LOCALAPPDATA
    $profileEvidence.appdata = $env:APPDATA
    $profileEvidence.temp = $env:TEMP
    if ($env:USERPROFILE.TrimEnd('\') -ne $registered) { throw "USERPROFILE $($env:USERPROFILE) is not the registered profile $registered" }
    foreach ($pair in @(@('LOCALAPPDATA', $env:LOCALAPPDATA), @('APPDATA', $env:APPDATA), @('TEMP', $env:TEMP))) {
        $inside = $pair[1].TrimEnd('\') + '\'
        if (-not $inside.StartsWith($registered + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$($pair[0]) $($pair[1]) is not inside the registered profile $registered"
        }
    }
    $probeFile = Join-Path $env:TEMP ('qualify-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($probeFile, 'temporary file creation works')
    if ([System.IO.File]::ReadAllText($probeFile) -ne 'temporary file creation works') { throw "the temporary file $probeFile reads back differently" }
    Remove-Item -LiteralPath $probeFile -Force
    $profileEvidence.temp_file_created = $true
    $profileEvidence.ok = $true
} catch {
    $profileEvidence.error = $_.Exception.Message
}
Write-Utf8NoBom (Join-Path $Results 'child-profile.json') (ConvertTo-Json -InputObject $profileEvidence -Depth 4)

$record = [ordered]@{
    name = $identity.Name
    sid = $sid
    is_administrator = $isAdministrator
    administrators_sid_in_token = $hasAdministratorsSid
    administrators_group_rows = @($administratorRows)
    elevated = $elevated
    enabled_backup_restore_privileges = @($enabledBackupRestore)
    userprofile = $env:USERPROFILE
    localappdata = $env:LOCALAPPDATA
    temp = $env:TEMP
    profile_verified = $profileEvidence.ok
    session_id = (Get-Process -Id $PID).SessionId
    powershell = $PSVersionTable.PSVersion.ToString()
    recorded = (Get-Date).ToUniversalTime().ToString('o')
}
Write-Utf8NoBom (Join-Path $Results 'child-identity.json') (ConvertTo-Json -InputObject $record -Depth 4)
Write-Host ("child identity: {0} administrator={1} administrators-sid={2} elevated={3} backup/restore privileges enabled={4} profile verified={5}" -f $identity.Name, $isAdministrator, $hasAdministratorsSid, $elevated, @($enabledBackupRestore).Count, $profileEvidence.ok)

if ($isAdministrator -or $hasAdministratorsSid -or $elevated -or @($enabledBackupRestore).Count -gt 0 -or $identity.Name -notlike "*\$($layoutDocument.username)") {
    Stop-Child 10 'the child is not an ordinary user (or is not the user the administrator created)'
}
if (-not $profileEvidence.ok) {
    Stop-Child 12 "the child's own profile could not be established: $($profileEvidence.error)"
}

# native stderr text must not end the script (Windows PowerShell 5.1 turns it into an error record)
$ErrorActionPreference = 'Continue'
$python = & $PythonExe -X utf8 --version 2>&1 | Out-String
$pythonCode = $LASTEXITCODE
Write-Host "python: $($python.Trim())"
if ($pythonCode -ne 0) { Stop-Child 11 "python exited with $pythonCode" }
Write-Utf8NoBom (Join-Path $Results 'child-python.txt') $python

& $PythonExe -X utf8 (Join-Path $HarnessDir 'harness.py') --layout $Layout --results $Results 2>&1 |
    Tee-Object -FilePath (Join-Path $Results 'harness-console.txt')
exit $LASTEXITCODE
