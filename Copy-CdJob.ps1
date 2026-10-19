#Requires -Version 5.1
<#
.SYNOPSIS
    Job de copie de CD isole dans son propre processus (appelle par CdRepositoryGui.ps1).
#>
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$DriveLetter,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][string]$ProgressFile
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $here 'CdRepositoryGui.log'

function Write-JobTrace {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [JOB] $Message"
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

try {
    Write-JobTrace "Demarrage du job : lecteur='$DriveLetter' titre='$Title' categorie='$Category'"
    Import-Module $ModulePath -Force
    Write-JobTrace 'Module importe.'

    $cb = {
        param([int]$pct, [string]$detail)
        try { Add-Content -Path $ProgressFile -Value "$pct|$detail" -Encoding UTF8 } catch { }
    }

    $result = Copy-CdToRepository -Title $Title -DriveLetter $DriveLetter -Category $Category -ProgressCallback $cb
    Write-JobTrace "Job termine OK : $result"
    Add-Content -Path $ProgressFile -Value "DONE|$result" -Encoding UTF8
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Write-JobTrace "Job en erreur : $($_.Exception.GetType().FullName): $msg"
    if ($_.InvocationInfo) { Write-JobTrace "    at $($_.InvocationInfo.PositionMessage)" }
    if ($_.Exception.InnerException) { Write-JobTrace "    inner: $($_.Exception.InnerException.Message)" }
    Add-Content -Path $ProgressFile -Value "ERROR|$msg" -Encoding UTF8
    exit 1
}
