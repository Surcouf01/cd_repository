#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
if (-not $script:ModuleRoot) { $script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:CfgFile = Join-Path $script:ModuleRoot 'config.json'
$script:TraceFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'CdRepositoryGui.log'

function Write-ModuleTrace {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [MODULE] $Message"
    if ($env:CdRepoLogFile) {
        try { Add-Content -Path $env:CdRepoLogFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:TraceFile) {
        try { Add-Content -Path $script:TraceFile -Value $line -Encoding UTF8 } catch { }
    }
    try { Write-Host $line -ForegroundColor DarkCyan } catch { }
}
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
        public static long GetImageSize(object comStream) {
            IStream image = (IStream)comStream;
            System.Runtime.InteropServices.ComTypes.STATSTG st;
            image.Stat(out st, 1);
            return st.cbSize;
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
                $ratio = [double]$pos / [double]$total
                if ($ratio -gt 1.0) { $ratio = 1.0 }
                $p = 70 + [int][math]::Floor(30.0 * $ratio)
                if ($p -gt 100) { $p = 100 }
                $pctIso = [int][math]::Floor(100.0 * $ratio)
                & $userCb $p ("Ecriture de l'ISO : $pctIso %")
            }
        }.GetNewClosure()
        $action = [Action[long,long]]$cbBlock
    }
    $srcSizeBytes = 0
    $srcFiles = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -Force -File -ErrorAction SilentlyContinue)
    if ($srcFiles.Count -gt 0) {
        $sum = ($srcFiles | Measure-Object Length -Sum).Sum
        if ($sum) { $srcSizeBytes = [long]$sum }
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    try {
        $fsi.VolumeName = $VolumeLabel
        $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
        if ($srcSizeBytes -gt 700MB) {
            $fsi.ChooseImageDefaultsForMediaType(12)  # base CD
            try { $fsi.FreeMediaBlocks = 2300000 } catch {
                try { $fsi.put_FreeMediaBlocks(2300000) } catch { Write-ModuleTrace 'FreeMediaBlocks non modifiable ; taille CD conservee.' }
            }
            Write-ModuleTrace "Disque de $([math]::Round($srcSizeBytes/1MB,0)) Mo : capacite etendue a ~2,2 To (FreeMediaBlocks=2300000)."
        }
        else {
            $fsi.ChooseImageDefaultsForMediaType(12)  # CD ~650-700 Mo
        }
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

function Test-CdRepositoryRequirements {
    [CmdletBinding()]
    param([switch]$Quiet)

    $results = New-Object System.Collections.ArrayList
    function Add-Result([string]$Name, [bool]$Ok, [string]$Detail) {
        [void]$results.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
        Write-ModuleTrace ("Prerequis '{0}' : {1} - {2}" -f $Name, $(if ($Ok) {'OK'} else {'ECHEC'}), $Detail)
    }

    $wmpPaths = @()
    $wmpFoundVia = ''
    try {
        $clsid = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\WMPlayer.OCX.7\CLSID' -ErrorAction Stop).'(default)'
        if ($clsid) {
            $server = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
            if (-not $server) {
                $server = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\LocalServer32" -ErrorAction SilentlyContinue).'(default)'
            }
            if ($server) {
                $server = [Environment]::ExpandEnvironmentVariables($server.Trim('"'))
                if (Test-Path $server) { $wmpPaths += $server; $wmpFoundVia = 'registre COM' }
            }
        }
    } catch { }
    $system32 = [Environment]::GetFolderPath('System')
    $sysWow64 = Join-Path ([Environment]::GetFolderPath('SystemX86')) ''
    if (-not $sysWow64 -or $sysWow64 -eq '\') { $sysWow64 = Join-Path $env:SystemRoot 'SysWOW64' }
    $wmpPaths += @(
        (Join-Path $system32 'wmp.dll'),
        (Join-Path $env:SystemRoot 'SysWOW64\wmp.dll'),
        (Join-Path $system32 'wmp.dll'),
        (Join-Path $env:ProgramFiles 'Windows Media Player\wmp.dll'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Media Player\wmp.dll'),
        (Join-Path $env:ProgramFiles 'Windows Media Player\wmp.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Media Player\wmp.exe')
    )
    $wmpDll = $null
    foreach ($p in $wmpPaths) {
        if ($p -and (Test-Path $p)) { $wmpDll = $p; break }
    }
    if ($wmpDll -and -not $wmpFoundVia) { $wmpFoundVia = 'chemins systeme' }
    Add-Result 'Windows Media Player' ([bool]$wmpDll) $(if ($wmpDll) { "present ($wmpFoundVia) : $wmpDll" } else { 'introuvable (registre COM, System32, Program Files) - installez : Parametres > Applications > Fonctionnalites facultatives > Windows Media Player' })

    $wmpCom = $false
    $wmpComDetail = ''
    if ($wmpDll) {
        try {
            $test = New-Object -ComObject WMPlayer.OCX.7 -ErrorAction Stop
            $wmpCom = $true
            $wmpComDetail = 'objet COM WMPlayer.OCX.7 cree avec succes'
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($test)
        } catch {
            $wmpComDetail = "creation COM WMPlayer.OCX.7 echouee : $($_.Exception.Message)"
        }
    } else {
        $wmpComDetail = 'wmp.dll absent, test COM ignore'
    }
    Add-Result 'WMP pilotable par COM' $wmpCom $wmpComDetail

    $imapi = $false
    $imapiDetail = ''
    try {
        $t = [type]::GetTypeFromProgID('IMAPI2FS.MsftFileSystemImage')
        if ($t) { $imapi = $true; $imapiDetail = 'IMAPI2FS disponible' }
        else { $imapiDetail = 'IMAPI2FS.MsftFileSystemImage introuvable' }
    } catch { $imapiDetail = "erreur : $($_.Exception.Message)" }
    Add-Result 'IMAPI2 (creation ISO)' $imapi $imapiDetail

    $cfg = $null
    $cfgOk = $false
    $cfgDetail = ''
    try {
        $cfg = Import-CdConfig
        $cfgOk = $true
        $cfgDetail = "racine : $($cfg.RepositoryRoot)"
    } catch { $cfgDetail = $_.Exception.Message }
    Add-Result 'Configuration (config.json)' $cfgOk $cfgDetail

    $nasOk = $false
    $nasDetail = ''
    if ($cfgOk -and $cfg) {
        if (Test-Path $cfg.RepositoryRoot) { $nasOk = $true; $nasDetail = "accesible : $($cfg.RepositoryRoot)" }
        else { $nasDetail = "inaccessible : $($cfg.RepositoryRoot) - verifiez le partage SMB" }
    } else { $nasDetail = 'configuration non chargee' }
    Add-Result 'Repository NAS (SMB)' $nasOk $nasDetail

    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Result 'Droits administrateur' $admin $(if ($admin) { 'requis pour le montage ISO : OK' } else { 'montage ISO indisponible sans elevation' })

    $missing = @($results | Where-Object { -not $_.Ok })
    if (-not $Quiet) {
        foreach ($r in $results) {
            $icon = if ($r.Ok) { '[OK]  ' } else { '[ECHEC]' }
            Write-Host ("{0} {1} : {2}" -f $icon, $r.Check, $r.Detail)
        }
    }
    return [pscustomobject]@{
        AllOk       = ($missing.Count -eq 0)
        WmpDll      = [bool]$wmpDll
        WmpCom      = $wmpCom
        Imapi       = $imapi
        Config      = $cfgOk
        Nas         = $nasOk
        Admin       = $admin
        Results     = $results
    }
}

function Test-CdIsAudio {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    $drive = $DriveLetter.TrimEnd('\',':')
    try {
        Write-ModuleTrace "Test-CdIsAudio : creation Shell.Application..."
        $shell = New-Object -ComObject Shell.Application
        Write-ModuleTrace "Test-CdIsAudio : NameSpace(3) ssfDRIVES..."
        $folder = $shell.NameSpace(3)  # ssfDRIVES
        if (-not $folder) {
            Write-ModuleTrace "Test-CdIsAudio : NameSpace(3) a retourne null."
            return $false
        }
        Write-ModuleTrace "Test-CdIsAudio : enumeration des items du dossier Lecteurs..."
        $item = $null
        foreach ($it in $folder.Items()) {
            $itName = "$($it.Name)"
            $itPath = "$($it.Path)"
            Write-ModuleTrace "Test-CdIsAudio : item '$itName' chemin '$itPath'"
            if ($itName -match "^${drive}:" -or $itPath -match "^${drive}:") { $item = $it; break }
        }
        if (-not $item) {
            Write-ModuleTrace "Test-CdIsAudio : lecteur $drive non trouve dans les items Shell."
            return $false
        }
        Write-ModuleTrace "Test-CdIsAudio : lecteur trouve, enumeration des verbes..."
        foreach ($ver in $item.Verbs()) {
            $vn = "$($ver.Name)"
            Write-ModuleTrace "Test-CdIsAudio : verbe '$vn'"
            if ($vn -match 'Rip|Extraire|Copier') { return $true }
        }
    } catch {
        Write-ModuleTrace "Test-CdIsAudio : exception : $($_.Exception.Message)"
        return $false
    }
    Write-ModuleTrace "Test-CdIsAudio : aucun verbe de rip detecte, disque considere non audio."
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

function Get-WmpRipFolder {
    [CmdletBinding()]
    param()
    try {
        $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\MediaPlayer\Preferences' -ErrorAction Stop
        if ($p.CDRipPath) {
            Write-ModuleTrace "Rip audio : CDRipPath registre = '$($p.CDRipPath)' (existe: $(Test-Path $p.CDRipPath)))."
            if (Test-Path $p.CDRipPath) { return $p.CDRipPath }
        } else {
            Write-ModuleTrace 'Rip audio : CDRipPath absent du registre WMP.'
        }
    } catch { Write-ModuleTrace "Rip audio : lecture des preferences WMP impossible : $($_.Exception.Message)" }
    return $null
}

function Get-RippedFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$Since)
    $roots = New-Object System.Collections.ArrayList
    $wmpRoot = Get-WmpRipFolder
    if ($wmpRoot) { [void]$roots.Add($wmpRoot) }
    try { [void]$roots.Add((Get-KnownMusicFolder)) } catch { }
    $exts = @('.wma','.mp3','.wav','.m4a','.flac')
    if ($roots.Count -eq 0) { [void]$roots.Add($env:USERPROFILE) }
    $files = @()
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        Write-ModuleTrace "Rip audio : scan des fichiers produits sous $root"
        $files += @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLower() -and $_.LastWriteTime -ge $Since.AddSeconds(-5) })
    }
    $files = @($files | Sort-Object -Property FullName -Unique)
    if ($files.Count -eq 0) { return @() }
    $newestDir = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).DirectoryName
    return @($files | Where-Object { $_.DirectoryName -eq $newestDir -or $files.Count -le 30 })
}

function Get-WmpDllPath {
    [CmdletBinding()]
    param()
    $server = $null
    try {
        $clsid = (Get-ItemProperty -Path 'Registry::HKEY_CLASSES_ROOT\WMPlayer.OCX.7\CLSID' -ErrorAction Stop).'(default)'
        if ($clsid) {
            $server = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\InprocServer32" -ErrorAction SilentlyContinue).'(default)'
            if (-not $server) { $server = (Get-ItemProperty -Path "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\LocalServer32" -ErrorAction SilentlyContinue).'(default)' }
            if ($server) { $server = [Environment]::ExpandEnvironmentVariables($server.Trim('"')) }
        }
    } catch { }
    if (-not $server -or -not (Test-Path $server)) { $server = Join-Path $env:SystemRoot 'System32\wmp.dll' }
    if (-not (Test-Path $server)) { throw "wmp.dll introuvable (registre COM et System32)." }
    return $server
}

function New-WmpRipRaw {
    [CmdletBinding()]
    param()
    $binderDir = Join-Path $env:TEMP 'cdrepo_job'
    if (-not (Test-Path $binderDir)) { New-Item -ItemType Directory -Path $binderDir -Force | Out-Null }
    $binderDll = Join-Path $binderDir 'CdRepo.WmpRaw.dll'
    if (Test-Path $binderDll) {
        try {
            $null = [Reflection.Assembly]::LoadFrom($binderDll)
            Write-ModuleTrace 'Rip audio : binder pre-compile charge depuis la DLL.'
            return
        } catch { Write-ModuleTrace "Rip audio : chargement de la DLL binder a echoue, recompilation : $($_.Exception.Message)" }
    }
    if (-not ('CdRepo.WmpRaw' -as [type])) {
        Write-ModuleTrace 'Rip audio : compilation du binder typelib v2 vers DLL persistante...'
        $srcRip = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace CdRepo {
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void FnVoid(IntPtr pThis);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void FnOutInt(IntPtr pThis, out int value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void FnGetByDrive(IntPtr pThis, [MarshalAs(UnmanagedType.BStr)] string drive, out IntPtr ppCdrom);

    public class WmpRipRaw {
        private IntPtr _pRip;
        private FnVoid _fnStart, _fnStop;
        private FnOutInt _fnState, _fnProg;
        internal WmpRipRaw(IntPtr pRip, FnVoid start, FnVoid stop, FnOutInt state, FnOutInt prog) {
            _pRip = pRip; _fnStart = start; _fnStop = stop; _fnState = state; _fnProg = prog;
        }
        public void StartRip() { _fnStart(_pRip); }
        public void StopRip() { _fnStop(_pRip); }
        public int GetState() { int v; _fnState(_pRip, out v); return v; }
        public int GetProgress() { int v; _fnProg(_pRip, out v); return v; }
        public void Release() { if (_pRip != IntPtr.Zero) { Marshal.Release(_pRip); _pRip = IntPtr.Zero; } }
    }

    public static class WmpRaw {
        [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void LoadTypeLibEx(string strTypeLibName, int regKind, out ITypeLib typeLib);

        private static void Log(string logFile, string msg) {
            try { File.AppendAllText(logFile, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "] [WMPRAW] " + msg + Environment.NewLine); } catch { }
        }

        private static ITypeInfo FindTypeInfo(ITypeLib tlb, string name, string logFile) {
            int count = tlb.GetTypeInfoCount();
            for (int i = 0; i < count; i++) {
                string n, doc, help; int ctx;
                tlb.GetDocumentation(i, out n, out doc, out ctx, out help);
                if (n == name) {
                    ITypeInfo ti;
                    tlb.GetTypeInfo(i, out ti);
                    Log(logFile, name + " trouve (index " + i + ").");
                    return ti;
                }
            }
            return null;
        }

        private static int FindSlot(ITypeInfo ti, System.Runtime.InteropServices.ComTypes.TYPEATTR attr, string methodName, string logFile) {
            for (int f = 0; f < attr.cFuncs; f++) {
                IntPtr pFd;
                ti.GetFuncDesc(f, out pFd);
                System.Runtime.InteropServices.ComTypes.FUNCDESC fd = (System.Runtime.InteropServices.ComTypes.FUNCDESC)Marshal.PtrToStructure(pFd, typeof(System.Runtime.InteropServices.ComTypes.FUNCDESC));
                string[] names = new string[8];
                int pcNames;
                ti.GetNames(fd.memid, names, names.Length, out pcNames);
                string fname = (pcNames > 0 && names[0] != null) ? names[0] : "";
                int slot = fd.oVft / IntPtr.Size;
                Log(logFile, "  " + fname + " slot=" + slot + " invkind=" + fd.invkind);
                ti.ReleaseFuncDesc(pFd);
                string baseName = fname;
                if (baseName.StartsWith("get_")) { baseName = baseName.Substring(4); }
                if (baseName == methodName || fname == methodName) { return slot; }
            }
            return -1;
        }

        public static WmpRipRaw BindByDrive(object cdromCollection, string driveSpecifier, string wmpPath, string logFile) {
            ITypeLib tlb;
            LoadTypeLibEx(wmpPath, 2, out tlb);
            Log(logFile, "Typelib chargee : " + tlb.GetTypeInfoCount() + " types. Architecture : " + (IntPtr.Size == 8 ? "64 bits" : "32 bits") + ".");

            ITypeInfo collInfo = FindTypeInfo(tlb, "IWMPCdromCollection", logFile);
            if (collInfo == null) { throw new Exception("IWMPCdromCollection absent de la typelib."); }
            IntPtr pCollAttr;
            collInfo.GetTypeAttr(out pCollAttr);
            System.Runtime.InteropServices.ComTypes.TYPEATTR collAttr = (System.Runtime.InteropServices.ComTypes.TYPEATTR)Marshal.PtrToStructure(pCollAttr, typeof(System.Runtime.InteropServices.ComTypes.TYPEATTR));
            Guid iidColl = collAttr.guid;
            int slotGetBy = FindSlot(collInfo, collAttr, "getByDriveSpecifier", logFile);
            collInfo.ReleaseTypeAttr(pCollAttr);
            Log(logFile, "iidColl=" + iidColl + " slotGetByDriveSpecifier=" + slotGetBy);
            if (slotGetBy < 0) { throw new Exception("getByDriveSpecifier introuvable dans la typelib."); }

            ITypeInfo ripInfo = FindTypeInfo(tlb, "IWMPCdromRip", logFile);
            if (ripInfo == null) { throw new Exception("IWMPCdromRip absent de la typelib."); }
            IntPtr pRipAttr;
            ripInfo.GetTypeAttr(out pRipAttr);
            System.Runtime.InteropServices.ComTypes.TYPEATTR ripAttr = (System.Runtime.InteropServices.ComTypes.TYPEATTR)Marshal.PtrToStructure(pRipAttr, typeof(System.Runtime.InteropServices.ComTypes.TYPEATTR));
            Guid iidRip = ripAttr.guid;
            int slotStart = FindSlot(ripInfo, ripAttr, "startRip", logFile);
            int slotStop = FindSlot(ripInfo, ripAttr, "stopRip", logFile);
            int slotState = FindSlot(ripInfo, ripAttr, "ripState", logFile);
            int slotProg = FindSlot(ripInfo, ripAttr, "ripProgress", logFile);
            ripInfo.ReleaseTypeAttr(pRipAttr);
            Log(logFile, "iidRip=" + iidRip + " slots: startRip=" + slotStart + " stopRip=" + slotStop + " ripState=" + slotState + " ripProgress=" + slotProg);
            if (slotStart < 0 || slotStop < 0 || slotState < 0 || slotProg < 0) {
                throw new Exception("Methode(s) du rip introuvable(s) dans la typelib.");
            }

            IntPtr pUnkColl = Marshal.GetIUnknownForObject(cdromCollection);
            IntPtr pColl = IntPtr.Zero;
            Guid g1 = iidColl;
            int hr1 = Marshal.QueryInterface(pUnkColl, ref g1, out pColl);
            Marshal.Release(pUnkColl);
            if (hr1 != 0 || pColl == IntPtr.Zero) {
                throw new COMException("QI IWMPCdromCollection hr=0x" + hr1.ToString("X8"), hr1);
            }

            IntPtr vtblColl = Marshal.ReadIntPtr(pColl);
            FnGetByDrive fnGetBy = (FnGetByDrive)Marshal.GetDelegateForFunctionPointer(
                Marshal.ReadIntPtr(vtblColl, slotGetBy * IntPtr.Size), typeof(FnGetByDrive));
            IntPtr pCdrom = IntPtr.Zero;
            fnGetBy(pColl, driveSpecifier, out pCdrom);
            Marshal.Release(pColl);
            if (pCdrom == IntPtr.Zero) {
                throw new Exception("getByDriveSpecifier n a retourne aucun lecteur pour " + driveSpecifier);
            }
            Log(logFile, "Lecteur obtenu via vtable brute (aucun late-binding parametre).");

            IntPtr pRip = IntPtr.Zero;
            Guid g2 = iidRip;
            int hr2 = Marshal.QueryInterface(pCdrom, ref g2, out pRip);
            Marshal.Release(pCdrom);
            if (hr2 != 0 || pRip == IntPtr.Zero) {
                throw new COMException("QI IWMPCdromRip hr=0x" + hr2.ToString("X8"), hr2);
            }

            IntPtr vtbl = Marshal.ReadIntPtr(pRip);
            FnVoid fnStart = (FnVoid)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slotStart * IntPtr.Size), typeof(FnVoid));
            FnVoid fnStop = (FnVoid)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slotStop * IntPtr.Size), typeof(FnVoid));
            FnOutInt fnState = (FnOutInt)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slotState * IntPtr.Size), typeof(FnOutInt));
            FnOutInt fnProg = (FnOutInt)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slotProg * IntPtr.Size), typeof(FnOutInt));
            Log(logFile, "Delegues vtable binds. Rip pret.");
            return new WmpRipRaw(pRip, fnStart, fnStop, fnState, fnProg);
        }
    }
}
'@
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.OutputAssembly = $binderDll
        $cp.CompilerOptions = '/platform:AnyCPU'
        Add-Type -TypeDefinition $srcRip -CompilerParameters $cp
        $null = [Reflection.Assembly]::LoadFrom($binderDll)
        Write-ModuleTrace "Rip audio : binder v2 compile vers $binderDll et charge."
    }
}

function Invoke-CdAudioRipInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [scriptblock]$ProgressCallback,
        [int]$TimeoutMinutes = 90
    )
    Write-ModuleTrace 'Rip interne : entree dans la fonction.'
    $drive = $DriveLetter.TrimEnd('\',':')
    New-WmpRipRaw
    Write-ModuleTrace 'Rip interne : binder compile/verifie.'
    Add-Type -AssemblyName System.Windows.Forms
    Write-ModuleTrace 'Rip interne : WinForms charge.'
    $logFile = $env:CdRepoLogFile
    if (-not $logFile) { $logFile = Join-Path $env:TEMP 'CdRepositoryJob.log' }
    $wmpPath = Get-WmpDllPath
    Write-ModuleTrace "Rip audio : typelib source : $wmpPath"
    Write-ModuleTrace 'Rip audio : creation de l objet COM (propriete seulement, les appels parametres passent par la vtable).'
    $wmp = New-Object -ComObject WMPlayer.OCX.7
    Write-ModuleTrace 'Rip audio : objet WMP cree.'
    $script:RipResult = $null
    $script:RipError = $null
    try {
        $cdroms = $wmp.cdromCollection
        if (-not $cdroms) { throw "Collection de lecteurs WMP indisponible." }
        $driveCount = 0
        try { $driveCount = $cdroms.count } catch { }
        Write-ModuleTrace "Rip audio : $driveCount lecteur(s) dans la collection."
        $cdrom = $cdroms.getByDriveSpecifier("${drive}:")
        if (-not $cdrom) { throw "Lecteur ${drive}: introuvable dans la collection WMP." }
        Write-ModuleTrace 'Rip audio : attente de l indexation du CD par WMP (playlist)...'
        $idxDeadline = (Get-Date).AddSeconds(30)
        $idxCount = -1
        while ((Get-Date) -lt $idxDeadline) {
            $n = -1
            try { $pl = $cdrom.Playlist; if ($pl) { $n = $pl.count } } catch { }
            if ($n -gt 0) {
                if ($n -eq $idxCount) { break }
                $idxCount = $n
            }
            Start-Sleep -Milliseconds 500
        }
        Write-ModuleTrace "Rip audio : playlist du CD peuplee ($idxCount piste(s))."
        if ($ProgressCallback) { & $ProgressCallback 0 "CD audio detecte dans ${drive}:. Extraction..." }

        $ripStart = Get-Date
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $script:RipAttempts = 1
        $script:RipGraceEnd = (Get-Date).AddSeconds(30)
        $script:RipRaw = [CdRepo.WmpRaw]::BindByDrive($cdroms, "${drive}:", $wmpPath, $logFile)
        Write-ModuleTrace 'Rip audio : binder vtable operationnel (details [WMPRAW]).'

        $form = New-Object System.Windows.Forms.Form
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $form.Opacity = 0

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $poll = 0
        $timer.Add_Tick({
            try {
                $poll++
                $state = $script:RipRaw.GetState()
                $pct = $script:RipRaw.GetProgress()
                if ($poll % 5 -eq 1) { Write-ModuleTrace "Rip audio : poll #$poll etat=$state progression=$pct %." }
                if ($ProgressCallback) { & $ProgressCallback $pct "Extraction audio : $pct %" }
                if ($state -ne 1 -and $script:RipAttempts -lt 3 -and (Get-Date) -lt $script:RipGraceEnd) {
                    Write-ModuleTrace "Rip audio : rip arrete immediatement (etat=$state, tentative $($script:RipAttempts)/3). Nouvelle tentative..."
                    $script:RipAttempts++
                    Start-Sleep -Seconds 5
                    $script:RipRaw.StartRip()
                    Write-ModuleTrace "Rip audio : startRip relance (tentative $($script:RipAttempts))."
                }
                elseif ($state -ne 1) {
                    Write-ModuleTrace "Rip audio : etat passe a $state (progression $pct %)."
                    $script:RipResult = 'done'
                    $timer.Stop()
                    $form.Close()
                }
                elseif ((Get-Date) -gt $deadline) {
                    try { $script:RipRaw.StopRip() } catch { }
                    $script:RipError = "Timeout du rip audio apres $TimeoutMinutes minutes."
                    $timer.Stop()
                    $form.Close()
                }
            }
            catch {
                $script:RipError = "Surveillance du rip : $($_.Exception.Message)"
                $timer.Stop()
                $form.Close()
            }
        })

        $form.Add_Shown({
            try {
                Write-ModuleTrace 'Rip audio : pompe active, appel de startRip (vtable)...'
                $script:RipRaw.StartRip()
                Write-ModuleTrace 'Rip audio : startRip retourne sans erreur.'
                $timer.Start()
            }
            catch {
                $script:RipError = "startRip : $($_.Exception.Message)"
                Write-ModuleTrace "Rip audio : erreur startRip : $($_.Exception.Message)"
                $timer.Stop()
                $form.Close()
            }
        })

        [void][System.Windows.Forms.Application]::Run($form)

        if ($script:RipError) { throw $script:RipError }
        if (-not $script:RipResult) { throw "La boucle de rip s'est terminee sans resultat." }

        if ($ProgressCallback) { & $ProgressCallback 100 'Extraction audio terminee.' }
        Write-ModuleTrace 'Rip audio termine. Recherche des fichiers produits...'
        $ripped = @(Get-RippedFiles -Since $ripStart)
        Write-ModuleTrace "Rip audio : $($ripped.Count) fichier(s) trouve(s) dans le dossier Musique."
        if ($ripped.Count -eq 0) {
            Write-ModuleTrace 'Rip audio : aucune piste nouvelle ; interrogation de la bibliotheque WMP (album deja extrait ?)...'
            $libFiles = @()
            $plCount = 0
            try {
                $pl = $cdrom.Playlist
                if ($pl) { $plCount = $pl.count }
                $albumTitle = $null
                if ($plCount -gt 0) {
                    try { $albumTitle = $pl.item(0).getItemInfo('WM/AlbumTitle') } catch { }
                }
                Write-ModuleTrace "Rip audio : playlist CD = $plCount piste(s), album = '$albumTitle'."
                if ($albumTitle) {
                    $lib = $wmp.mediaCollection.getByAlbum($albumTitle)
                    $libCount = 0
                    if ($lib) { $libCount = $lib.count }
                    Write-ModuleTrace "Rip audio : $libCount piste(s) dans la bibliotheque WMP pour cet album."
                    $exts = @('.wma','.mp3','.wav','.m4a','.flac')
                    for ($i = 0; $i -lt $libCount; $i++) {
                        $u = $lib.item($i).sourceURL
                        if ($u -and (Test-Path -LiteralPath $u)) {
                            $f = Get-Item -LiteralPath $u
                            if ($exts -contains $f.Extension.ToLower()) { $libFiles += $f }
                        } else {
                            Write-ModuleTrace "Rip audio : piste bibliotheque $i introuvable sur le disque ($u)."
                        }
                    }
                }
            } catch { Write-ModuleTrace "Rip audio : interrogation de la bibliotheque WMP echouee : $($_.Exception.Message)" }
            $libFiles = @($libFiles | Sort-Object -Property FullName -Unique)
            if ($libFiles.Count -gt 0 -and ($plCount -eq 0 -or $libFiles.Count -ge $plCount)) {
                Write-ModuleTrace "Rip audio : album deja extrait par WMP - reutilisation de $($libFiles.Count) fichier(s) existant(s)."
                if ($ProgressCallback) { & $ProgressCallback 100 'Album deja extrait : fichiers WMP reutilises.' }
                return $libFiles
            }
            if ($libFiles.Count -gt 0) {
                throw "Le rip n a pas produit de fichier et la bibliotheque WMP ne contient que $($libFiles.Count) piste(s) sur $plCount (extraction partielle d un run precedent). Supprimez l album de la bibliotheque WMP (de mon ordinateur inclus) puis relancez."
            }
            throw ("Le rip s arrete immediatement sans produire de fichier. Causes connues : (1) les pistes de ce CD ont deja ete extraites par WMP lors d un run precedent - supprimez l album de la bibliotheque WMP ou utilisez un autre CD ; (2) dossier d extraction invalide dans WMP (Options > Extraire de la musique) ; (3) WMP n a jamais ete lance une premiere fois (relancez-le manuellement et verifiez que l extraction manuelle fonctionne).")
        }
        return $ripped
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wmp)
    }
}

function Invoke-CdAudioRip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [scriptblock]$ProgressCallback,
        [int]$TimeoutMinutes = 90
    )
    $drive = $DriveLetter.TrimEnd('\',':')
    Write-ModuleTrace 'Rip audio : delegation a un sous-processus 32 bits dedie (controle ActiveX WMP 32 bits uniquement).'

    $ripJob = Join-Path $script:ModuleRoot 'Rip-CdJob.ps1'
    if (-not (Test-Path $ripJob)) { throw "Rip-CdJob.ps1 introuvable : $ripJob" }

    $dir = Join-Path $env:TEMP 'cdrepo_job'
    $localRip = Join-Path $dir 'Rip-CdJob.ps1'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ripJobFull = [System.IO.Path]::GetFullPath($ripJob)
    $localRipFull = [System.IO.Path]::GetFullPath($localRip)
    if ($ripJobFull -ne $localRipFull) {
        Copy-Item -LiteralPath $ripJob -Destination $localRip -Force
    }

    $ripProgress = Join-Path $dir ("cdrepo_ripprogress_" + [guid]::NewGuid().ToString('N') + '.txt')
    if (Test-Path $ripProgress) { Remove-Item $ripProgress -Force }
    $ripLog = $env:CdRepoLogFile
    if (-not $ripLog) { $ripLog = Join-Path $env:TEMP 'CdRepositoryJob.log' }

    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $ps32)) { throw "PowerShell 32 bits introuvable : $ps32 (le controle WMP est 32 bits uniquement)." }

    function Quote-RipArg([string]$v) { return '"' + $v + '"' }
    $ripArgs = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', (Quote-RipArg $localRip),
                 '-DriveLetter', (Quote-RipArg $drive),
                 '-ProgressFile', (Quote-RipArg $ripProgress),
                 '-LogFile', (Quote-RipArg $ripLog))
    Write-ModuleTrace "Rip audio : lancement du sous-job 32 bits..."
    $ripStdOut = Join-Path $dir 'cdrepo_rip_stdout.txt'
    $ripStdErr = Join-Path $dir 'cdrepo_rip_stderr.txt'
    Remove-Item -LiteralPath $ripStdOut, $ripStdErr -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $ps32 -ArgumentList $ripArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $ripStdOut -RedirectStandardError $ripStdErr
    Write-ModuleTrace "Rip audio : sous-job lance (PID $($proc.Id))."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pos = 0
    $done = $false
    $errMsg = $null
    while (-not $done) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $ripProgress) {
            try { $lines = [System.IO.File]::ReadAllLines($ripProgress) } catch { $lines = @() }
            for (; $pos -lt $lines.Count; $pos++) {
                $line = $lines[$pos]
                $sep = $line.IndexOf('|')
                if ($sep -lt 1) { continue }
                $tag = $line.Substring(0, $sep)
                $rest = $line.Substring($sep + 1)
                if ($tag -eq 'RIPDONE') {
                    $done = $true
                    $fileList = $rest
                }
                elseif ($tag -eq 'RIPERROR') {
                    $done = $true
                    $errMsg = $rest
                }
                else {
                    $pct = 0
                    [int]::TryParse($tag, [ref]$pct) | Out-Null
                    if ($ProgressCallback) { & $ProgressCallback $pct $rest }
                }
            }
        }
        if ($proc.HasExited -and -not $done) {
            Start-Sleep -Milliseconds 800
            if (Test-Path $ripProgress) {
                try { $lines = [System.IO.File]::ReadAllLines($ripProgress) } catch { $lines = @() }
                foreach ($line in $lines) {
                    if ($line -match '^RIPDONE\|') { $done = $true; $fileList = $line.Substring(8) }
                    if ($line -match '^RIPERROR\|') { $done = $true; $errMsg = $line.Substring(9) }
                }
            }
            if (-not $done) {
                $code = -1
                try { $code = $proc.ExitCode } catch { }
                $stderrTail = ''
                try {
                    if (Test-Path $ripStdErr) {
                        $stderrTail = ([System.IO.File]::ReadAllLines($ripStdErr) | Select-Object -Last 15) -join ' | '
                    }
                } catch { }
                throw "Le sous-job de rip s est arrete brutalement (code $code) sans signal. stderr: $stderrTail"
            }
        }
        if ((Get-Date) -gt $deadline) {
            try { $proc.Kill() } catch { }
            throw "Timeout du rip audio apres $TimeoutMinutes minutes."
        }
    }
    try { Remove-Item $ripProgress -Force -ErrorAction SilentlyContinue } catch { }

    if ($errMsg) { throw "Rip audio : $errMsg" }
    if (-not $fileList) { throw "Rip audio : aucune liste de fichiers recue du sous-job." }

    $files = @()
    foreach ($p in $fileList -split '\|') {
        if ($p -and (Test-Path $p)) { $files += Get-Item -LiteralPath $p }
    }
    Write-ModuleTrace "Rip audio : $($files.Count) fichier(s) recus du sous-job 32 bits."
    if ($files.Count -eq 0) {
        throw "Le rip n a produit aucun fichier exploitable. Verifiez le dossier d extraction configure dans Windows Media Player (Options > Extraire de la musique)."
    }
    return $files
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
    Write-ModuleTrace "Copy-CdToRepository : config chargee (racine=$($cfg.RepositoryRoot))."
    $root = $cfg.RepositoryRoot
    $drive = $DriveLetter.TrimEnd('\',':')
    $src = "${drive}:"
    Write-ModuleTrace "Copy-CdToRepository : demarrage (lecteur=$drive titre=$Title categorie=$Category)."
    Write-ModuleTrace "Copy-CdToRepository : interrogation du lecteur (DriveInfo)..."
    $vol = $null
    try {
        $di = New-Object System.IO.DriveInfo("$drive")
        if ($di.IsReady) {
            $vol = [pscustomobject]@{ FileSystemLabel = $di.VolumeLabel }
            Write-ModuleTrace "Copy-CdToRepository : lecteur pret, label='$($di.VolumeLabel)' format='$($di.DriveFormat)'."
        }
        else {
            Write-ModuleTrace "Copy-CdToRepository : lecteur pas pret (pas de medium)."
        }
    }
    catch {
        Write-ModuleTrace "Copy-CdToRepository : DriveInfo a echoue : $($_.Exception.Message)"
    }
    Write-ModuleTrace "Copy-CdToRepository : Get-PSDrive..."
    $hasFileSystem = [bool](Get-PSDrive $drive -ErrorAction SilentlyContinue)
    Write-ModuleTrace "Copy-CdToRepository : systeme de fichiers present = $hasFileSystem."
    $isAudio = $false
    if (-not $hasFileSystem) {
        $isAudio = Test-CdIsAudio -DriveLetter $drive
        Write-ModuleTrace "Copy-CdToRepository : Test-CdIsAudio (sans systeme de fichiers) = $isAudio."
    }
    else {
        $label = ''
        if ($vol -and $vol.FileSystemLabel) { $label = "$($vol.FileSystemLabel)" }
        Write-ModuleTrace "Copy-CdToRepository : label du volume = '$label'."
        if ($label -match 'Audio CD') {
            $isAudio = $true
        }
        else {
            try {
                $rootFiles = @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | Select-Object -First 5)
                $cdaCount = @($rootFiles | Where-Object { $_.Extension -eq '.cda' }).Count
                Write-ModuleTrace "Copy-CdToRepository : $($rootFiles.Count) fichier(s) a la racine dont $cdaCount .cda."
                if ($rootFiles.Count -gt 0 -and $cdaCount -eq $rootFiles.Count) { $isAudio = $true }
            } catch { Write-ModuleTrace "Copy-CdToRepository : enumeration racine impossible : $($_.Exception.Message)" }
        }
        Write-ModuleTrace "Copy-CdToRepository : CD audio (label/.cda) = $isAudio."
    }
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
                $copied += [long]$f.Length
                if ($ProgressCallback -and $totalBytes -gt 0) {
                    & $ProgressCallback ([int][math]::Floor(90.0 * $copied / $totalBytes)) ("Transfert vers le NAS : $($f.Name)")
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
    if (-not $hasFileSystem) { throw "Aucun disque present dans le lecteur $drive." }
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
                        if ($ProgressCallback) { & $ProgressCallback ([int][math]::Floor(70.0 * $copied / [Math]::Max(1,$totalBytes))) ("Reessai $try/3 : $($f.Name)") }
                        Start-Sleep -Milliseconds 800
                    }
                }
            }
            if (-not $copiedOk) {
                [void]$readErrors.Add([pscustomobject]@{ file = $f.FullName; error = "illisible apres 3 essais" })
                Write-Warning "Erreur de lecture : $($f.FullName) - fichier ignore"
            } else {
                $copied += [long]$f.Length
            }
            $n++
            if ($ProgressCallback -and $totalBytes -gt 0) {
                $pct = [int][math]::Floor(70.0 * $copied / $totalBytes)
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
    'Test-CdRepositoryRequirements','Test-CdIsAudio','Invoke-CdAudioRip','Invoke-CdAudioRipInternal','Get-KnownMusicFolder','Get-RippedFiles','Get-WmpRipFolder',
    'Copy-CdToRepository','Mount-CdFromRepository','Dismount-CdFromRepository',
    'Remove-CdFromRepository','Show-CdIndex','Search-CdIndex','Show-CdContent',
    'Get-CdCategories','Update-CdCategories','Move-CdEntry'
)
