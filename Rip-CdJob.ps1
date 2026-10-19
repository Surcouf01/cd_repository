#Requires -Version 5.1
<#
.SYNOPSIS
    Sous-job 32 bits dedie au rip WMP d'un CD audio (appelle par CdRepository.psm1).
    Le controle ActiveX WMP n'existe qu'en 32 bits ; le reste du pipeline tourne en 64 bits.
#>
param(
    [Parameter(Mandatory)][string]$DriveLetter,
    [Parameter(Mandatory)][string]$ProgressFile,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
if (-not $LogFile) { $LogFile = Join-Path $env:TEMP 'CdRepositoryRip.log' }

function Write-RipTrace {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [RIP32] $Message"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Write-RipProgress {
    param([int]$Percent, [string]$Detail)
    try { Add-Content -Path $ProgressFile -Value "$Percent|$Detail" -Encoding UTF8 } catch { }
}

try {
    $bits = '64 bits'
    try { if (-not [Environment]::Is64BitProcess) { $bits = '32 bits' } } catch { }
    Write-RipTrace "Sous-job rip demarre ($bits, PID $PID) : lecteur=$DriveLetter"
    if ([Environment]::Is64BitProcess) {
        throw "Ce sous-job doit tourner en 32 bits (SysWOW64). Lancez-le via le powershell 32 bits."
    }

    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    Import-Module (Join-Path $here 'CdRepository.psd1') -Force
    Write-RipTrace 'Module importe dans le sous-job.'

    $cb = {
        param([int]$pct, [string]$detail)
        Write-RipProgress -Percent $pct -Detail $detail
    }

    $ripped = @(Invoke-CdAudioRip -DriveLetter $DriveLetter -ProgressCallback $cb)
    Write-RipTrace "Sous-job rip termine : $($ripped.Count) fichier(s)."
    $list = ($ripped | ForEach-Object { $_.FullName }) -join '|'
    Add-Content -Path $ProgressFile -Value "RIPDONE|$list" -Encoding UTF8
    exit 0
}
catch {
    Write-RipTrace "Sous-job rip en erreur : $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($_.InvocationInfo) { Write-RipTrace "    at $($_.InvocationInfo.PositionMessage)" }
    Add-Content -Path $ProgressFile -Value "RIPERROR|$($_.Exception.Message)" -Encoding UTF8
    exit 1
}
