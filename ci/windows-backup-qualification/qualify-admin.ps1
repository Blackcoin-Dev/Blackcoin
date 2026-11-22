# Copyright (c) 2026 The Blackcoin developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.
#
# Administrator side of the Windows backup qualification (Windows PowerShell 5.1, run by the hosted runner's
# administrator account):
#   -Action Run       set everything up, run the child harness as a separate STANDARD user, collect the results, and
#                     always tear down again (try/finally)
#   -Action Teardown  idempotent clean-up only (the workflow also calls it from an `if: always()` step)
#
# What only an administrator can do is done here: create the local standard user, prepare the NTFS and FAT32 VHDs
# with diskpart, create the share and the ACLs. Everything that is being qualified runs in qualify-child.ps1 as that
# user. Regtest only; no private data.
param(
    [Parameter(Mandatory = $true)][ValidateSet('Run', 'Teardown')][string]$Action,
    [string]$Root = 'C:\q',
    [string]$PayloadDir,     # directory with the verified portable payload (blackcoind.exe and the other executables)
    [string]$ProbeExe,       # flush_probe.exe, already hash-verified
    [string]$HarnessDir,     # ci/windows-backup-qualification of the qualifying branch
    [string]$PythonExe,      # the runner's python.exe
    [string]$ResultsOut      # where the results are copied to, outside $Root
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$UserName = 'qbackup'
$ShareName = 'QBackup'
$NtfsLabel = 'QNTFS'
$FatLabel = 'QFAT'
$NtfsVhd = Join-Path $Root 'ntfs.vhd'
$FatVhd = Join-Path $Root 'fat32.vhd'
$ChildTimeoutMinutes = 35

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
    return [pscustomobject]@{ Code = $code; Output = $output.Trim() }
}

function Invoke-Diskpart([string]$Name, [string[]]$Lines) {
    $script = Join-Path $Root ($Name + '.txt')
    Write-Utf8NoBom $script (($Lines -join "`r`n") + "`r`n")
    $result = Invoke-Native 'diskpart.exe' @('/s', $script)
    Write-Host "diskpart $Name exit code $($result.Code)"
    Write-Host $result.Output
    return $result
}

function Get-FreeLetter([string[]]$Preferred, [string[]]$Taken) {
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }) + $Taken
    foreach ($letter in $Preferred) {
        if ($used -notcontains $letter) { return $letter }
    }
    throw "no free drive letter among $($Preferred -join ',')"
}

function Remove-Vhd([string]$Path) {
    if (Test-Path $Path) {
        $name = 'detach-' + [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $null = Invoke-Diskpart $name @("select vdisk file=`"$Path`"", 'detach vdisk')
        Remove-Item -Force -ErrorAction SilentlyContinue $Path
    }
}

function Invoke-Teardown {
    Write-Host '--- teardown'
    Get-Process -Name blackcoind -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $Root) {
        Remove-Vhd $NtfsVhd
        Remove-Vhd $FatVhd
    }
    $null = Invoke-Native 'net.exe' @('share', $ShareName, '/delete', '/y')
    if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "*\$UserName" } |
        ForEach-Object { Remove-CimInstance $_ -ErrorAction SilentlyContinue }
    if (Test-Path $Root) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Root
        if (Test-Path $Root) {
            Start-Sleep -Seconds 5
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Root
        }
    }
    Write-Host ("teardown: root present = {0}, user present = {1}" -f (Test-Path $Root),
        [bool](Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue))
}

if ($Action -eq 'Teardown') {
    Invoke-Teardown
    exit 0
}

foreach ($required in @($PayloadDir, $ProbeExe, $HarnessDir, $PythonExe, $ResultsOut)) {
    if (-not $required) { throw 'Run needs -PayloadDir -ProbeExe -HarnessDir -PythonExe -ResultsOut' }
}
$exitCode = 1
try {
    # ----- layout on disk -----
    Invoke-Teardown            # a clean start, whatever an earlier run left
    $Bin = Join-Path $Root 'bin'
    $Harness = Join-Path $Root 'harness'
    $ResultsDir = Join-Path $Root 'results'
    $Cases = Join-Path $Root 'cases'
    $ShareDir = Join-Path $Root 'share'
    $NtfsMountDatadir = Join-Path $Cases 'mounted\data'
    $NtfsMount = Join-Path $NtfsMountDatadir 'regtest\mounted'
    $FatMountDatadir = Join-Path $Cases 'fat32\data'
    $FatMount = Join-Path $FatMountDatadir 'regtest\fatmount'
    foreach ($directory in @($Root, $Bin, $Harness, $ResultsDir, $Cases, $ShareDir, $NtfsMount, $FatMount)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Copy-Item -Path (Join-Path $PayloadDir '*') -Destination $Bin -Recurse -Force
    Copy-Item -Path $ProbeExe -Destination (Join-Path $Bin 'flush_probe.exe') -Force
    Copy-Item -Path (Join-Path $HarnessDir 'harness.py') -Destination $Harness -Force
    Copy-Item -Path (Join-Path $HarnessDir 'qualify-child.ps1') -Destination $Harness -Force
    $Daemon = Join-Path $Bin 'blackcoind.exe'
    if (-not (Test-Path $Daemon)) { throw "blackcoind.exe is not in $Bin" }

    # ----- the separate standard user (the plan's PowerShell) -----
    $plain = 'Qq1!' + [guid]::NewGuid()
    Write-Host "::add-mask::$plain"
    $pw = ConvertTo-SecureString $plain -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $pw -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $UserName
    $user = "$env:COMPUTERNAME\$UserName"
    $cred = New-Object System.Management.Automation.PSCredential($user, $pw)

    # The user may write to the root (cases, results, share); the binaries and scripts are readable, not writable.
    $null = Invoke-Native 'icacls.exe' @($Root, '/grant', "${user}:(OI)(CI)M")
    foreach ($locked in @($Bin, $Harness)) {
        $r = Invoke-Native 'icacls.exe' @($locked, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', "${user}:(OI)(CI)RX")
        if ($r.Code -ne 0) { throw "icacls on $locked failed: $($r.Output)" }
    }
    try { Start-Service seclogon } catch { Write-Host "seclogon: $($_.Exception.Message)" }

    # ----- letters and infrastructure -----
    $NtfsLetter = Get-FreeLetter @('V', 'W', 'X', 'Y') @()
    $SubstLetter = Get-FreeLetter @('Q', 'P', 'O') @($NtfsLetter)
    $MappedLetter = Get-FreeLetter @('R', 'S', 'T') @($NtfsLetter, $SubstLetter)
    $infra = [ordered]@{
        ntfs_vhd = $false; ntfs_vhd_error = ''; fat32_vhd = $false; fat32_vhd_error = ''; share = $false; share_error = ''
    }
    try {
        $lines = @(
            "create vdisk file=`"$NtfsVhd`" maximum=256 type=expandable", "select vdisk file=`"$NtfsVhd`"", 'attach vdisk',
            'create partition primary', "format fs=ntfs quick label=$NtfsLabel", "assign letter=$NtfsLetter",
            "assign mount=`"$NtfsMount`"")
        $r = Invoke-Diskpart 'vhd-ntfs' $lines
        if ($r.Code -ne 0) { throw "diskpart failed: $($r.Output)" }
        Start-Sleep -Seconds 3
        $volume = Get-Volume -FileSystemLabel $NtfsLabel
        if ($volume.FileSystem -ne 'NTFS' -or "$($volume.DriveType)" -ne 'Fixed') {
            throw "the VHD volume is $($volume.FileSystem) / $($volume.DriveType)"
        }
        $access = (Get-Partition -DriveLetter $NtfsLetter).AccessPaths
        if (@($access | Where-Object { $_ -like "$NtfsMount*" }).Count -eq 0) { throw "the mount path is not an access path: $access" }
        $null = Invoke-Native 'icacls.exe' @("${NtfsLetter}:\", '/grant', "${user}:(OI)(CI)M")
        $infra.ntfs_vhd = $true
    } catch {
        $infra.ntfs_vhd_error = $_.Exception.Message
        Write-Host "::warning::NTFS VHD setup failed: $($infra.ntfs_vhd_error)"
    }
    try {
        $lines = @(
            "create vdisk file=`"$FatVhd`" maximum=256 type=expandable", "select vdisk file=`"$FatVhd`"", 'attach vdisk',
            'create partition primary', "format fs=fat32 quick label=$FatLabel", "assign mount=`"$FatMount`"")
        $r = Invoke-Diskpart 'vhd-fat32' $lines
        if ($r.Code -ne 0) { throw "diskpart failed: $($r.Output)" }
        Start-Sleep -Seconds 3
        $volume = Get-Volume -FileSystemLabel $FatLabel
        if ($volume.FileSystem -ne 'FAT32') { throw "the VHD volume is $($volume.FileSystem)" }
        $infra.fat32_vhd = $true
    } catch {
        $infra.fat32_vhd_error = $_.Exception.Message
        Write-Host "::warning::FAT32 VHD setup failed: $($infra.fat32_vhd_error)"
    }
    try {
        $r = Invoke-Native 'net.exe' @('share', "$ShareName=$ShareDir", "/grant:$UserName,FULL")
        if ($r.Code -ne 0) { throw "net share failed: $($r.Output)" }
        $infra.share = $true
    } catch {
        $infra.share_error = $_.Exception.Message
        Write-Host "::warning::share setup failed: $($infra.share_error)"
    }

    $layout = [ordered]@{
        root = $Root; user = $user; username = $UserName; bin = $Bin; results = $ResultsDir; cases = $Cases
        daemon = $Daemon; probe = (Join-Path $Bin 'flush_probe.exe')
        ntfs_letter = $NtfsLetter; ntfs_mount = $NtfsMount; ntfs_mount_datadir = $NtfsMountDatadir
        fat_mount = $FatMount; fat_mount_datadir = $FatMountDatadir
        share_unc = "\\localhost\$ShareName"; share_dir = $ShareDir
        subst_letter = $SubstLetter; mapped_letter = $MappedLetter; infra = $infra
    }
    $LayoutPath = Join-Path $Harness 'layout.json'
    Write-Utf8NoBom $LayoutPath ($layout | ConvertTo-Json -Depth 5)
    $null = Invoke-Native 'icacls.exe' @($LayoutPath, '/grant', "${user}:R")

    # ----- evidence recorded as the administrator -----
    $evidence = Join-Path $ResultsDir 'admin-evidence'
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    $os = Get-CimInstance Win32_OperatingSystem
    $info = [ordered]@{
        image_os = $env:ImageOS; image_version = $env:ImageVersion; os_caption = $os.Caption; os_build = $os.BuildNumber
        computer = $env:COMPUTERNAME; runner_user = $env:USERNAME; ntfs_letter = $NtfsLetter; subst_letter = $SubstLetter; mapped_letter = $MappedLetter; infra = $infra
        started = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-Utf8NoBom (Join-Path $evidence 'runner-info.json') ($info | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom (Join-Path $evidence 'runner-whoami-all.txt') ((Invoke-Native 'whoami.exe' @('/all')).Output)
    Write-Utf8NoBom (Join-Path $evidence 'volumes.txt') ((Get-Volume | Format-Table -AutoSize | Out-String))
    Write-Utf8NoBom (Join-Path $evidence 'icacls-root.txt') ((Invoke-Native 'icacls.exe' @($Root)).Output + "`r`n" + (Invoke-Native 'icacls.exe' @("$env:SystemDrive\")).Output)
    Write-Utf8NoBom (Join-Path $evidence 'daemon-version.txt') ((Invoke-Native $Daemon @('--version')).Output)

    # ----- the child, as the standard user -----
    $ChildScript = Join-Path $Harness 'qualify-child.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ChildScript`" -Layout `"$LayoutPath`" -Results `"$ResultsDir`" -PythonExe `"$PythonExe`" -HarnessDir `"$Harness`""
    Write-Host "starting the child as $user"
    $p = Start-Process -FilePath 'powershell.exe' -Credential $cred -LoadUserProfile -WorkingDirectory $Root `
        -ArgumentList $arguments -Wait -PassThru
    $childCode = $null
    try { $childCode = $p.ExitCode } catch { Write-Host "the child's exit code is not readable: $($_.Exception.Message)" }
    Write-Host "child exit code: $childCode"

    # ----- verdict: the child's own identity check and the harness summary (the exit code alone is not trusted) -----
    $identityPath = Join-Path $ResultsDir 'child-identity.json'
    $summaryPath = Join-Path $ResultsDir 'summary.json'
    if (-not (Test-Path $identityPath)) { throw 'the child recorded no identity: it did not run as a standard user' }
    $identity = Get-Content -Raw $identityPath | ConvertFrom-Json
    if ($identity.is_administrator -or $identity.elevated -or @($identity.enabled_backup_restore_privileges).Count -gt 0) {
        throw 'the child is an administrator or holds backup/restore privileges'
    }
    if (-not (Test-Path $summaryPath)) { throw 'the harness wrote no summary' }
    $summary = Get-Content -Raw $summaryPath | ConvertFrom-Json
    $listed = Invoke-Native $PythonExe @((Join-Path $Harness 'harness.py'), '--list')
    $expectedCases = @($listed.Output -split "`n" | Where-Object { $_.Trim() }).Count
    Write-Host ("summary: passed={0} failed={1} unresolved={2} of {3} cases" -f $summary.passed, $summary.failed, $summary.unresolved, $expectedCases)
    if ($summary.failed -ne 0 -or $summary.unresolved -ne 0 -or $summary.passed -ne $expectedCases) {
        throw 'the qualification did not pass every case (failed or unresolved cases fail the job)'
    }
    if (($null -ne $childCode) -and ($childCode -ne 0)) { throw "the child exited with $childCode" }
    $exitCode = 0
} catch {
    Write-Host "::error::$($_.Exception.Message)"
    $exitCode = 1
} finally {
    # results first (outside the root), then the clean-up
    try {
        if (Test-Path (Join-Path $Root 'results')) {
            New-Item -ItemType Directory -Force -Path $ResultsOut | Out-Null
            Copy-Item -Path (Join-Path $Root 'results\*') -Destination $ResultsOut -Recurse -Force
        }
    } catch {
        Write-Host "::warning::copying the results failed: $($_.Exception.Message)"
    }
    try { Invoke-Teardown } catch { Write-Host "::warning::teardown: $($_.Exception.Message)" }
}
exit $exitCode
