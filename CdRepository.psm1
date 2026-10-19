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
    $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $disks = @()
    if ($null -ne $json.disks) {
        if ($json.disks -is [array]) { $disks = $json.disks }
        else { $disks = @($json.disks) }
    }
    return [pscustomobject]@{ version = $json.version; disks = $disks }
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

function Test-CdIsAudio {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    $drive = $DriveLetter.TrimEnd('\',':')
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace(3)  # ssfDRIVES
        if (-not $folder) { return $false }
        $item = $null
        foreach ($it in $folder.Items()) {
            if ($it.Name -match "^${drive}:" -or $it.Path -match "^${drive}:\\") { $item = $it; break }
        }
        if (-not $item) { return $false }
        foreach ($ver in $item.Verbs()) {
            if ($ver.Name -match 'Rip|Extraire|Copier') { return $true }
        }
    } catch { return $false }
    return $false
}

function Get-KnownMusicFolder {
    [CmdletBinding()]
    param()
    $folders = New-Object System.Collections.ArrayList
    try {
        $shell = New-Object -ComObject Shell.Application
        $ns = $shell.NameSpace(13)  # ssfMUSIC = dossier Mes musiques connu
        if ($ns) { [void]$folders.Add($ns.Self.Path) }
    } catch { }
    [void]$folders.Add((Join-Path $env:USERPROFILE 'Music'))
    [void]$folders.Add((Join-Path $env:USERPROFILE 'Mes musiques'))
    [void]$folders.Add((Join-Path $env:USERPROFILE 'Ma musique'))
    foreach ($f in $folders) {
        if ($f -and (Test-Path $f)) { return $f }
    }
    throw "Dossier Musique introuvable."
}

function Get-RippedFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Since)
    $musicRoot = Get-KnownMusicFolder
    $exts = @('.wma','.mp3','.wav','.m4a','.flac')
    $files = @(Get-ChildItem -LiteralPath $musicRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() -and $_.LastWriteTime -ge $Since.AddSeconds(-5) })
    if ($files.Count -eq 0) { return @() }
    $newestDir = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).DirectoryName
    return @($files | Where-Object { $_.DirectoryName -eq $newestDir -or $files.Count -le 30 })
}

function Invoke-CdAudioRip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [scriptblock]$ProgressCallback,
        [int]$TimeoutMinutes = 90
    )
    $drive = $DriveLetter.TrimEnd('\',':')
    if (-not ('CdRepo.WmpRip' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CdRepo {
    [StructLayout(LayoutKind.Sequential)]
    public struct WmpRipResult {
        public int Percent;
        public int State;
    }

    [ComImport]
    [Guid("6BF52A4F-394A-11D3-B153-00C04F79FAA6")]
    public class WindowsMediaPlayerClass { }

    [ComImport]
    [Guid("56E2294F-69ED-4629-A869-AEA72C0DCC2C")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IWMPCdromRip {
        void startRip();
        void stopRip();
        void get_ripState(out int pState);
        void get_ripProgress(out int plProgress);
    }

    public static class WmpRip {
        public static void StartRip(object cdrom) {
            IWMPCdromRip rip = (IWMPCdromRip)cdrom;
            rip.startRip();
        }
        public static void StopRip(object cdrom) {
            IWMPCdromRip rip = (IWMPCdromRip)cdrom;
            rip.stopRip();
        }
        public static WmpRipResult GetStatus(object cdrom) {
            IWMPCdromRip rip = (IWMPCdromRip)cdrom;
            WmpRipResult r;
            rip.get_ripState(out r.State);
            rip.get_ripProgress(out r.Percent);
            return r;
        }
    }
}
'@
    }
    if (-not (Test-Path "$env:ProgramFiles\Windows Media Player\wmp.dll") -and
        -not (Test-Path "${env:ProgramFiles(x86)}\Windows Media Player\wmp.dll")) {
        throw "Windows Media Player est requis pour le rip audio (wmp.dll introuvable)."
    }
    $wmp = New-Object -ComObject WMPlayer.OCX.7
    try {
        $cdroms = $wmp.cdromCollection
        if (-not $cdroms) { throw "Collection de lecteurs WMP indisponible." }
        $cdrom = $null
        try { $cdrom = $cdroms.getByDriveSpecifier("${drive}:") } catch { }
        if (-not $cdrom) {
            for ($i = 0; $i -lt $cdroms.count; $i++) {
                $c = $cdroms.Item($i)
                if ($c -and $c.driveSpecifier -match "^${drive}$") { $cdrom = $c; break }
            }
        }
        if (-not $cdrom) { throw "WMP ne trouve pas de CD audio dans le lecteur ${drive}:. Verifiez que le disque est bien insere." }
        $playlist = $cdrom.Playlist
        if (-not $playlist -or $playlist.count -eq 0) {
            throw "Aucune piste audio detectee dans ${drive}: (le disque n'est peut-etre pas un CD audio)."
        }
        if ($ProgressCallback) { & $ProgressCallback 0 "CD audio detecte : $($playlist.count) piste(s). Demarrage du rip..." }

        $ripStart = Get-Date
        [CdRepo.WmpRip]::StartRip($cdrom)
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $state = 1
        while ($state -eq 1) {
            Start-Sleep -Milliseconds 1000
            $st = [CdRepo.WmpRip]::GetStatus($cdrom)
            $state = $st.State
            if ($ProgressCallback) { & $ProgressCallback $st.Percent ("Extraction audio : $($st.Percent) %") }
            if ((Get-Date) -gt $deadline) {
                [CdRepo.WmpRip]::StopRip($cdrom)
                throw "Timeout du rip audio apres $TimeoutMinutes minutes."
            }
        }
        if ($state -ne 2) {
            throw "Le rip audio s est termine de facon inattendue (etat $state)."
        }
        if ($ProgressCallback) { & $ProgressCallback 100 'Extraction audio terminee.' }
        $ripped = Get-RippedFiles -Since $ripStart
        if ($ripped.Count -eq 0) {
            throw "Le rip semble termine mais aucune piste nouvelle n a ete trouvee dans le dossier Musique. Verifiez le dossier d extraction configure dans Windows Media Player (Options > Extraire de la musique)."
        }
        return $ripped
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wmp)
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
    $hasFileSystem = [bool](Get-PSDrive $drive -ErrorAction SilentlyContinue)
    if (-not $hasFileSystem) {
        $isAudio = Test-CdIsAudio -DriveLetter $drive
        if ($isAudio) {
            if ($ProgressCallback) { & $ProgressCallback 0 'CD audio detecte : extraction des pistes...' }
            $rippedFiles = @(Invoke-CdAudioRip -DriveLetter $drive -ProgressCallback $ProgressCallback)
            $catDir = Join-Path $root (Get-MediaCategory $Category)
            if (-not (Test-Path $catDir)) { New-Item -ItemType Directory -Path $catDir -Force | Out-Null }
            $safe = ($Title -replace '[\\/:*?"<>|]','_').Trim()
            $destDir = Join-Path $catDir $safe
            $i = 1
            while (Test-Path $destDir) { $destDir = Join-Path $catDir ("{0}_{1}" -f $safe, $i); $i++ }
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            $copied = 0
            $files = $rippedFiles
            $totalBytes = ($files | Measure-Object Length -Sum).Sum
            if ($totalBytes) { $totalBytes = [long]$totalBytes }
            foreach ($f in $files) {
                Copy-Item -LiteralPath $f.FullName -Destination $destDir -Force
                $copied += $f.Length
                if ($ProgressCallback -and $totalBytes -gt 0) {
                    & $ProgressCallback ([int](90 * $copied / $totalBytes)) ("Transfert vers le NAS : $($f.Name)")
                }
            }
            if ($files.Count -eq 0) { throw "Le rip audio n a produit aucun fichier. Verifiez le format de sortie de Windows Media Player." }
            $totalSize = ($files | Measure-Object Length -Sum).Sum
            New-CdIndex | Out-Null
            $index = Get-CdIndex
            $contents = @($files | Select-Object -First 30 | ForEach-Object { $_.Name })
            $contents += "[$($files.Count) fichiers au total, $([math]::Round($totalSize/1MB,1)) Mo]"
            $entry = [pscustomobject]@{
                id          = [guid]::NewGuid().ToString()
                title       = $Title
                description = $Description
                category    = (Get-MediaCategory $Category)
                fileName    = $safe
                sizeBytes   = $totalSize
                addedUtc    = (Get-Date).ToUniversalTime().ToString('o')
                sourceLabel = "CD Audio"
                contents    = $contents
                readErrors  = @()
            }
            $newDisks = @($index.disks) + @($entry)
            Save-CdIndex -Index ([pscustomobject]@{ version = 1; disks = $newDisks })
            $check = Get-CdIndex
            if (@($check.disks | Where-Object { $_.id -eq $entry.id }).Count -eq 0) {
                throw "Echec de l ecriture de l index : verification post-ecriture negative."
            }
            if ($ProgressCallback) { & $ProgressCallback 100 'Termine.' }
            Write-Host "OK : CD audio archive dans $destDir"
            Write-Output $destDir
            return
        }
        throw "Aucun disque present dans le lecteur $drive."
    }
    if (-not $vol) { throw "Lettre de lecteur invalide ou non presente : $drive" }

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
            $newDisks = @($index.disks) + @($entry)
            Save-CdIndex -Index ([pscustomobject]@{ version = 1; disks = $newDisks })
            $check = Get-CdIndex
            if (@($check.disks | Where-Object { $_.id -eq $entry.id }).Count -eq 0) {
                throw "Echec de l ecriture de l index : verification post-ecriture negative."
            }
            Write-Host "Index mis a jour : $($check.disks.Count) disque(s)."
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
    if (-not (Test-Path $iso)) {
        if ($entry.sourceLabel -eq 'CD Audio' -and (Test-Path $iso -PathType Container)) {
            Write-Host "CD audio : contenu disponible dans $iso (pas de montage necessaire)."
            Start-Process "explorer.exe" $iso
            return [pscustomobject]@{ Letter = ''; Image = $null; Id = $Id }
        }
        throw "Fichier ISO manquant : $iso"
    }

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
    'Test-CdIsAudio','Invoke-CdAudioRip','Get-KnownMusicFolder','Get-RippedFiles',
    'Copy-CdToRepository','Mount-CdFromRepository','Dismount-CdFromRepository',
    'Remove-CdFromRepository','Show-CdIndex','Search-CdIndex','Show-CdContent',
    'Get-CdCategories','Update-CdCategories','Move-CdEntry'
)
