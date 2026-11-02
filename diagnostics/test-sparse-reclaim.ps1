# Copyright (c) Microsoft. All rights reserved.
# SPDX-License-Identifier: MIT
#
# Disposable WSL sparse-VHD regression probe.
# This script NEVER changes the sparse mode of an existing distribution.
# Requires Windows, WSL 3.x, a compatible rootfs TAR, and enough free host space.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RootfsTar,

    [ValidateRange(128, 8192)]
    [int]$WriteMiB = 512,

    [ValidateRange(1, 20)]
    [int]$Cycles = 3,

    [ValidateRange(5, 180)]
    [int]$WaitSeconds = 45,

    [ValidateRange(0.0, 1.0)]
    [double]$MinimumReclaimFraction = 0.50,

    [string]$WorkRoot = (Join-Path $env:TEMP 'wsl-sparse-reclaim-lab'),

    [switch]$IncludeDynamicControl,

    [switch]$KeepDistros
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe was not found. Run this test on a Windows machine with WSL installed.'
}

if (-not ('WslSparseLab.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace WslSparseLab
{
    public static class NativeMethods
    {
        [DllImport("kernel32.dll", EntryPoint = "GetCompressedFileSizeW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetCompressedFileSize(string path, out uint high);
    }
}
'@
}

function Get-AllocatedBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    [uint32]$high = 0
    [uint32]$low = [WslSparseLab.NativeMethods]::GetCompressedFileSize($Path, [ref]$high)
    if ($low -eq [uint32]::MaxValue) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($errorCode -ne 0) {
            throw "GetCompressedFileSizeW failed for $Path (Win32 $errorCode)."
        }
    }

    return ([uint64]$high * [uint64]4294967296) + [uint64]$low
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    # Windows PowerShell 5.1 can emit NativeCommandError for native stderr.
    # Capture that output without letting a warning bypass LASTEXITCODE checking.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & wsl.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $output = ($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("wsl.exe {0} failed with exit code {1}: {2}" -f ($Arguments -join ' '), $exitCode, $output)
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-Guest {
    param(
        [string]$Distro,
        [string]$Command,
        [switch]$AllowFailure
    )

    return Invoke-Wsl -Arguments @('-d', $Distro, '-u', 'root', '--', 'sh', '-c', $Command) -AllowFailure:$AllowFailure
}

function Read-VhdState {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        LogicalBytes   = [uint64]$item.Length
        AllocatedBytes = [uint64](Get-AllocatedBytes -Path $Path)
        Sparse         = (($item.Attributes -band [System.IO.FileAttributes]::SparseFile) -ne 0)
    }
}

$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$RootfsTar = (Resolve-Path -LiteralPath $RootfsTar).Path
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
$resultDir = Join-Path $WorkRoot "results-$runId"
New-Item -ItemType Directory -Path $resultDir -Force | Out-Null

$driveRoot = [System.IO.Path]::GetPathRoot($resultDir)
if ($driveRoot -match '^[A-Za-z]:\\') {
    $driveName = $driveRoot.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName
    $requiredBytes = [int64](2 * $WriteMiB + 3072) * 1MB
    if ($drive.Free -lt $requiredBytes) {
        throw ("Insufficient host free space. Have {0:N1} GiB; require at least {1:N1} GiB." -f
            ($drive.Free / 1GB), ($requiredBytes / 1GB))
    }
}

$wslVersion = (Invoke-Wsl -Arguments @('--version')).Output
$osVersion = [System.Environment]::OSVersion.VersionString
$rows = @()
$registeredNames = @()
$failure = $null

try {
    $modes = @('Sparse')
    if ($IncludeDynamicControl) { $modes = @('Dynamic', 'Sparse') }

    foreach ($mode in $modes) {
        $name = "wsl-sparse-lab-$runId-$($mode.ToLowerInvariant())"
        $distroDir = Join-Path $WorkRoot $name
        New-Item -ItemType Directory -Path $distroDir -Force | Out-Null

        Write-Host "Importing disposable $mode distro: $name"
        Invoke-Wsl -Arguments @('--import', $name, $distroDir, $RootfsTar, '--version', '2') | Out-Null
        $registeredNames += $name

        if ($mode -eq 'Sparse') {
            Invoke-Wsl -Arguments @('--manage', $name, '--set-sparse', 'true') | Out-Null
        }

        $vhdPath = Join-Path $distroDir 'ext4.vhdx'
        if (-not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) {
            throw "Expected imported VHDX was not found: $vhdPath"
        }

        $initial = Read-VhdState -Path $vhdPath
        if ($initial.Sparse -ne ($mode -eq 'Sparse')) {
            throw "Unexpected sparse attribute on $vhdPath (expected $mode)."
        }

        # A persistent checksum-protected sentinel detects corruption of
        # unrelated live data after the large temporary file is discarded.
        Invoke-Guest -Distro $name -Command (
            'set -eu; mkdir -p /var/tmp/wsl-sparse-lab; ' +
            'dd if=/dev/urandom of=/var/tmp/wsl-sparse-lab/sentinel.bin bs=1048576 count=8 conv=fsync status=none; ' +
            'cd /var/tmp/wsl-sparse-lab; sha256sum sentinel.bin > sentinel.sha256; sync') | Out-Null

        $mountOptions = (Invoke-Guest -Distro $name -Command 'findmnt -no OPTIONS /').Output
        $discardInfo = (Invoke-Guest -Distro $name -Command 'lsblk -D' -AllowFailure).Output

        for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
            Write-Host "[$mode/$cycle] Writing $WriteMiB MiB of incompressible guest data..."
            $before = Read-VhdState -Path $vhdPath

            $createCommand = (
                'set -eu; cd /var/tmp/wsl-sparse-lab; ' +
                "dd if=/dev/urandom of=data.bin bs=1048576 count=$WriteMiB conv=fsync status=none; " +
                'sha256sum data.bin > data.sha256; sync'
            )
            Invoke-Guest -Distro $name -Command $createCommand | Out-Null
            $afterWrite = Read-VhdState -Path $vhdPath

            Invoke-Guest -Distro $name -Command (
                'set -eu; cd /var/tmp/wsl-sparse-lab; sha256sum -c data.sha256; sha256sum -c sentinel.sha256') | Out-Null

            # Restart only the disposable distro, not the whole WSL VM.
            Invoke-Wsl -Arguments @('--terminate', $name) | Out-Null
            Invoke-Guest -Distro $name -Command (
                'set -eu; cd /var/tmp/wsl-sparse-lab; sha256sum -c data.sha256; sha256sum -c sentinel.sha256') | Out-Null

            Invoke-Guest -Distro $name -Command (
                'set -eu; rm -f /var/tmp/wsl-sparse-lab/data.bin /var/tmp/wsl-sparse-lab/data.sha256; sync') | Out-Null

            $trim = Invoke-Guest -Distro $name -Command 'fstrim -v /' -AllowFailure
            $afterTrim = Read-VhdState -Path $vhdPath
            $growth = [double]$afterWrite.AllocatedBytes - [double]$before.AllocatedBytes
            $deadline = (Get-Date).AddSeconds($WaitSeconds)
            $reclaimed = [double]$afterWrite.AllocatedBytes - [double]$afterTrim.AllocatedBytes

            while (($growth -gt 0) -and
                   ($reclaimed -lt $MinimumReclaimFraction * $growth) -and
                   ((Get-Date) -lt $deadline)) {
                Start-Sleep -Seconds 3
                $afterTrim = Read-VhdState -Path $vhdPath
                $reclaimed = [double]$afterWrite.AllocatedBytes - [double]$afterTrim.AllocatedBytes
            }

            # Verify existing live data after the discard, too.
            Invoke-Guest -Distro $name -Command (
                'set -eu; cd /var/tmp/wsl-sparse-lab; sha256sum -c sentinel.sha256') | Out-Null

            $fraction = if ($growth -gt 0) { $reclaimed / $growth } else { $null }
            $status = if ($mode -eq 'Dynamic') {
                'CONTROL'
            }
            elseif ($trim.ExitCode -ne 0) {
                'TRIM_FAILED'
            }
            elseif ($null -eq $fraction) {
                'NO_OBSERVED_GROWTH'
            }
            elseif ($fraction -ge $MinimumReclaimFraction) {
                'PASS'
            }
            else {
                'RECLAIM_BELOW_THRESHOLD'
            }

            $row = [pscustomobject]@{
                RunId                = $runId
                WindowsVersion       = $osVersion
                Distro               = $name
                Mode                 = $mode
                Cycle                = $cycle
                WriteMiB             = $WriteMiB
                LogicalVhdBytes      = $afterTrim.LogicalBytes
                BeforeAllocatedBytes = $before.AllocatedBytes
                PeakAllocatedBytes   = $afterWrite.AllocatedBytes
                AfterAllocatedBytes  = $afterTrim.AllocatedBytes
                ObservedGrowthBytes  = [int64]$growth
                ReclaimedBytes       = [int64]$reclaimed
                ReclaimedFraction    = $fraction
                TrimExitCode         = $trim.ExitCode
                TrimOutput           = $trim.Output
                MountOptions         = $mountOptions
                DiscardCapabilities  = $discardInfo
                Status               = $status
            }
            $rows += $row
            Write-Host ("[$mode/$cycle] Growth {0:N1} MiB; returned {1:N1} MiB; {2}" -f
                ($growth / 1MB), ($reclaimed / 1MB), $status)
        }
    }
}
catch {
    $failure = $_.Exception.Message
    Write-Warning $failure
}
finally {
    $csv = Join-Path $resultDir 'reclaim-cycles.csv'
    $json = Join-Path $resultDir 'summary.json'
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    }

    $report = [ordered]@{
        RunId           = $runId
        WindowsVersion  = $osVersion
        WslVersion      = $wslVersion
        RootfsTar       = $RootfsTar
        WriteMiB        = $WriteMiB
        Cycles          = $Cycles
        ReclaimThreshold = $MinimumReclaimFraction
        FatalError      = $failure
        Results         = $rows
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $json -Encoding UTF8

    if (-not $KeepDistros) {
        foreach ($name in $registeredNames) {
            $unregister = Invoke-Wsl -Arguments @('--unregister', $name) -AllowFailure
            if ($unregister.ExitCode -ne 0) {
                Write-Warning "Could not unregister disposable distro $name. Clean up manually."
            }
        }
    }

    Write-Host "Saved diagnostic results to $resultDir"
}

if ($failure -or ($rows | Where-Object { $_.Mode -eq 'Sparse' -and $_.Status -ne 'PASS' })) {
    Write-Warning 'Sparse-reclaim validation did not pass. Do not enable sparse mode by default based on this run.'
    exit 2
}

Write-Host 'Sparse-reclaim checks passed for this run. Repeat on multiple Windows versions and with fault injection before proposing a new default.'
