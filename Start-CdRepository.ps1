#Requires -Version 5.1
<#
.SYNOPSIS
    Menu interactif du repository de compact disks (NAS Synology via SMB).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Start-CdRepository.ps1
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'CdRepository.psd1') -Force

function Read-Choice {
    param([string]$Prompt, [string[]]$Valid)
    while ($true) {
        $v = Read-Host $Prompt
        if ($Valid -contains $v) { return $v }
        Write-Host "Choix invalide : $($Valid -join ', ')"
    }
}

function Read-Category {
    $cats = Get-CdCategories
    Write-Host ("Categories : " + (($cats | ForEach-Object { $_ }) -join ' | '))
    while ($true) {
        $c = Read-Host 'Categorie'
        $cat = Get-MediaCategory $c
        if ($cats -contains $cat) { return $cat }
        Write-Host "Categorie inconnue."
    }
}

function Read-NonEmpty([string]$Prompt) {
    while ($true) {
        $v = Read-Host $Prompt
        if ($v -and $v.Trim()) { return $v.Trim() }
        Write-Host "Valeur requise."
    }
}

function Pick-Disk {
    param([string]$FilterCategory = '')
    $disks = Show-CdIndex -Raw
    if ($FilterCategory) { $disks = @($disks | Where-Object { (Get-MediaCategory $_.category) -eq (Get-MediaCategory $FilterCategory) }) }
    if (-not $disks -or $disks.Count -eq 0) { Write-Host 'Index vide.'; return $null }
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $d = $disks[$i]
        Write-Host ("[{0}] {1} ({2}, {3} Mo)" -f ($i + 1), $d.title, (Get-MediaCategory $d.category), [math]::Round($d.sizeBytes / 1MB, 0))
    }
    $sel = Read-Host 'Numero (0 pour annuler)'
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $disks.Count) { return $null }
    return $disks[$n - 1]
}

$null = Import-CdConfig

:main while ($true) {
    Write-Host ''
    Write-Host '===== CD Repository (NAS Synology) ====='
    Write-Host '1. Copier un CD vers le repository'
    Write-Host '2. Monter un CD du repository'
    Write-Host '3. Demonter un CD'
    Write-Host '4. Afficher l index'
    Write-Host '5. Rechercher dans l index'
    Write-Host '6. Voir le contenu d un CD'
    Write-Host '7. Deplacer un CD vers une autre categorie'
    Write-Host '8. Supprimer un CD du repository'
    Write-Host '0. Quitter'
    $choice = Read-Choice 'Choix' @('0','1','2','3','4','5','6','7','8')

    try {
        switch ($choice) {
            '1' {
                $letter = Read-NonEmpty 'Lettre du lecteur de CD (ex: D)'
                $title  = Read-NonEmpty 'Titre du CD'
                $cat    = Read-Category
                $desc   = Read-Host 'Description (optionnel)'
                Copy-CdToRepository -Title $title -DriveLetter $letter -Category $cat -Description $desc
            }
            '2' {
                $d = Pick-Disk
                if ($d) {
                    $pref = Read-Host 'Lettre preferee (vide = premiere libre)'
                    if ($pref) { Mount-CdFromRepository -Id $d.id -PreferredLetter $pref }
                    else { Mount-CdFromRepository -Id $d.id }
                }
            }
            '3' {
                $d = Pick-Disk
                if ($d) { Dismount-CdFromRepository -Id $d.id }
            }
            '4' {
                $cat = Read-Host 'Filtrer par categorie (vide = toutes)'
                Show-CdIndex -Category $cat
            }
            '5' {
                $q = Read-NonEmpty 'Recherche'
                $cat = Read-Host 'Filtrer par categorie (vide = toutes)'
                Search-CdIndex -Query $q -Category $cat
            }
            '6' {
                $d = Pick-Disk
                if ($d) {
                    $full = (Read-Host 'Contenu complet ? (o/n)') -eq 'o'
                    Show-CdContent -Id $d.id -Full:$full
                }
            }
            '7' {
                $d = Pick-Disk
                if ($d) {
                    $cat = Read-Category
                    Move-CdEntry -Id $d.id -Category $cat
                }
            }
            '8' {
                $d = Pick-Disk
                if ($d) {
                    $confirm = Read-Host "Supprimer '$($d.title)' ? (o/n)"
                    if ($confirm -eq 'o') { Remove-CdFromRepository -Id $d.id }
                }
            }
            '0' { break main }
        }
    }
    catch {
        Write-Host "ERREUR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host 'Au revoir.'
