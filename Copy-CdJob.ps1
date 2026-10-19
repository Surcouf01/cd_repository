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
    [Parameter(Mandatory)][string]$ProgressFile,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'

if (-not $LogFile) {
    $LogFile = Join-Path $env:TEMP 'CdRepositoryJob.log'
}

function Write-JobTrace {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [JOB] $Message"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

try {
    Write-JobTrace "Demarrage du job (PID $PID) : lecteur='$DriveLetter' titre='$Title' categorie='$Category'"
    Write-JobTrace "Import du module : $ModulePath"
    Import-Module $ModulePath -Force
    Write-JobTrace 'Module importe.'

    Write-JobTrace 'Verification des prerequis (Quiet)...'
    $req = Test-CdRepositoryRequirements -Quiet
    Write-JobTrace "Prerequis : WMP dll=$($req.WmpDll) COM=$($req.WmpCom) IMAPI=$($req.Imapi) config=$($req.Config) NAS=$($req.Nas) admin=$($req.Admin)"
    if (-not $req.Nas) {
        throw "Repository NAS inaccessible : verifiez le partage SMB et config.json."
    }
    $hasFs = [bool](Get-PSDrive $DriveLetter.TrimEnd(':', '\') -ErrorAction SilentlyContinue)
    if (-not $hasFs -and -not $req.WmpCom) {
        $isAudio = $false
        try { $isAudio = Test-CdIsAudio -DriveLetter $DriveLetter } catch { $isAudio = $true }
        if ($isAudio) {
            throw "CD audio detecte mais Windows Media Player est absent ou non pilotable. Installation : Parametres > Applications > Fonctionnalites facultatives > Windows Media Player (ou : Add-WindowsCapability -Online -Name 'Media.WindowsMediaPlayer')."
        }
    }

    $cb = {
        param([int]$pct, [string]$detail)
        try { Add-Content -Path $ProgressFile -Value "$pct|$detail" -Encoding UTF8 } catch { }
    }

    Write-JobTrace 'Appel de Copy-CdToRepository...'
    Write-JobTrace "  - Volume du lecteur ${DriveLetter}: ..."
    $vol = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':', '\') -ErrorAction SilentlyContinue
    Write-JobTrace "  - Get-Volume : $(if ($vol) { 'OK (label=' + $vol.FileSystemLabel + ')' } else { 'aucun volume' })"
    Write-JobTrace "  - Test de presence du systeme de fichiers (Get-PSDrive)..."
    $hasFs = [bool](Get-PSDrive $DriveLetter.TrimEnd(':', '\') -ErrorAction SilentlyContinue)
    Write-JobTrace "  - Systeme de fichiers present : $hasFs"

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
