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
# The hosted job allows 60 minutes and the qualifying step 45: the child gets 30, which leaves time for the collection of
# the results, the clean-up and the always-run upload steps even when the child has to be killed.
$ChildTimeoutMinutes = 30
$script:DiskpartLogDir = $null

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

# A native command that must succeed: its exit code is checked here and a failure ends the step with the output.
function Invoke-Checked([string]$What, [string]$File, [string[]]$Arguments) {
    $result = Invoke-Native $File $Arguments
    if ($result.Code -ne 0) { throw "$What failed with exit code $($result.Code): $($result.Output)" }
    return $result
}

# The script and the output (with the exit code) of every diskpart run are kept with the results.
function Invoke-Diskpart([string]$Name, [string[]]$Lines) {
    $script = Join-Path $Root ($Name + '.txt')
    $text = ($Lines -join "`r`n") + "`r`n"
    Write-Utf8NoBom $script $text
    $result = Invoke-Native 'diskpart.exe' @('/s', $script)
    Write-Host "diskpart $Name exit code $($result.Code)"
    Write-Host $result.Output
    if ($script:DiskpartLogDir -and (Test-Path $script:DiskpartLogDir)) {
        Write-Utf8NoBom (Join-Path $script:DiskpartLogDir ($Name + '.script.txt')) $text
        Write-Utf8NoBom (Join-Path $script:DiskpartLogDir ($Name + '.output.txt')) ("exit code $($result.Code)`r`n" + $result.Output + "`r`n")
    }
    return $result
}

function Get-FreeLetter([string[]]$Preferred, [string[]]$Taken) {
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }) + $Taken
    foreach ($letter in $Preferred) {
        if ($used -notcontains $letter) { return $letter }
    }
    throw "no free drive letter among $($Preferred -join ',')"
}

# Detach and delete a VHD. The diskpart exit code is recorded; the outcome (the file is gone) decides.
function Remove-Vhd([string]$Path, [System.Collections.ArrayList]$Steps, [System.Collections.ArrayList]$Failures) {
    if (Test-Path $Path) {
        $name = 'detach-' + [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $r = Invoke-Diskpart $name @("select vdisk file=`"$Path`"", 'detach vdisk')
        $null = $Steps.Add([ordered]@{ step = $name; exit_code = $r.Code; output = $r.Output })
        Remove-Item -Force -ErrorAction SilentlyContinue $Path
        if (Test-Path $Path) {
            Start-Sleep -Seconds 3
            Remove-Item -Force -ErrorAction SilentlyContinue $Path
        }
        if (Test-Path $Path) { $null = $Failures.Add("$Path could not be removed after detach (diskpart exit code $($r.Code))") }
    }
}

# Idempotent clean-up. Returns what it did and what it could not do; the caller puts that into the final receipt.
function Invoke-Teardown {
    # -KeepResults is used only after a failed copy of the results: everything but $Root\results is removed, so the
    # workflow's upload of C:\q\results can still recover the evidence; the workflow's last step removes the rest
    param([switch]$KeepResults)
    Write-Host "--- teardown (keep results: $KeepResults)"
    $steps = New-Object System.Collections.ArrayList
    $failures = New-Object System.Collections.ArrayList
    try {
        $running = @(Get-Process -Name blackcoind -ErrorAction SilentlyContinue)
        foreach ($process in $running) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
        $null = $steps.Add([ordered]@{ step = 'stop-blackcoind'; stopped = $running.Count })
    } catch {
        $null = $failures.Add("stopping blackcoind: $($_.Exception.Message)")
    }
    if (Test-Path $Root) {
        Remove-Vhd $NtfsVhd $steps $failures
        Remove-Vhd $FatVhd $steps $failures
    }
    $share = Invoke-Native 'net.exe' @('share', $ShareName, '/delete', '/y')
    $null = $steps.Add([ordered]@{ step = 'net-share-delete'; exit_code = $share.Code; output = $share.Output })
    # exit code 2 with message 2310 means the share did not exist, which is the clean state
    if ($share.Code -ne 0 -and $share.Output -notmatch '2310') {
        $null = $failures.Add("net share delete exited with $($share.Code): $($share.Output)")
    }
    try {
        if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $UserName -ErrorAction Stop }
    } catch {
        $null = $failures.Add("removing the local user: $($_.Exception.Message)")
    }
    try {
        Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { $_.LocalPath -like "*\$UserName" } |
            ForEach-Object { Remove-CimInstance $_ -ErrorAction Stop }
    } catch {
        $null = $failures.Add("removing the user profile: $($_.Exception.Message)")
    }
    $keptResults = Join-Path $Root 'results'
    $removeRoot = {
        if ($KeepResults) {
            Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $keptResults } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Root
        }
    }
    if (Test-Path $Root) {
        & $removeRoot
        $leftovers = if ($KeepResults) { @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $keptResults }) } else { @(if (Test-Path $Root) { $Root }) }
        if ($leftovers.Count -gt 0) {
            Start-Sleep -Seconds 5
            & $removeRoot
        }
    }
    $rootPresent = if ($KeepResults) {
        @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $keptResults }).Count -gt 0
    } else { [bool](Test-Path $Root) }
    $userPresent = [bool](Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)
    $sharePresent = [bool](Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue)
    if ($rootPresent) { $null = $failures.Add("$Root is still present (apart from the preserved results)") }
    if ($userPresent) { $null = $failures.Add("the local user $UserName is still present") }
    if ($sharePresent) { $null = $failures.Add("the share $ShareName is still present") }
    Write-Host ("teardown: root present = {0}, user present = {1}, share present = {2}, failures = {3}" -f $rootPresent, $userPresent, $sharePresent, $failures.Count)
    foreach ($failure in $failures) { Write-Host "::error::teardown: $failure" }
    return [pscustomobject]@{
        root_present = $rootPresent; results_preserved = [bool]$KeepResults; user_present = $userPresent; share_present = $sharePresent
        failures = @($failures); steps = @($steps)
    }
}

if ($Action -eq 'Teardown') {
    $outcome = Invoke-Teardown
    if (@($outcome.failures).Count -gt 0) { exit 1 }
    exit 0
}

foreach ($required in @($PayloadDir, $ProbeExe, $HarnessDir, $PythonExe, $ResultsOut)) {
    if (-not $required) { throw 'Run needs -PayloadDir -ProbeExe -HarnessDir -PythonExe -ResultsOut' }
}
$exitCode = 1
$timedOut = $false
$teardownOutcome = $null
$copyProblem = ''
try {
    # ----- layout on disk -----
    $start = Invoke-Teardown            # a clean start, whatever an earlier run left
    if (@($start.failures).Count -gt 0) { throw "the clean start failed: $(@($start.failures) -join '; ')" }
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
    $evidence = Join-Path $ResultsDir 'admin-evidence'
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    $script:DiskpartLogDir = Join-Path $ResultsDir 'diskpart'
    New-Item -ItemType Directory -Force -Path $script:DiskpartLogDir | Out-Null
    $setupLog = New-Object System.Collections.ArrayList
    Copy-Item -Path (Join-Path $PayloadDir '*') -Destination $Bin -Recurse -Force
    Copy-Item -Path $ProbeExe -Destination (Join-Path $Bin 'flush_probe.exe') -Force
    Copy-Item -Path (Join-Path $HarnessDir 'harness.py') -Destination $Harness -Force
    Copy-Item -Path (Join-Path $HarnessDir 'qualify-child.ps1') -Destination $Harness -Force
    $Daemon = Join-Path $Bin 'blackcoind.exe'
    if (-not (Test-Path $Daemon)) { throw "blackcoind.exe is not in $Bin" }

    # ----- hashes of what is being run: the harness files, the probe, every payload file -----
    $hashLines = New-Object System.Collections.ArrayList
    foreach ($name in @('harness.py', 'qualify-child.ps1', 'qualify-admin.ps1', 'verify_inputs.py', 'build-probe.sh', 'flush_probe.cpp', 'README.md')) {
        $file = Join-Path $HarnessDir $name
        if (Test-Path $file) { $null = $hashLines.Add(('{0}  harness/{1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLower(), $name)) }
    }
    # the copies the child actually runs must be the ones hashed above
    foreach ($name in @('harness.py', 'qualify-child.ps1')) {
        $source = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $HarnessDir $name)).Hash
        $copy = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Harness $name)).Hash
        if ($source -ne $copy) { throw "the staged $name differs from the qualifying branch's file" }
    }
    $null = $hashLines.Add(('{0}  probe/flush_probe.exe' -f (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Bin 'flush_probe.exe')).Hash.ToLower()))
    foreach ($file in (Get-ChildItem -LiteralPath $Bin -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Bin.Length).TrimStart('\')
        $null = $hashLines.Add(('{0}  payload/{1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLower(), $relative))
    }
    Write-Utf8NoBom (Join-Path $evidence 'sha256-harness-probe-payload.txt') (($hashLines -join "`r`n") + "`r`n")

    # ----- the separate standard user (the plan's PowerShell) -----
    $plain = 'Qq1!' + [guid]::NewGuid()
    Write-Host "::add-mask::$plain"
    $pw = ConvertTo-SecureString $plain -AsPlainText -Force
    New-LocalUser -Name $UserName -Password $pw -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $UserName
    $user = "$env:COMPUTERNAME\$UserName"
    $cred = New-Object System.Management.Automation.PSCredential($user, $pw)

    # The user may write to the root (cases, results, share); the binaries and scripts are readable, not writable.
    $null = Invoke-Checked "icacls grant on $Root" 'icacls.exe' @($Root, '/grant', "${user}:(OI)(CI)M")
    foreach ($locked in @($Bin, $Harness)) {
        $null = Invoke-Checked "icacls lock-down of $locked" 'icacls.exe' @($locked, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', "${user}:(OI)(CI)RX")
    }

    # Secondary Logon must be running for Start-Process -Credential: enable it when disabled, start it, verify it.
    $seclogon = Get-CimInstance Win32_Service -Filter "Name='seclogon'"
    if (-not $seclogon) { throw 'the Secondary Logon service (seclogon) does not exist on this runner' }
    $null = $setupLog.Add("seclogon before: start mode $($seclogon.StartMode), state $($seclogon.State)")
    if ($seclogon.StartMode -eq 'Disabled') {
        Set-Service -Name seclogon -StartupType Manual
        $null = $setupLog.Add('seclogon: start mode changed from Disabled to Manual')
    }
    $service = Get-Service -Name seclogon
    if ($service.Status -ne 'Running') { Start-Service -Name seclogon }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    $service.Refresh()
    if ($service.Status -ne 'Running') { throw "the Secondary Logon service is $($service.Status), not Running" }
    $null = $setupLog.Add("seclogon after: state $($service.Status)")
    Write-Host ($setupLog -join '; ')

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
        $null = Invoke-Checked "icacls grant on ${NtfsLetter}:\" 'icacls.exe' @("${NtfsLetter}:\", '/grant', "${user}:(OI)(CI)M")
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
        $null = Invoke-Checked 'net share' 'net.exe' @('share', "$ShareName=$ShareDir", "/grant:$UserName,FULL")
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
    $null = Invoke-Checked "icacls read grant on $LayoutPath" 'icacls.exe' @($LayoutPath, '/grant', "${user}:R")

    # ----- evidence recorded as the administrator (every command's exit code is checked) -----
    $os = Get-CimInstance Win32_OperatingSystem
    $info = [ordered]@{
        image_os = $env:ImageOS; image_version = $env:ImageVersion; os_caption = $os.Caption; os_build = $os.BuildNumber
        computer = $env:COMPUTERNAME; runner_user = $env:USERNAME; ntfs_letter = $NtfsLetter; subst_letter = $SubstLetter; mapped_letter = $MappedLetter; infra = $infra
        setup_log = @($setupLog); child_timeout_minutes = $ChildTimeoutMinutes
        started = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-Utf8NoBom (Join-Path $evidence 'runner-info.json') ($info | ConvertTo-Json -Depth 5)
    Write-Utf8NoBom (Join-Path $evidence 'runner-whoami-all.txt') ((Invoke-Checked 'whoami /all' 'whoami.exe' @('/all')).Output)
    Write-Utf8NoBom (Join-Path $evidence 'volumes.txt') ((Get-Volume | Format-List * | Out-String))
    Write-Utf8NoBom (Join-Path $evidence 'partitions.json') (@(Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, Size, GptType, AccessPaths) | ConvertTo-Json -Depth 4)
    $aclText = New-Object System.Collections.ArrayList
    foreach ($target in @($Root, "$env:SystemDrive\", $Bin, $Harness, $NtfsMountDatadir, $NtfsMount, $ShareDir)) {   # FAT32 has no ACLs, so it is not listed
        if (Test-Path -LiteralPath $target) {
            $acl = Invoke-Checked "icacls $target" 'icacls.exe' @($target)
            $null = $aclText.Add("--- $target`r`n$($acl.Output)")
        }
    }
    if ($infra.ntfs_vhd) {
        $acl = Invoke-Checked "icacls ${NtfsLetter}:\" 'icacls.exe' @("${NtfsLetter}:\")
        $null = $aclText.Add("--- ${NtfsLetter}:\`r`n$($acl.Output)")
        $null = $aclText.Add("--- fsutil volumeinfo of the NTFS mount`r`n" + (Invoke-Checked 'fsutil volumeinfo (NTFS)' 'fsutil.exe' @('fsinfo', 'volumeinfo', "${NtfsLetter}:\")).Output)
    }
    if ($infra.fat32_vhd) {
        $null = $aclText.Add("--- fsutil volumeinfo of the FAT32 mount`r`n" + (Invoke-Checked 'fsutil volumeinfo (FAT32)' 'fsutil.exe' @('fsinfo', 'volumeinfo', "$FatMount\")).Output)
    }
    Write-Utf8NoBom (Join-Path $evidence 'icacls-and-volume-details.txt') (($aclText -join "`r`n`r`n") + "`r`n")
    Write-Utf8NoBom (Join-Path $evidence 'daemon-version.txt') ((Invoke-Checked 'blackcoind --version' $Daemon @('--version')).Output)

    # ----- the child, as the standard user, with a deadline -----
    $ChildScript = Join-Path $Harness 'qualify-child.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ChildScript`" -Layout `"$LayoutPath`" -Results `"$ResultsDir`" -PythonExe `"$PythonExe`" -HarnessDir `"$Harness`""
    Write-Host "starting the child as $user (deadline $ChildTimeoutMinutes minutes)"
    $childStarted = Get-Date
    $p = Start-Process -FilePath 'powershell.exe' -Credential $cred -LoadUserProfile -WorkingDirectory $Root `
        -ArgumentList $arguments -PassThru
    $null = $p.Handle          # keeps the process handle open, which is what makes ExitCode readable after the exit
    $finished = $p.WaitForExit($ChildTimeoutMinutes * 60 * 1000)
    $killOutput = ''
    if (-not $finished) {
        $timedOut = $true
        Write-Host "::error::the child did not finish within $ChildTimeoutMinutes minutes: terminating its process tree"
        $kill = Invoke-Native 'taskkill.exe' @('/T', '/F', '/PID', "$($p.Id)")
        $killOutput = "taskkill exit code $($kill.Code): $($kill.Output)"
        Write-Host $killOutput
        $null = $p.WaitForExit(60000)
    } else {
        $p.WaitForExit()       # lets the redirected streams and the exit code settle
    }
    $childCode = $null
    $rawExitCode = $p.ExitCode      # read it as is: a cast of $null to [int] would silently become 0
    if ($null -ne $rawExitCode) {
        try { $childCode = [int]$rawExitCode } catch { Write-Host "the child's exit code is not readable: $($_.Exception.Message)" }
    } else {
        Write-Host "the child's exit code is not readable: it is null"
    }
    Write-Host "child exit code: $childCode (timed out: $timedOut)"
    $childRun = [ordered]@{
        started = $childStarted.ToUniversalTime().ToString('o'); finished = (Get-Date).ToUniversalTime().ToString('o')
        timeout_minutes = $ChildTimeoutMinutes; timed_out = $timedOut; exit_code = $childCode; kill = $killOutput
    }
    Write-Utf8NoBom (Join-Path $evidence 'child-run.json') ($childRun | ConvertTo-Json -Depth 3)
    if ($timedOut) { throw "the child exceeded its $ChildTimeoutMinutes minute budget and was terminated" }
    if ($null -eq $childCode) { throw 'the child exit code could not be read, so the run is not accepted' }

    # ----- verdict: the child's own identity check, the harness summary and the real exit code -----
    $identityPath = Join-Path $ResultsDir 'child-identity.json'
    $summaryPath = Join-Path $ResultsDir 'summary.json'
    if (-not (Test-Path $identityPath)) { throw 'the child recorded no identity: it did not run as a standard user' }
    $identity = Get-Content -Raw $identityPath | ConvertFrom-Json
    if ($identity.is_administrator -or $identity.administrators_sid_in_token -or $identity.elevated -or @($identity.enabled_backup_restore_privileges).Count -gt 0) {
        throw 'the child is an administrator or holds backup/restore privileges'
    }
    if (-not $identity.profile_verified) { throw 'the child did not verify its own profile folders' }
    if (-not (Test-Path $summaryPath)) { throw 'the harness wrote no summary' }
    $summary = Get-Content -Raw $summaryPath | ConvertFrom-Json
    $listed = Invoke-Checked 'harness.py --list' $PythonExe @((Join-Path $Harness 'harness.py'), '--list')
    $expectedCases = @($listed.Output -split "`n" | Where-Object { $_.Trim() }).Count
    Write-Host ("summary: passed={0} failed={1} unresolved={2} of {3} cases" -f $summary.passed, $summary.failed, $summary.unresolved, $expectedCases)
    if ($summary.failed -ne 0 -or $summary.unresolved -ne 0 -or $summary.passed -ne $expectedCases) {
        throw 'the qualification did not pass every case (failed or unresolved cases fail the job)'
    }
    if ($childCode -ne 0) { throw "the child exited with $childCode" }
    $exitCode = 0
} catch {
    Write-Host "::error::$($_.Exception.Message)"
    $exitCode = 1
} finally {
    # results first (outside the root), then the clean-up, then the receipt that says how the clean-up went
    try {
        if (Test-Path (Join-Path $Root 'results')) {
            New-Item -ItemType Directory -Force -Path $ResultsOut | Out-Null
            $sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'results') -Recurse -File)
            Copy-Item -Path (Join-Path $Root 'results\*') -Destination $ResultsOut -Recurse -Force
            $copied = @(Get-ChildItem -LiteralPath $ResultsOut -Recurse -File)
            $missing = @($sourceFiles | Where-Object {
                    $relative = $_.FullName.Substring((Join-Path $Root 'results').Length).TrimStart('\')
                    -not (Test-Path -LiteralPath (Join-Path $ResultsOut $relative))
                })
            if ($missing.Count -gt 0) { throw "$($missing.Count) result files did not arrive in $ResultsOut" }
            if ($exitCode -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $ResultsOut 'summary.json'))) { throw 'summary.json is not in the copied results' }
        } elseif ($exitCode -eq 0) {
            throw 'there is no results directory to copy'
        }
    } catch {
        $copyProblem = $_.Exception.Message
        Write-Host "::error::copying the results failed: $copyProblem"
        $exitCode = 1
    }
    try {
        # a failed copy keeps C:\q\results for the workflow's upload; the workflow's last step deletes it
        $teardownOutcome = if ($copyProblem) { Invoke-Teardown -KeepResults } else { Invoke-Teardown }
        if (@($teardownOutcome.failures).Count -gt 0) { $exitCode = 1 }
    } catch {
        Write-Host "::error::teardown threw: $($_.Exception.Message)"
        $teardownOutcome = [pscustomobject]@{ failures = @("teardown threw: $($_.Exception.Message)"); steps = @() }
        $exitCode = 1
    }
    try {
        New-Item -ItemType Directory -Force -Path $ResultsOut | Out-Null
        $receipt = [ordered]@{
            exit_code = $exitCode; child_timed_out = $timedOut; results_copy_problem = $copyProblem
            teardown = $teardownOutcome; recorded = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-Utf8NoBom (Join-Path $ResultsOut 'final-receipt.json') ($receipt | ConvertTo-Json -Depth 6)
    } catch {
        Write-Host "::error::writing the final receipt failed: $($_.Exception.Message)"
        $exitCode = 1
    }
}
exit $exitCode
