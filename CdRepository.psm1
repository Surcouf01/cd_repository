#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:CfgFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json'
$script:IndexFile = $null
$script:Categories = @('jeux','peripheriques','films','musique','autre')

function Import-CdConfig {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $script:CfgFile)) {
        throw "config.json introuvable : $($script:CfgFile). Copiez config.example.json vers config.json et adaptez-le."
    }
    $cfg = Get-Content $script:CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in 'RepositoryRoot','DriveLetters') {
        if ($null -eq $cfg.$p) { throw "config.json : propriete '$p' manquante." }
    }
    $script:IndexFile = Join-Path $cfg.RepositoryRoot 'index\index.json'
    return $cfg
}

function New-CdIndex {
    [CmdletBinding()]
    param([string]$Path = $script:IndexFile)
    if (-not (Test-Path $Path)) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        @{ version = 1; disks = @() } | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
    }
}

function Get-CdIndex {
    [CmdletBinding()]
    param([string]$Path = $script:IndexFile)
    if (-not $Path) { throw "Configuration non chargee : appelez Import-CdConfig d'abord." }
    New-CdIndex -Path $Path
    return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-CdIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Index, [string]$Path = $script:IndexFile)
    $tmp = "$Path.tmp"
    $Index | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-DriveLettersInUse {
    [CmdletBinding()]
    param([string]$Allowed = 'EFGHIJKLMNOPQRSTUVWXYZ')
    $used = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name.Length -eq 1 }).Name
    $list = @()
    foreach ($c in $Allowed.ToCharArray()) {
        if ($used -notcontains [string]$c) { $list += [string]$c }
    }
    return $list
}

function Get-MediaCategory {
    [CmdletBinding()]
    param([string]$Category)
    if (-not $Category) { return 'autre' }
    $c = ($Category.Trim().ToLower() -replace '[^a-z]','')
    switch -Regex ($c) {
        '^jeu'      { return 'jeux' }
        '^(game|jeuxvideos?)$' { return 'jeux' }
        '^(peripherique|peripheriques|drivers?|pilotes?)$' { return 'peripheriques' }
        '^(film|films|video|videos|movies?)$' { return 'films' }
        '^(musique|music|audio|cdaudio)$' { return 'musique' }
        default     { return 'autre' }
    }
}

function New-IsoImageFromDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationIso,
        [Parameter(Mandatory)][string]$VolumeLabel,
        [scriptblock]$ProgressCallback
    )
    if (-not (Test-Path $SourceDirectory)) { throw "Repertoire source introuvable : $SourceDirectory" }
    if (-not ('CdRepo.IsoStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace CdRepo {
    public static class IsoStream {
        public static void CopyStream(object comStream, string destinationIso) {
            IStream image = (IStream)comStream;
            using (FileStream fs = new FileStream(destinationIso, FileMode.Create, FileAccess.Write)) {
                byte[] buf = new byte[1048576];
                IntPtr pcb = Marshal.AllocHGlobal(8);
                try {
                    while (true) {
                        image.Read(buf, buf.Length, pcb);
                        long read = Marshal.ReadInt64(pcb);
                        if (read <= 0) break;
                        fs.Write(buf, 0, (int)read);
                    }
                }
                finally { Marshal.FreeHGlobal(pcb); }
            }
        }
        public static void CopyStream(object comStream, string destinationIso, Action<long,long> progress) {
            IStream image = (IStream)comStream;
            System.Runtime.InteropServices.ComTypes.STATSTG st;
            image.Stat(out st, 1);
            long total = st.cbSize;
            long done = 0;
            int loops = 0;
            using (FileStream fs = new FileStream(destinationIso, FileMode.Create, FileAccess.Write)) {
                byte[] buf = new byte[1048576];
                IntPtr pcb = Marshal.AllocHGlobal(8);
                try {
                    while (true) {
                        image.Read(buf, buf.Length, pcb);
                        long read = Marshal.ReadInt64(pcb);
                        if (read <= 0) break;
                        fs.Write(buf, 0, (int)read);
                        done += read;
                        if (progress != null && (++loops % 8 == 0)) progress(done, total);
                    }
                }
                finally { Marshal.FreeHGlobal(pcb); }
            }
            if (progress != null) progress(total, total);
        }
    }
}
'@
    }
    $action = $null
    if ($ProgressCallback) {
        $userCb = $ProgressCallback
        $cbBlock = {
            param([long]$pos, [long]$total)
            if ($total -gt 0) {
                $p = 70 + [int](30 * $pos / $total)
                & $userCb $p ("Ecriture de l'ISO : $([math]::Round(100 * $pos / $total)) %")
            }
        }.GetNewClosure()
        $action = [Action[long,long]]$cbBlock
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    try {
        $fsi.VolumeName = $VolumeLabel
        $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
        $fsi.ChooseImageDefaultsForMediaType(12)  # CD ~650-700 Mo
        if ($ProgressCallback) { & $ProgressCallback 72 'Analyse des fichiers pour l image ISO...' }
        $fsi.Root.AddTree((Resolve-Path $SourceDirectory).Path, $false)
        if ($ProgressCallback) { & $ProgressCallback 78 'Generation du flux ISO...' }
        $result = $fsi.CreateResultImage()
        [CdRepo.IsoStream]::CopyStream($result.ImageStream, [System.IO.Path]::GetFullPath($DestinationIso), $action)
    }
    finally {
        if ($null -ne $result) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($result) }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi)
    }
}

function Copy-CdToRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][ValidateSet('jeux','peripheriques','films','musique','autre')][string]$Category,
        [string]$Description = '',
        [scriptblock]$ProgressCallback,
        [switch]$NoIndex
    )
    $cfg = Import-CdConfig
    $root = $cfg.RepositoryRoot
    $drive = $DriveLetter.TrimEnd('\',':')
    $src = "${drive}:"
    $vol = (Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue)
    if (-not $vol) { throw "Lettre de lecteur invalide ou non presente : $drive" }
    if (-not (Get-PSDrive $drive -ErrorAction SilentlyContinue)) { throw "Aucun disque present dans le lecteur $drive" }

    $catDir = Join-Path $root (Get-MediaCategory $Category)
    if (-not (Test-Path $catDir)) { New-Item -ItemType Directory -Path $catDir -Force | Out-Null }

    $safe = ($Title -replace '[\\/:*?"<>|]','_').Trim()
    $isoPath = Join-Path $catDir "$safe.iso"
    $i = 1
    while (Test-Path $isoPath) {
        $isoPath = Join-Path $catDir ("{0}_{1}.iso" -f $safe, $i); $i++
    }

    $srcRoot = (Get-PSDrive $drive).Root
    $tempRoot = Join-Path $env:TEMP ("cdrepo_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        Write-Host "Copie locale du contenu du disque ($src -> $tempRoot)..."
        if ($ProgressCallback) { & $ProgressCallback 0 'Lecture de la structure du disque...' }
        $enumErrs = @()
        $allFiles = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -Force -File -ErrorVariable enumErrs -ErrorAction SilentlyContinue)
        if ($allFiles.Count -eq 0 -and $enumErrs.Count -eq 0) { throw "Le disque dans $src est vide ou illisible." }
        $allDirs = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -Force -Directory -ErrorAction SilentlyContinue)
        foreach ($d in $allDirs) {
            $dest = Join-Path $tempRoot $d.FullName.Substring($srcRoot.Length)
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        }
        $totalBytes = ($allFiles | Measure-Object Length -Sum).Sum
        if (-not $totalBytes) { $totalBytes = 0 }
        if ($ProgressCallback) { & $ProgressCallback 1 "Structure lue : $($allFiles.Count) fichier(s), $([math]::Round($totalBytes/1MB,1)) Mo" }
        $copied = 0; $n = 0
        $readErrors = New-Object System.Collections.ArrayList
        foreach ($f in $allFiles) {
            $destPath = Join-Path $tempRoot $f.FullName.Substring($srcRoot.Length)
            $copiedOk = $false
            for ($try = 1; $try -le 3 -and -not $copiedOk; $try++) {
                try {
                    Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force -ErrorAction Stop
                    $copiedOk = $true
                }
                catch {
                    if (Test-Path $destPath) { Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue }
                    if ($try -lt 3) {
                        if ($ProgressCallback) { & $ProgressCallback ([int](70*$copied/[Math]::Max(1,$totalBytes))) ("Reessai $try/3 : $($f.Name)") }
                        Start-Sleep -Milliseconds 800
                    }
                }
            }
            if (-not $copiedOk) {
                [void]$readErrors.Add([pscustomobject]@{ file = $f.FullName; error = "illisible apres 3 essais" })
                Write-Warning "Erreur de lecture : $($f.FullName) - fichier ignore"
            } else {
                $copied += $f.Length
            }
            $n++
            if ($ProgressCallback -and $totalBytes -gt 0) {
                $pct = [int](70 * $copied / $totalBytes)
                $suffix = if ($readErrors.Count -gt 0) { " [$($readErrors.Count) erreur(s)]" } else { '' }
                & $ProgressCallback $pct ("Copie : $($f.Name) ($n/$($allFiles.Count))$suffix")
            }
        }
        if ($enumErrs.Count -gt 0) {
            foreach ($e in $enumErrs) {
                [void]$readErrors.Add([pscustomobject]@{ file = $e.TargetObject; error = $e.Exception.Message })
            }
        }
        if ($readErrors.Count -gt 0) {
            Write-Warning "$($readErrors.Count) erreur(s) de lecture : $($readErrors.Count) fichier(s) exclus de l'ISO."
            if ($ProgressCallback) { & $ProgressCallback 70 "Copie terminee avec $($readErrors.Count) erreur(s) de lecture" }
        }
        if ($ProgressCallback) { & $ProgressCallback 70 'Preparation de l image ISO...' }

        Write-Host "Creation de l'ISO : $isoPath"
        New-IsoImageFromDirectory -SourceDirectory $tempRoot -DestinationIso $isoPath -VolumeLabel ($safe -replace ' ','_') -ProgressCallback $ProgressCallback
        if (-not (Test-Path $isoPath)) { throw "La creation de l'ISO a echoue." }
        $size = (Get-Item $isoPath).Length
        Write-Host "OK : $isoPath ($([math]::Round($size/1MB,1)) Mo)"
        if ($ProgressCallback) { & $ProgressCallback 96 'Mise a jour de l''index...' }

        if (-not $NoIndex) {
            New-CdIndex | Out-Null
            $index = Get-CdIndex
            $files = Get-ChildItem -LiteralPath $tempRoot -Recurse -Force -File -ErrorAction SilentlyContinue
            $top = Get-ChildItem -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 30
            $contents = @(
                foreach ($f in ($top | ForEach-Object { $_.Name })) { $f }
                if ($files.Count -gt 0) { "[$($files.Count) fichiers au total, $([math]::Round(($files | Measure-Object Length -Sum).Sum/1MB,1)) Mo]" }
            )
            $entry = [pscustomobject]@{
                id          = [guid]::NewGuid().ToString()
                title       = $Title
                description = $Description
                category    = (Get-MediaCategory $Category)
                fileName    = Split-Path -Leaf $isoPath
                sizeBytes   = $size
                addedUtc    = (Get-Date).ToUniversalTime().ToString('o')
                sourceLabel = $vol.FileSystemLabel
                contents    = $contents
                readErrors  = @($readErrors)
            }
            $index.disks += $entry
            Save-CdIndex -Index $index
            Write-Host "Index mis a jour."
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $isoPath) { Write-Output $isoPath }
}

function Mount-CdFromRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$PreferredLetter = ''
    )
    $cfg = Import-CdConfig
    New-CdIndex | Out-Null
    $index = Get-CdIndex
    $entry = $index.disks | Where-Object { $_.id -eq $Id }
    if (-not $entry) { throw "Aucun disque avec l'id '$Id' dans l'index." }
    $cat = Get-MediaCategory $entry.category
    $iso = Join-Path (Join-Path $cfg.RepositoryRoot $cat) $entry.fileName
    if (-not (Test-Path $iso)) { throw "Fichier ISO manquant : $iso" }

    $allowed = $cfg.DriveLetters
    $free = @(Get-DriveLettersInUse -Allowed $allowed)
    if ($PreferredLetter) {
        $p = $PreferredLetter.TrimEnd(':', '\')
        if ($free -notcontains $p) { throw "Lettre '$p' non disponible (libres : $($free -join ', '))." }
        $letter = $p
    } else {
        if ($free.Count -eq 0) { throw "Aucune lettre de lecteur disponible dans : $allowed" }
        $letter = $free[0]
    }

    $img = Mount-DiskImage -ImagePath $iso -NoDriveLetter -PassThru
    $mounted = $false
    try {
        $vol = Get-Volume -DiskImage $img -ErrorAction SilentlyContinue
        $part = $null
        if ($vol) { $part = Get-Partition -Volume $vol -ErrorAction SilentlyContinue }
        if ($part -and $null -ne $part.DiskNumber -and $null -ne $part.PartitionNumber) {
            $null = Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath "$($letter):\" -ErrorAction Stop
            $mounted = $true
        }
        if (-not $mounted) {
            $diskImg = Get-DiskImage -ImagePath $iso
            if ($null -ne $diskImg.Number) {
                $parts = Get-Partition -DiskNumber $diskImg.Number -ErrorAction SilentlyContinue
                if ($parts -and $null -ne $parts[0].PartitionNumber) {
                    $null = Add-PartitionAccessPath -DiskNumber $diskImg.Number -PartitionNumber $parts[0].PartitionNumber -AccessPath "$($letter):\" -ErrorAction Stop
                    $mounted = $true
                }
            }
        }
    } catch { $mounted = $false }
    if (-not $mounted) {
        Dismount-DiskImage -ImagePath $iso | Out-Null
        $img2 = Mount-DiskImage -ImagePath $iso -PassThru
        $vol2 = Get-Volume -DiskImage $img2 -ErrorAction SilentlyContinue
        if ($vol2 -and $vol2.DriveLetter) {
            $letter = [string]$vol2.DriveLetter
        } else {
            throw "Montage impossible : Windows n'a attribue aucune lettre de lecteur."
        }
        $img = $img2
    }
    Write-Host "Monte : $($entry.title) -> ${letter}:"
    return [pscustomobject]@{ Letter = $letter; Image = $img; Id = $Id }
}

function Dismount-CdFromRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $cfg = Import-CdConfig
    $index = Get-CdIndex
    $entry = $index.disks | Where-Object { $_.id -eq $Id }
    if (-not $entry) { throw "Aucun disque avec l'id '$Id'." }
    $cat = Get-MediaCategory $entry.category
    $iso = Join-Path (Join-Path $cfg.RepositoryRoot $cat) $entry.fileName
    Dismount-DiskImage -ImagePath $iso | Out-Null
    Write-Host "Demonte : $($entry.title)"
}

function Remove-CdFromRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [switch]$KeepFile)
    $cfg = Import-CdConfig
    $index = Get-CdIndex
    $entry = $index.disks | Where-Object { $_.id -eq $Id }
    if (-not $entry) { throw "Aucun disque avec l'id '$Id'." }
    $cat = Get-MediaCategory $entry.category
    $iso = Join-Path (Join-Path $cfg.RepositoryRoot $cat) $entry.fileName
    if (-not $KeepFile -and (Test-Path $iso)) {
        Remove-Item -LiteralPath $iso -Force
        Write-Host "Fichier supprime : $iso"
    }
    $index.disks = @($index.disks | Where-Object { $_.id -ne $Id })
    Save-CdIndex -Index $index
    Write-Host "Entree retiree de l'index."
}

function Show-CdIndex {
    [CmdletBinding()]
    param(
        [string]$Category = '',
        [switch]$Raw
    )
    $index = Get-CdIndex
    $disks = $index.disks
    if ($Category) {
        $cat = Get-MediaCategory $Category
        $disks = @($disks | Where-Object { (Get-MediaCategory $_.category) -eq $cat })
    }
    if ($Raw) {
        return $disks
    }
    if (-not $disks -or $disks.Count -eq 0) {
        Write-Host "Index vide."
        return
    }
    $disks | ForEach-Object {
        [pscustomobject]@{
            Id        = $_.id
            Titre     = $_.title
            Categorie = (Get-MediaCategory $_.category)
            TailleMo = [math]::Round($_.sizeBytes / 1MB, 1)
            Ajoute    = ([datetime]$_.addedUtc).ToString('yyyy-MM-dd')
            Fichier   = $_.fileName
        }
    } | Format-Table -AutoSize
}

function Search-CdIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Category = ''
    )
    $index = Get-CdIndex
    $q = $Query.ToLower()
    $hits = @($index.disks | Where-Object {
        (($_.title, $_.description, $_.fileName, ($_.contents -join ' ')) -join ' ').ToLower() -match [regex]::Escape($q)
    })
    if ($Category) {
        $cat = Get-MediaCategory $Category
        $hits = @($hits | Where-Object { (Get-MediaCategory $_.category) -eq $cat })
    }
    if ($hits.Count -eq 0) { Write-Host "Aucun resultat pour '$Query'."; return }
    $hits | ForEach-Object {
        [pscustomobject]@{
            Id        = $_.id
            Titre     = $_.title
            Categorie = (Get-MediaCategory $_.category)
            TailleMo = [math]::Round($_.sizeBytes / 1MB, 1)
            Contenu   = (($_.contents | Select-Object -First 5) -join '; ')
        }
    } | Format-Table -AutoSize
}

function Show-CdContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$Full
    )
    $cfg = Import-CdConfig
    $index = Get-CdIndex
    $entry = $index.disks | Where-Object { $_.id -eq $Id }
    if (-not $entry) { throw "Aucun disque avec l'id '$Id'." }
    $cat = Get-MediaCategory $entry.category
    $iso = Join-Path (Join-Path $cfg.RepositoryRoot $cat) $entry.fileName
    if (-not (Test-Path $iso)) { throw "Fichier ISO manquant : $iso" }

    $mounted = $null
    try {
        $mounted = Mount-CdFromRepository -Id $Id
        $root = "$($mounted.Letter):\"
        if ($Full) {
            Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object {
                $rel = $_.FullName.Substring($root.Length)
                if ($_.PSIsContainer) { "[DIR]  $rel" } else { "$([math]::Round($_.Length/1KB,1)) Ko  $rel" }
            }
        } else {
            Get-ChildItem -LiteralPath $root -Force | ForEach-Object {
                if ($_.PSIsContainer) { "[DIR]  $($_.Name)" } else { "$([math]::Round($_.Length/1KB,1)) Ko  $($_.Name)" }
            }
        }
    }
    finally {
        if ($mounted) { Dismount-CdFromRepository -Id $Id | Out-Null }
    }
}

function Get-CdCategories {
    [CmdletBinding()]
    param()
    return $script:Categories
}

function Update-CdCategories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Names)
    $script:Categories = $Names
}

function Move-CdEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('jeux','peripheriques','films','musique','autre')][string]$Category
    )
    $cfg = Import-CdConfig
    $index = Get-CdIndex
    $entry = $index.disks | Where-Object { $_.id -eq $Id }
    if (-not $entry) { throw "Aucun disque avec l'id '$Id'." }
    $oldCat = Get-MediaCategory $entry.category
    $newCat = Get-MediaCategory $Category
    if ($oldCat -eq $newCat) { Write-Host "Deja dans '$newCat'."; return }
    $oldIso = Join-Path (Join-Path $cfg.RepositoryRoot $oldCat) $entry.fileName
    $newDir = Join-Path $cfg.RepositoryRoot $newCat
    if (-not (Test-Path $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
    if (Test-Path $oldIso) {
        Move-Item -LiteralPath $oldIso -Destination $newDir -Force
        Write-Host "Fichier deplace vers $newDir"
    }
    $entry.category = $newCat
    Save-CdIndex -Index $index
    Write-Host "Index mis a jour : $($entry.title) -> $newCat"
}

Export-ModuleMember -Function @(
    'Import-CdConfig','New-CdIndex','Get-CdIndex','Save-CdIndex',
    'Get-DriveLettersInUse','Get-MediaCategory','New-IsoImageFromDirectory',
    'Copy-CdToRepository','Mount-CdFromRepository','Dismount-CdFromRepository',
    'Remove-CdFromRepository','Show-CdIndex','Search-CdIndex','Show-CdContent',
    'Get-CdCategories','Update-CdCategories','Move-CdEntry'
)
