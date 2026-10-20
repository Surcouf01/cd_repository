#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$VerboseErrors
)
<#
.SYNOPSIS
    Interface graphique WPF du repository de compact disks (NAS Synology via SMB).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CdRepositoryGui.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CdRepositoryGui.ps1 -VerboseErrors
    Affiche et journalise toutes les erreurs non gerees (fichier CdRepositoryGui.log a cote du script).
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:VerboseErrors = [bool]$VerboseErrors
$script:LogFile = Join-Path $here 'CdRepositoryGui.log'

function Write-ErrorLog {
    param([string]$Context, [object]$Error)
    try {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Context]"
        if ($Error -is [System.Management.Automation.ErrorRecord]) {
            $line += " $($Error.Exception.GetType().FullName): $($Error.Exception.Message)"
            if ($Error.InvocationInfo) {
                $line += "`n    at $($Error.InvocationInfo.PositionMessage)"
            }
            if ($Error.Exception.InnerException) {
                $line += "`n    inner: $($Error.Exception.InnerException.Message)"
            }
        }
        else { $line += " $Error" }
        Write-TraceLog -Message $line -Color 'Yellow'
    } catch { }
}

function Write-TraceLog {
    param([string]$Message, [string]$Color = 'DarkGray')
    try { Add-Content -Path $script:LogFile -Value $Message -Encoding UTF8 } catch { }
    try { Add-Content -Path (Join-Path $env:TEMP 'CdRepositoryGui.log') -Value $Message -Encoding UTF8 } catch { }
    try { Write-Host $Message -ForegroundColor $Color } catch { }
}

try {
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        try { Write-TraceLog "[APPDOMAIN] Exception non geree : $($e.ExceptionObject)" -Color 'Red' } catch { }
    })
} catch { }

Write-TraceLog "=== Demarrage du GUI -VerboseErrors=$script:VerboseErrors ===" -Color 'Cyan'

Import-Module (Join-Path $here 'CdRepository.psd1') -Force
Write-TraceLog "Module importe."

Write-TraceLog '--- Verification des prerequis ---' -Color 'Cyan'
try {
    Write-TraceLog '--- Resynchronisation de l index depuis le NAS ---' -Color 'Cyan'
    $sync = Sync-CdIndexFromDisk
    Write-TraceLog ("Index resynchronise : +{0} ajoute(s), {1} manquant(s), {2} ISO invalide(s), {3} categorie inconnue(s)." -f $sync.Added, $sync.Missing, $sync.Invalid, $sync.CategoryUnknown) -Color 'DarkCyan'
} catch {
    Write-TraceLog "Resynchronisation de l index impossible : $($_.Exception.Message)" -Color 'Red'
}
$script:Requirements = $null
try {
    $req = Test-CdRepositoryRequirements
    $script:Requirements = $req
    foreach ($r in $req.Results) {
        Write-TraceLog ("{0} {1} : {2}" -f $(if ($r.Ok) {'[OK]  '} else {'[ECHEC]'}), $r.Check, $r.Detail) -Color $(if ($r.Ok) {'Green'} else {'Red'})
    }
    if (-not $req.WmpCom) {
        Write-TraceLog 'ATTENTION : Windows Media Player est absent ou non pilotable - le rip des CD audio echouera. Les CD de données continueront de fonctionner.' -Color 'Red'
    }
} catch {
    Write-TraceLog "Verification des prerequis en erreur : $($_.Exception.Message)" -Color 'Red'
}

if ($script:VerboseErrors) { $ErrorActionPreference = 'Continue'; $Error.Clear() }

trap {
    Write-ErrorLog -Context 'UNHANDLED' -Error $_
    if ($script:VerboseErrors) {
        [System.Windows.MessageBox]::Show(
            "Erreur non geree :`n$($_.Exception.Message)`n`nVoir CdRepositoryGui.log pour les details.",
            'Erreur', 'OK', 'Error') | Out-Null
    }
    continue
}


Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CD Repository - NAS Synology" Height="640" Width="980"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Barre d'outils -->
        <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                <Button x:Name="BtnRip"   Content="Copier un CD..."  Width="120" Margin="0,0,8,0" ToolTip="Copie le CD insere vers le repository (ISO + index)"/>
                <Button x:Name="BtnMount" Content="Monter"           Width="80"  Margin="0,0,8,0" ToolTip="Monter l'ISO selectionne sur la premiere lettre libre"/>
                <Button x:Name="BtnDismount" Content="Demonter"      Width="80"  Margin="0,0,8,0" ToolTip="Demonter l'ISO selectionne"/>
                <Button x:Name="BtnMove"  Content="Deplacer..."      Width="90"  Margin="0,0,8,0" ToolTip="Changer la categorie du CD selectionne"/>
                <Button x:Name="BtnDelete" Content="Supprimer"       Width="80"  Margin="0,0,8,0" ToolTip="Supprimer le CD selectionne (fichier + index)"/>
            </StackPanel>
            <Button x:Name="BtnRefresh" Content="Actualiser" Width="85" DockPanel.Dock="Right" Margin="0,0,8,0" ToolTip="Recharger l index depuis le NAS"/>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
                <Grid Width="220">
                    <TextBox x:Name="TxtSearch" Height="24" VerticalContentAlignment="Center" Background="White"
                             ToolTip="Recherche dynamique : titre, description, fichier, contenu"/>
                    <TextBlock x:Name="TxtSearchHint" Text="Recherche" Height="24"
                               Foreground="Gray" FontStyle="Italic" VerticalAlignment="Center" HorizontalAlignment="Left"
                               IsHitTestVisible="False" Margin="6,0,0,0">
                        <TextBlock.Style>
                            <Style TargetType="TextBlock">
                                <Setter Property="Visibility" Value="Collapsed"/>
                                <Style.Triggers>
                                    <MultiDataTrigger>
                                        <MultiDataTrigger.Conditions>
                                            <Condition Binding="{Binding Text, ElementName=TxtSearch}" Value=""/>
                                            <Condition Binding="{Binding IsKeyboardFocusWithin, ElementName=TxtSearch}" Value="False"/>
                                        </MultiDataTrigger.Conditions>
                                        <Setter Property="Visibility" Value="Visible"/>
                                    </MultiDataTrigger>
                                </Style.Triggers>
                            </Style>
                        </TextBlock.Style>
                    </TextBlock>
                </Grid>
                <ComboBox x:Name="CmbCategory" Width="130" Height="24" Margin="6,0,0,0"/>
                <Button x:Name="BtnClear"   Content="Effacer"   Width="70" Margin="6,0,0,0"/>
                <Button x:Name="BtnPrint"    Content="Imprimer..." Width="90" Margin="6,0,0,0" ToolTip="Imprimer la liste des disques (vue courante)"/>
            </StackPanel>
        </DockPanel>

        <!-- Liste des disques -->
        <DataGrid x:Name="GridDisks" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True"
                  SelectionMode="Single" HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                  EnableRowVirtualization="True">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Titre" Binding="{Binding Title}" Width="260"/>
                <DataGridTextColumn Header="Categorie" Binding="{Binding Category}" Width="100"/>
                <DataGridTextColumn Header="Taille (Mo)" Binding="{Binding SizeMB}" Width="90"/>
                <DataGridTextColumn Header="Ajoute" Binding="{Binding Added}" Width="100"/>
                <DataGridTextColumn Header="Description" Binding="{Binding Description}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>

        <GridSplitter Grid.Row="2" Height="6" HorizontalAlignment="Stretch" ResizeBehavior="PreviousAndNext" Background="Transparent"/>

        <!-- Contenu du CD selectionne -->
        <GroupBox Grid.Row="3" Header="Contenu du disque selectionne">
            <ListView x:Name="ListContent" FontFamily="Consolas">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="Type" Width="60" DisplayMemberBinding="{Binding Type}"/>
                        <GridViewColumn Header="Taille" Width="100" DisplayMemberBinding="{Binding Size}"/>
                        <GridViewColumn Header="Nom / Chemin" Width="700" DisplayMemberBinding="{Binding Name}"/>
                    </GridView>
                </ListView.View>
            </ListView>
        </GroupBox>

        <!-- Barre d'etat -->
        <StatusBar Grid.Row="4" Margin="0,8,0,0">
            <StatusBarItem>
                <TextBox x:Name="TxtStatus" Text="Pret." IsReadOnly="True"
                         BorderThickness="0" Background="Transparent" VerticalContentAlignment="Center"
                         Padding="0" Margin="0"
                         Focusable="True" Cursor="IBeam"
                         ToolTip="Message d'etat - selectionnable/copiable"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
foreach ($n in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh',
               'TxtSearch','CmbCategory','BtnClear','BtnPrint',
               'GridDisks','ListContent','TxtStatus') {
    $controls[$n] = $window.FindName($n)
}

$script:Busy = $false
$script:CopyProgressFile = $null
$script:CopyProgressPos = 0
$script:CopyProc = $null
$script:CopyDone = $true

function Set-Status {
    param([string]$Text, [switch]$Error)
    $controls['TxtStatus'].Text = $Text
    if ($Error) { $controls['TxtStatus'].Foreground = 'Red' }
    else { $controls['TxtStatus'].Foreground = 'Black' }
}
$controls['TxtStatus'].Add_GotKeyboardFocus({
    if ($controls['TxtStatus'].SelectionLength -eq 0) { $controls['TxtStatus'].SelectAll() }
})
$controls['TxtStatus'].Add_PreviewMouseLeftButtonDown({
    if (-not $controls['TxtStatus'].IsKeyboardFocusWithin) {
        $controls['TxtStatus'].Focus()
        $controls['TxtStatus'].SelectAll()
        $_.Handled = $true
    }
})

function Show-CopyOverlay {
    param([string]$Title, [string]$SourceLetter)
    $ovXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copie en cours" Width="520" Height="240" WindowStyle="None" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="WhiteSmoke" ShowInTaskbar="False"
        AllowsTransparency="False" Topmost="True">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" HorizontalAlignment="Center" FontSize="15" FontWeight="Bold"
                   x:Name="LblTitle" Text="Copie du CD en cours..."/>
        <Canvas Grid.Row="1" x:Name="Cvs" Height="90">
            <Grid x:Name="FolderLeft" Canvas.Left="10" Canvas.Top="15" Width="80">
                <Path Data="M 0,8 L 8,0 L 60,0 L 60,10 L 76,10 L 76,42 L 0,42 Z"
                      Fill="#F5C77E" Stroke="#8A6D3B" StrokeThickness="1.5"/>
                <TextBlock Text="CD" HorizontalAlignment="Center" Margin="0,18,0,0" Foreground="#7B5B2A" FontWeight="Bold"/>
                <TextBlock x:Name="LblSource" HorizontalAlignment="Center" Margin="0,48,0,0" Foreground="#555"/>
            </Grid>
            <Grid x:Name="FolderRight" Canvas.Left="380" Canvas.Top="15" Width="80">
                <Path Data="M 0,8 L 8,0 L 60,0 L 60,10 L 76,10 L 76,42 L 0,42 Z"
                      Fill="#9FC5E8" Stroke="#2A5885" StrokeThickness="1.5"/>
                <TextBlock Text="NAS" HorizontalAlignment="Center" Margin="0,18,0,0" Foreground="#1F4E79" FontWeight="Bold"/>
                <TextBlock x:Name="LblDest" HorizontalAlignment="Center" Margin="0,48,0,0" Foreground="#555"/>
            </Grid>
            <Grid x:Name="Leaf" Canvas.Left="30" Canvas.Top="35" Width="28" Height="28">
                <Ellipse Width="26" Height="26" Fill="#FFD966" Stroke="#BF9000" StrokeThickness="1.5"/>
                <Ellipse Width="8" Height="8" Fill="White" Stroke="#BF9000" StrokeThickness="1" Margin="-2,-2,0,0"/>
                <Ellipse Width="26" Height="26" Fill="Transparent" Stroke="#7F6000" StrokeThickness="2" StrokeDashArray="2 2" Margin="0"/>
            </Grid>
        </Canvas>
        <ProgressBar Grid.Row="2" x:Name="PbPercent" Height="20" Margin="20,0" Maximum="100" Minimum="0"/>
        <StackPanel Grid.Row="3" Margin="0,8,0,0">
            <TextBlock x:Name="LblDetail" HorizontalAlignment="Center" Foreground="#555" FontWeight="Bold" Text="Demarrage..."/>
            <TextBlock x:Name="LblFile" HorizontalAlignment="Center" Foreground="#777" FontSize="11" Margin="0,2,0,0" TextTrimming="CharacterEllipsis" MaxWidth="460" Text=""/>
        </StackPanel>
    </Grid>
</Window>
'@
    $script:OverlayWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$ovXaml)))
    $script:OverlayCvs    = $script:OverlayWindow.FindName('Cvs')
    $script:OverlayPb     = $script:OverlayWindow.FindName('PbPercent')
    $script:OverlayLbl    = $script:OverlayWindow.FindName('LblDetail')
    $script:OverlayFile   = $script:OverlayWindow.FindName('LblFile')
    $script:OverlayTitle  = $script:OverlayWindow.FindName('LblTitle')
    $script:OverlayLeaf   = $script:OverlayWindow.FindName('Leaf')
    $script:CopyStart     = [datetime]::Now
    $null = $script:OverlayWindow.FindName('LblSource').Text = "${SourceLetter}"
    $null = $script:OverlayWindow.FindName('LblDest').Text = 'NAS'

    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 30
    $anim.To = 385
    $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(1400))
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $anim.AutoReverse = $false
    [void]$script:OverlayLeaf.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $anim)

    $rise = New-Object System.Windows.Media.Animation.DoubleAnimation
    $rise.From = 20
    $rise.To = 60
    $rise.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
    $rise.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $rise.AutoReverse = $true
    [void]$script:OverlayLeaf.BeginAnimation([System.Windows.Controls.Canvas]::TopProperty, $rise)

    $script:OverlayWindow.Owner = $window
    $script:Busy = $true
    foreach ($b in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh','BtnClear','BtnPrint') {
        $controls[$b].IsEnabled = $false
    }
    [void]$script:OverlayWindow.Show()
}

function Update-CopyProgress {
    param([int]$Percent, [string]$Detail, [string]$FileName = '')
    if ($script:OverlayWindow) {
        $script:OverlayPb.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
        $script:OverlayLbl.Text = "$Percent % - $Detail"
        if ($Detail -match 'erreur\(s\)') {
            $script:OverlayLbl.Foreground = '#D97706'
            $script:OverlayFile.Foreground = '#D97706'
        } else {
            $script:OverlayLbl.Foreground = '#555'
            $script:OverlayFile.Foreground = '#777'
        }
        if ($FileName) { $script:OverlayFile.Text = $FileName }
        elseif ($script:OverlayPb.Value -lt 70) { $script:OverlayFile.Text = '' }
        $elapsed = ([datetime]::Now - $script:CopyStart)
        $script:OverlayTitle.Text = ('Copie en cours... {0:mm\:ss}' -f $elapsed)
    }
}

function Hide-CopyOverlay {
    if ($script:OverlayWindow) {
        $script:OverlayWindow.Close()
        $script:OverlayWindow = $null
    }
    $script:Busy = $false
    foreach ($b in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh','BtnClear','BtnPrint') {
        $controls[$b].IsEnabled = $true
    }
}

function Wait-Cursor([scriptblock]$Body) {
    $window.Cursor = 'Wait'
    try { & $Body }
    finally { $window.Cursor = 'Arrow' }
}

function Get-SelectedDisk {
    $sel = $controls['GridDisks'].SelectedItem
    if (-not $sel) {
        Set-Status "Selectionnez d'abord un disque dans la liste." -Error
        return $null
    }
    return $sel
}

$viewModels = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$controls['GridDisks'].ItemsSource = $viewModels

$controls['GridDisks'].Add_LoadingRow({
    param($sender, $e)
    $vm = $e.Row.Item
    if ($vm -and $vm.PSObject.Properties['RowColor'] -and $vm.RowColor) {
        $e.Row.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($vm.RowColor)
    } else {
        $e.Row.Background = [System.Windows.Media.Brushes]::White
    }
})

function Update-DiskGrid {
    $viewModels.Clear()
    $cat = $controls['CmbCategory'].SelectedItem
    $index = Get-CdIndex
    $disks = @($index.disks)
    if ($cat -and $cat -ne '(toutes)') {
        $want = Get-MediaCategory $cat
        $disks = @($disks | Where-Object {
            $c = $null
            if ($_.PSObject.Properties['category']) { $c = $_.category }
            (Get-MediaCategory $c) -eq $want
        })
    }
    foreach ($d in $disks) {
        $dc = $null
        if ($d.PSObject.Properties['category']) { $dc = $d.category }
        $sz = 0
        if ($d.PSObject.Properties['sizeBytes'] -and $d.sizeBytes) { $sz = $d.sizeBytes }
        $added = ''
        if ($d.PSObject.Properties['addedUtc'] -and $d.addedUtc) {
            try { $added = ([datetime]$d.addedUtc).ToString('yyyy-MM-dd') } catch { $added = [string]$d.addedUtc }
        }
        $desc = ''
        if ($d.PSObject.Properties['description']) { $desc = $d.description }
        $flags = @()
        if ($d.PSObject.Properties['syncFlags']) { $flags = @($d.syncFlags) }
        $viewModels.Add([pscustomobject]@{
            Id          = $d.id
            Title       = $d.title
            Category    = Get-MediaCategory $dc
            SizeMB      = [math]::Round($sz / 1MB, 1)
            Added       = $added
            Description = $desc
            Flags       = ($flags -join ', ')
            RowColor    = $(if ($flags -contains 'FICHIER_MANQUANT' -or $flags -contains 'ISO_INVALIDE') { '#C0392B' }
                             elseif ($flags -contains 'CATEGORIE_INCONNUE') { '#D97706' }
                             elseif ($flags -contains 'AJOUTE_PAR_SCAN') { '#1F618D' }
                             else { '' })
        })
    }
    Set-Status "$($viewModels.Count) disque(s) affiche(s)."
}

function Update-ContentPane {
    $controls['ListContent'].Items.Clear()
    $sel = $controls['GridDisks'].SelectedItem
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            $index = Get-CdIndex
            $entry = $index.disks | Where-Object { $_.id -eq $sel.Id }
            if (-not $entry) { Set-Status "Entree d'index introuvable." -Error; return }
            if ($entry.contents) {
                foreach ($c in $entry.contents) {
                    $controls['ListContent'].Items.Add([pscustomobject]@{
                        Type = 'Apercu'; Size = ''; Name = [string]$c
                    }) | Out-Null
                }
            }
            Set-Status "Apercu du contenu : $($entry.title) (montez le disque pour l'explorer)."
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
    }
}

function Get-CdVolumeLabel {
    param([string]$Drive)
    try {
        $di = New-Object System.IO.DriveInfo("$($Drive.TrimEnd(':', '\'))")
        if ($di.IsReady) { return "$($di.VolumeLabel)" }
    } catch { }
    return ''
}

function Get-CdDriveLetters {
    $letters = @()
    try {
        $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction Stop
        foreach ($d in $drives) {
            if ($d.DeviceID -match '^([A-Za-z]):$') { $letters += $Matches[1].ToUpper() }
        }
    }
    catch {
        foreach ($d in (Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=5' -ErrorAction SilentlyContinue)) {
            if ($d.DeviceID -match '^([A-Za-z]):$') { $letters += $Matches[1].ToUpper() }
        }
    }
    return $letters
}

# --- Initialisation ---
$null = Import-CdConfig
$combo = $controls['CmbCategory']
if (-not $combo) { throw "Initialisation impossible : controle CmbCategory introuvable (XAML charge partiellement ?)." }
$combo.Items.Add('(toutes)') | Out-Null
foreach ($c in (Get-CdCategories)) { $combo.Items.Add($c) | Out-Null }
$combo.SelectedIndex = 0

Update-DiskGrid

# --- Evenements ---

$controls['BtnRefresh'].Add_Click({ Wait-Cursor { Update-DiskGrid } })

$controls['GridDisks'].Add_SelectionChanged({ Update-ContentPane })

function Invoke-Search {
    $q = ''
    if ($controls['TxtSearch'].Text) { $q = $controls['TxtSearch'].Text.Trim() }
    try {
        if (-not $q) { Update-DiskGrid; return }
        $cat = $controls['CmbCategory'].SelectedItem
        $index = Get-CdIndex
        $all = @($index.disks)
        $hits = @($all | Where-Object {
            $parts = @()
            foreach ($p in 'title','description','fileName','contents') {
                if ($_.PSObject.Properties[$p]) {
                    if ($p -eq 'contents') { $parts += [string]($_.contents -join ' ') }
                    else { $parts += [string]$_.$p }
                }
            }
            ($parts -join ' ').ToLower() -match [regex]::Escape($q.ToLower())
        })
        if ($cat -and $cat -ne '(toutes)') {
            $want = Get-MediaCategory $cat
            $hits = @($hits | Where-Object {
                $c = $null
                if ($_.PSObject.Properties['category']) { $c = $_.category }
                (Get-MediaCategory $c) -eq $want
            })
        }
        $viewModels.Clear()
        foreach ($d in $hits) {
            $dc = $null
            if ($d.PSObject.Properties['category']) { $dc = $d.category }
            $sz = 0
            if ($d.PSObject.Properties['sizeBytes'] -and $d.sizeBytes) { $sz = $d.sizeBytes }
            $added = ''
            if ($d.PSObject.Properties['addedUtc'] -and $d.addedUtc) {
                try { $added = ([datetime]$d.addedUtc).ToString('yyyy-MM-dd') } catch { $added = [string]$d.addedUtc }
            }
            $desc = ''
            if ($d.PSObject.Properties['description']) { $desc = $d.description }
            $viewModels.Add([pscustomobject]@{
                Id          = $d.id
                Title       = $d.title
                Category    = Get-MediaCategory $dc
                SizeMB      = [math]::Round($sz / 1MB, 1)
                Added       = $added
                Description = $desc
            })
        }
        Set-Status "$($hits.Count) resultat(s) pour '$q'."
    }
    catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
}

$script:SearchTimer = $null

$controls['TxtSearch'].Add_GotMouseCapture({
    [System.Windows.Input.Keyboard]::Focus($controls['TxtSearch']) | Out-Null
})

$controls['TxtSearch'].Add_TextChanged({
    if ($script:SearchTimer) { $script:SearchTimer.Stop() }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(300)
    $t.Add_Tick({
        $script:SearchTimer.Stop()
        Invoke-Search
    })
    $script:SearchTimer = $t
    $t.Start()
})

$controls['TxtSearch'].Add_KeyDown({
    if ($_.Key -eq 'Enter') {
        if ($script:SearchTimer) { $script:SearchTimer.Stop() }
        Invoke-Search
        $_.Handled = $true
    }
})

$controls['BtnPrint'].Add_Click({
    try {
        $rows = @($viewModels)
        if ($rows.Count -eq 0) { Set-Status 'Rien a imprimer : la liste est vide.' -Error; return }
        $dlg = New-Object System.Windows.Controls.PrintDialog
        if (-not $dlg.ShowDialog()) { return }
        $doc = New-Object System.Windows.Documents.FlowDocument
        $doc.PagePadding = New-Object System.Windows.Thickness(40)
        $doc.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
        $doc.FontSize = 12
        $title = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run("Index CD - $($rows.Count) disque(s)"))
        $title.FontSize = 18
        $title.FontWeight = 'Bold'
        $doc.Blocks.Add($title)
        $datePara = New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run("Imprime le $(Get-Date -Format 'yyyy-MM-dd HH:mm')"))
        $datePara.FontSize = 10
        $datePara.Foreground = [System.Windows.Media.Brushes]::Gray
        $doc.Blocks.Add($datePara)
        $table = New-Object System.Windows.Documents.Table
        $table.CellSpacing = 0
        $border = New-Object System.Windows.Thickness(0,0,0,1)
        foreach ($col in @('Titre','Categorie','Taille (Mo)','Ajoute','Description')) {
            $c = New-Object System.Windows.Documents.TableColumn
            $c.Width = [System.Windows.GridLength]::new(@(240,90,80,90,300)[$table.Columns.Count])
            $table.Columns.Add($c)
        }
        $rg = New-Object System.Windows.Documents.TableRowGroup
        $hr = New-Object System.Windows.Documents.TableRow
        foreach ($h in @('Titre','Categorie','Taille (Mo)','Ajoute','Description')) {
            $cell = New-Object System.Windows.Documents.TableCell(New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run($h)))
            $cell.FontWeight = 'Bold'
            $cell.BorderBrush = [System.Windows.Media.Brushes]::Gray
            $cell.BorderThickness = $border
            $cell.Padding = New-Object System.Windows.Thickness(4)
            [void]$hr.Cells.Add($cell)
        }
        [void]$rg.Rows.Add($hr)
        foreach ($r in $rows) {
            $tr = New-Object System.Windows.Documents.TableRow
            foreach ($v in @($r.Title, $r.Category, $r.SizeMB, $r.Added, $r.Description)) {
                $vv = if ($null -ne $v) { [string]$v } else { '' }
                $cell = New-Object System.Windows.Documents.TableCell(New-Object System.Windows.Documents.Paragraph(New-Object System.Windows.Documents.Run($vv)))
                $cell.BorderBrush = [System.Windows.Media.Brushes]::LightGray
                $cell.BorderThickness = $border
                $cell.Padding = New-Object System.Windows.Thickness(4)
                [void]$tr.Cells.Add($cell)
            }
            [void]$rg.Rows.Add($tr)
        }
        [void]$table.RowGroups.Add($rg)
        $doc.Blocks.Add($table)
        $dlg.PrintDocument($doc, "Index CD Repository")
        Set-Status "Impression envoyee : $($rows.Count) disque(s)."
    }
    catch { Set-Status "Impression impossible : $($_.Exception.Message)" -Error }
})

$controls['BtnClear'].Add_Click({
    $controls['TxtSearch'].Text = ''
    $controls['CmbCategory'].SelectedIndex = 0
    Update-DiskGrid
})

$controls['CmbCategory'].Add_SelectionChanged({
    if ($script:SearchTimer) { $script:SearchTimer.Stop() }
    Invoke-Search
})

$controls['BtnRip'].Add_Click({
    if ($script:Busy) { Set-Status 'Une operation est deja en cours.' -Error; return }

    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copier un CD" Height="290" Width="440" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Lecteur de CD :"/>
        <ComboBox x:Name="DlgLetter" Grid.Row="1" Height="24" Margin="0,4,0,8" IsEditable="True"
                  ToolTip="Lettres detectees automatiquement ; modifiable si besoin"/>
        <TextBlock Grid.Row="2" Text="Titre :"/>
        <TextBox x:Name="DlgTitle" Grid.Row="3" Height="24" Margin="0,4,0,8"/>
        <TextBlock x:Name="DlgLabel" Grid.Row="4" Foreground="Gray" FontStyle="Italic" FontSize="11" Margin="0,0,0,8"
                   Text="Titre du disque : (aucun disque detecte)" TextTrimming="CharacterEllipsis"/>
        <TextBlock Grid.Row="5" Text="Categorie :"/>
        <ComboBox x:Name="DlgCat" Grid.Row="6" Height="24" Margin="0,4,0,8"/>
        <TextBlock Grid.Row="7" Text=""/>
        <StackPanel Grid.Row="8" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgOk" Content="Copier" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="DlgCancel" Content="Annuler" Width="90" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)))
    $dlgLetter = $dialog.FindName('DlgLetter')
    $dlgTitle  = $dialog.FindName('DlgTitle')
    $dlgLabel  = $dialog.FindName('DlgLabel')
    $dlgCat    = $dialog.FindName('DlgCat')
    $dlgOk     = $dialog.FindName('DlgOk')
    $dlgLetter.Add_SelectionChanged({
        $sel = $dlgLetter.Text.Trim().TrimEnd(':', '\')
        if (-not $sel) { $dlgLabel.Text = ''; return }
        $vol = $null
        $lbl = Get-CdVolumeLabel -Drive $sel
        if ($lbl) { $vol = [pscustomobject]@{ FileSystemLabel = $lbl } }
        if ($vol -and $vol.FileSystemLabel) {
            $dlgLabel.Text = "Titre du disque : $($vol.FileSystemLabel)"
        }
        elseif ($vol) {
            $dlgLabel.Text = "Titre du disque : (CD audio ou disque sans nom)"
        }
        else {
            $dlgLabel.Text = "Titre du disque : (aucun disque dans ${sel}:)"
        }
    })
    $dlgOk.Add_Click({ $dialog.DialogResult = $true })
    foreach ($c in (Get-CdCategories)) { $dlgCat.Items.Add($c) | Out-Null }
    $curCat = $controls['CmbCategory'].SelectedItem
    $ci = 0
    if ($curCat -and $curCat -ne '(toutes)') { $ci = [array]::IndexOf((Get-CdCategories), (Get-MediaCategory $curCat)) }
    $dlgCat.SelectedIndex = [Math]::Max(0, $ci)

    $letters = Get-CdDriveLetters
    foreach ($l in $letters) { $dlgLetter.Items.Add($l) | Out-Null }
    if ($letters.Count -gt 0) {
        $dlgLetter.SelectedIndex = 0
        $dlgTitle.Focus()
        $sel0 = $dlgLetter.Text.Trim().TrimEnd(':', '\')
        if ($sel0) {
            $vol0 = $null
            $lbl0 = Get-CdVolumeLabel -Drive $sel0
            if ($lbl0) { $vol0 = [pscustomobject]@{ FileSystemLabel = $lbl0 } }
            if ($vol0 -and $vol0.FileSystemLabel) {
                $dlgLabel.Text = "Titre du disque : $($vol0.FileSystemLabel)"
            }
            elseif ($vol0) {
                $dlgLabel.Text = "Titre du disque : (CD audio ou disque sans nom)"
            }
            else {
                $dlgLabel.Text = "Titre du disque : (aucun disque dans ${sel0}:)"
            }
        }
    } else {
        $dlgLetter.Text = ''
        $dlgLetter.Focus()
        [System.Windows.MessageBox]::Show(
            "Aucun lecteur de CD detecte.`nSaisissez une lettre manuellement si necessaire.",
            'Lecteurs', 'OK', 'Information') | Out-Null
    }

    $dialog.Owner = $window
    if (-not $dialog.ShowDialog()) { return }
    $letter = $dlgLetter.Text.Trim().TrimEnd(':', '\')
    $title  = $dlgTitle.Text.Trim()
    if (-not $letter -or -not $title) {
        Set-Status 'Lettre du lecteur et titre requis.' -Error
        return
    }

    $hasFs = [bool](Get-PSDrive $letter.TrimEnd(':', '\') -ErrorAction SilentlyContinue)
    $isAudio = $false
    if (-not $hasFs) {
        try { $isAudio = Test-CdIsAudio -DriveLetter $letter } catch { $isAudio = $false }
    }
    else {
        try {
            $rootFiles = @(Get-ChildItem -LiteralPath "$($letter.TrimEnd(':', '\')):" -File -ErrorAction SilentlyContinue | Select-Object -First 5)
            $cdaCount = @($rootFiles | Where-Object { $_.Extension -eq '.cda' }).Count
            if ($rootFiles.Count -gt 0 -and $cdaCount -eq $rootFiles.Count) { $isAudio = $true }
            $volTmp = $null
            $lblT = Get-CdVolumeLabel -Drive $letter
            if ($lblT) { $volTmp = [pscustomobject]@{ FileSystemLabel = $lblT } }
            if ($volTmp -and "$($volTmp.FileSystemLabel)" -match 'Audio CD') { $isAudio = $true }
        } catch { }
    }
    if ($isAudio -and -not $script:Requirements.WmpCom) {
        Set-Status 'Copie impossible : CD audio et Windows Media Player absent.' -Error
        [System.Windows.MessageBox]::Show(
            "Ce CD audio ne peut pas etre copie : Windows Media Player est absent ou non pilotable.`n`nInstallation : Parametres > Applications > Fonctionnalites facultatives > Windows Media Player`nou (admin) : Add-WindowsCapability -Online -Name 'Media.WindowsMediaPlayer'`n`nLes CD de donnees ne sont pas concernes par cette limitation.",
            'Windows Media Player requis', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $hasFs -and -not $isAudio) {
        Set-Status "Aucun disque lisible dans ${letter}:." -Error
        [System.Windows.MessageBox]::Show(
            "Aucun disque avec systeme de fichiers detecte dans ${letter}:, et il ne s'agit pas d'un CD audio reconnu.",
            'Disque illisible', 'OK', 'Warning') | Out-Null
        return
    }
    $cat = $dlgCat.SelectedItem
    if (-not $cat) { $cat = 'autre' }

    Show-CopyOverlay -Title $title -SourceLetter $letter

    Write-TraceLog "[GUI] Copie demandee : lecteur='$letter' titre='$title' categorie='$cat'" -Color 'Cyan'

    $jobScript = Join-Path $here 'Copy-CdJob.ps1'
    $modulePath = Join-Path $here 'CdRepository.psd1'

    # Copie locale des scripts (un chemin UNC peut empecher le lancement du job)
    # Inconditionnelle : ecrase toute version stale laissee par une session precedente
    $localDir = Join-Path $env:TEMP 'cdrepo_job'
    if (-not (Test-Path $localDir)) { New-Item -ItemType Directory -Path $localDir -Force | Out-Null }
    Get-ChildItem -LiteralPath $localDir -Filter 'cdrepo_progress_*.txt' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $localDir -Filter 'cdrepo_ripprogress_*.txt' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $localJob = Join-Path $localDir 'Copy-CdJob.ps1'
    $localMod = Join-Path $localDir 'CdRepository.psd1'
    $localPsm = Join-Path $localDir 'CdRepository.psm1'
    $localCfg = Join-Path $localDir 'config.json'
    Copy-Item -LiteralPath $jobScript -Destination $localJob -Force
    Copy-Item -LiteralPath $modulePath -Destination $localMod -Force
    Copy-Item -LiteralPath (Join-Path $here 'CdRepository.psm1') -Destination $localPsm -Force
    if (Test-Path (Join-Path $here 'Rip-CdJob.ps1')) {
        Copy-Item -LiteralPath (Join-Path $here 'Rip-CdJob.ps1') -Destination (Join-Path $localDir 'Rip-CdJob.ps1') -Force
    }
    Write-TraceLog "[GUI] Scripts locaux rafraichis (ecrasement inconditionnel)." -Color 'Cyan'
    if (Test-Path (Join-Path $here 'config.json')) {
        Copy-Item -LiteralPath (Join-Path $here 'config.json') -Destination $localCfg -Force
    }
    Write-TraceLog "[GUI] Scripts copies en local : $localDir" -Color 'Cyan'
    $jobScript = $localJob
    $modulePath = $localMod

    $progressFile = Join-Path $localDir ("cdrepo_progress_" + [guid]::NewGuid().ToString('N') + '.txt')
    if (Test-Path $progressFile) { Remove-Item $progressFile -Force }
    $jobLog = Join-Path $localDir 'job.log'
    if (Test-Path $jobLog) { Remove-Item $jobLog -Force }
    $script:JobLogPath = $jobLog
    $script:JobLogPos = 0

    $script:CopyProgressFile = $progressFile
    $script:CopyProgressPos = 0
    $script:CopyDone = $false

    function Quote-Arg([string]$v) {
        if ($null -eq $v) { return '""' }
        return '"' + $v + '"'
    }
    $procArgs = @(
        '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', (Quote-Arg $jobScript),
        '-ModulePath', (Quote-Arg $modulePath),
        '-DriveLetter', (Quote-Arg $letter),
        '-Title', (Quote-Arg $title),
        '-Category', (Quote-Arg $cat),
        '-ProgressFile', (Quote-Arg $progressFile),
        '-LogFile', (Quote-Arg $jobLog)
    )
    Write-TraceLog "[GUI] Lancement du processus isole : powershell $($procArgs -join ' ')" -Color 'Cyan'
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -PassThru -WindowStyle Hidden
    $script:CopyProc = $proc
    Write-TraceLog "[GUI] Processus de copie lance (PID $($proc.Id))."

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:CopyTimer = $timer
    $script:CopyHeartbeat = 0
    $timer.Add_Tick({
        if ($script:CopyDone) { $script:CopyTimer.Stop(); return }
        $script:CopyHeartbeat++
        if ($script:CopyHeartbeat % 20 -eq 0) {
            try { Add-Content -Path (Join-Path $env:TEMP 'CdRepositoryGui.log') -Value "[GUI] Heartbeat copie en cours (${script:CopyHeartbeat} ticks) - $(Get-Date -Format 'HH:mm:ss')" -Encoding UTF8 } catch { }
        }
        try {

        if ($env:CdRepoGuiNoLogTail) { }
        if ($script:JobLogPath -and (Test-Path $script:JobLogPath) -and -not $env:CdRepoGuiNoLogTail) {
            try {
                $jobLines = [System.IO.File]::ReadAllLines($script:JobLogPath)
                for ($j = $script:JobLogPos; $j -lt $jobLines.Count; $j++) {
                    Write-Host $jobLines[$j] -ForegroundColor DarkCyan
                    try { Add-Content -Path $script:LogFile -Value $jobLines[$j] -Encoding UTF8 } catch { }
                }
                $script:JobLogPos = $jobLines.Count
            } catch { }
        }

        if (Test-Path $script:CopyProgressFile) {
            try {
                $lines = [System.IO.File]::ReadAllLines($script:CopyProgressFile)
            } catch { $lines = @() }
            for ($i = $script:CopyProgressPos; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                $sep = $line.IndexOf('|')
                if ($sep -lt 1) { continue }
                $tag = $line.Substring(0, $sep)
                $rest = $line.Substring($sep + 1)
                if ($tag -eq 'DONE') {
                    $script:CopyDone = $true
                    $script:CopyTimer.Stop()
                    Hide-CopyOverlay
                    Set-Status "Copie terminee : $rest"
                    Update-DiskGrid
                    try { Remove-Item $script:CopyProgressFile -Force -ErrorAction SilentlyContinue } catch { }
                    return
                }
                elseif ($tag -eq 'ERROR') {
                    $script:CopyDone = $true
                    $script:CopyTimer.Stop()
                    Hide-CopyOverlay
                    Set-Status "Erreur : $rest" -Error
                    [System.Windows.MessageBox]::Show(
                        "La copie a echoue :`n`n$rest`n`nDetails dans CdRepositoryGui.log.",
                        'Erreur de copie', 'OK', 'Error') | Out-Null
                    Update-DiskGrid
                    try { Remove-Item $script:CopyProgressFile -Force -ErrorAction SilentlyContinue } catch { }
                    return
                }
                else {
                    $pct = 0
                    [int]::TryParse($tag, [ref]$pct) | Out-Null
                    $fileName = ''
                    $detail = $rest
                    if ($detail -match '^Copie\s*:\s*(.+?)\s*\((\d+)/(\d+)\)$') {
                        $fileName = $Matches[1]
                        $detail = "Fichier $($Matches[2]) / $($Matches[3])"
                    }
                    Update-CopyProgress -Percent $pct -Detail $detail -FileName $fileName
                }
            }
            $script:CopyProgressPos = $lines.Count
        }

        if ($script:CopyProc.HasExited) {
            if (-not $script:CopyDone) {
                Start-Sleep -Milliseconds 500
                $script:CopyDone = $true
                $script:CopyTimer.Stop()
                $exitCode = 0
                try { $exitCode = $script:CopyProc.ExitCode } catch { $exitCode = -1 }
                Write-TraceLog "[GUI] Le processus de copie s est arrete (code $exitCode) sans signal DONE/ERROR." -Color 'Red'
                Hide-CopyOverlay
                Set-Status "La copie s est arretee brutalement (code $exitCode). Voir CdRepositoryGui.log." -Error
                [System.Windows.MessageBox]::Show(
                    "Le processus de copie s est arrete brutalement (code $exitCode).`n`nL'interface est intacte.`nConsultez CdRepositoryGui.log pour la derniere etape atteinte.",
                    'Copie interrompue', 'OK', 'Warning') | Out-Null
                Update-DiskGrid
            }
        }
        }
        catch {
            Write-ErrorLog -Context 'COPY-TIMER' -Error $_
        }
    })
    $timer.Start()
})

function Test-GuiAdmin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-ElevatedCdOperation {
    param([string]$Operation, [string]$Id)
    # Repertoire partage : le processus eleve peut avoir un %TEMP% different
    # (compte administrateur distinct), le resultat doit etre lisible par le GUI.
    $sharedDir = Join-Path $env:ProgramData 'cdrepo'
    if (-not (Test-Path $sharedDir)) { New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null }
    $resultPath = Join-Path $sharedDir ("elev_result_" + [guid]::NewGuid().ToString('N') + '.json')
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    # Copie du module vers le repertoire partage : le compte eleve peut ne pas
    # avoir acces au repertoire de profil (Documents) du compte courant.
    $sharedDir = Join-Path $env:ProgramData 'cdrepo'
    if (-not (Test-Path $sharedDir)) { New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $here 'CdRepository.psm1') -Destination (Join-Path $sharedDir 'CdRepository.psm1') -Force
    Copy-Item -LiteralPath (Join-Path $here 'CdRepository.psd1') -Destination (Join-Path $sharedDir 'CdRepository.psd1') -Force
    if (Test-Path (Join-Path $here 'config.json')) {
        Copy-Item -LiteralPath (Join-Path $here 'config.json') -Destination (Join-Path $sharedDir 'config.json') -Force
    }
    $modulePath = Join-Path $sharedDir 'CdRepository.psd1'
    # Les valeurs sont interpolees directement dans le script encode :
    # -EncodedCommand ne transmet aucun argument au script.
    $cmdName = $(if ($Operation -eq 'mount') { 'Mount-CdFromRepository' } else { 'Dismount-CdFromRepository' })
    $opScript = "
        `$ErrorActionPreference = 'Stop'
        try {
            Import-Module -Name '$modulePath' -Force -ErrorAction Stop
            if (-not (Get-Command -Name '$cmdName' -ErrorAction SilentlyContinue)) {
                throw ('Import du module reussi mais $cmdName absent. Commandes exportees : ' + ((Get-Command -Module CdRepository -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '))
            }
            `$r = $cmdName -Id '$Id'
            @{ ok = `$true; letter = `$(if (`$r -and `$r.Letter) { [string]`$r.Letter } else { '' }) } | ConvertTo-Json | Set-Content -Path '$resultPath' -Encoding UTF8
        }
        catch {
            @{ ok = `$false; error = (`$_.Exception.Message + ' [type: ' + `$_.Exception.GetType().Name + ']') } | ConvertTo-Json | Set-Content -Path '$resultPath' -Encoding UTF8
        }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($opScript))
    $argLine = "-NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -PassThru -WindowStyle Hidden -Wait
    if (-not (Test-Path $resultPath)) {
        throw "L operation a ete annulee (elevation refusee) ou n a pas produit de resultat (code : $($proc.ExitCode)). Resultat attendu : $resultPath"
    }
    $result = Get-Content -Path $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    return $result
}

$controls['BtnMount'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            $m = $null
            if (Test-GuiAdmin) {
                $m = Mount-CdFromRepository -Id $sel.Id
            } else {
                Set-Status 'Elevation des droits demandee (montage ISO)...'
                $r = Invoke-ElevatedCdOperation -Operation 'mount' -Id $sel.Id
                if (-not $r.ok) { throw $r.error }
                $m = [pscustomobject]@{ Letter = $r.letter }
            }
            Set-Status "Monte sur $($m.Letter): . Ouverture de l'Explorateur..."
            if ($m.Letter) { Start-Process "explorer.exe" ("$($m.Letter):\") }
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
    }
})

$controls['BtnDismount'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            if (Test-GuiAdmin) {
                Dismount-CdFromRepository -Id $sel.Id
            } else {
                Set-Status 'Elevation des droits demandee (demontage ISO)...'
                $r = Invoke-ElevatedCdOperation -Operation 'dismount' -Id $sel.Id
                if (-not $r.ok) { throw $r.error }
            }
            Set-Status "Demonte : $($sel.Title)"
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
    }
})

$controls['BtnMove'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Deplacer le CD" Height="180" Width="380" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Nouvelle categorie :"/>
        <ComboBox x:Name="DlgCat" Grid.Row="1" Height="24" Margin="0,4,0,8"/>
        <TextBlock Grid.Row="2" Text=""/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgOk" Content="Deplacer" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="DlgCancel" Content="Annuler" Width="90" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)))
    $dlgCat = $dialog.FindName('DlgCat')
    $dlgOk  = $dialog.FindName('DlgOk')
    foreach ($c in (Get-CdCategories)) { $dlgCat.Items.Add($c) | Out-Null }
    $i = [array]::IndexOf((Get-CdCategories), $sel.Category)
    $dlgCat.SelectedIndex = if ($i -ge 0) { $i } else { 0 }
    $dialog.Owner = $window
    $dlgOk.Add_Click({ $dialog.DialogResult = $true })
    if ($dialog.ShowDialog()) {
        $newCat = $dlgCat.SelectedItem
        Wait-Cursor {
            try {
                Move-CdEntry -Id $sel.Id -Category $newCat
                Update-DiskGrid
            }
            catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
        }
    }
})

$controls['BtnDelete'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    if ($script:Busy) { Set-Status 'Une operation est deja en cours (copie). Attendez la fin avant de supprimer.' -Error; return }
    $confirm = [System.Windows.MessageBox]::Show(
        "Supprimer '$($sel.Title)' (fichier ISO + entree d'index) ?", 'Confirmation', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    $delId = $sel.Id
    $delTitle = $sel.Title
    $script:Busy = $true
    $window.Cursor = 'Wait'
    $delRunspace = [runspacefactory]::CreateRunspace()
    $delRunspace.Open()
    $delPs = [powershell]::Create()
    $delPs.Runspace = $delRunspace
    $delModule = Join-Path $here 'CdRepository.psd1'
    $delLog = Join-Path $env:TEMP 'CdRepositoryGui.log'
    $null = $delPs.AddScript({
        param($ModulePath, $Id, $LogPath)
        try { Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [DELETE] Debut : import du module..." -Encoding UTF8 } catch { }
        Import-Module $ModulePath -Force
        try { Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [DELETE] Module importe. Suppression en cours (NAS)..." -Encoding UTF8 } catch { }
        Remove-CdFromRepository -Id $Id
        try { Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [DELETE] Suppression terminee." -Encoding UTF8 } catch { }
    }).AddArgument($delModule).AddArgument($delId).AddArgument($delLog)
    $delAsync = $delPs.BeginInvoke()
    $script:DelStart = Get-Date
    $delTimer = New-Object System.Windows.Threading.DispatcherTimer
    $delTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $delTimer.Add_Tick({
        if (-not $delAsync.IsCompleted) {
            if (((Get-Date) - $script:DelStart).TotalSeconds -gt 20) {
                $delTimer.Stop()
                try { $delPs.Stop() } catch { }
                try { $delPs.Dispose() } catch { }
                try { $delRunspace.Dispose() } catch { }
                $window.Cursor = 'Arrow'
                $script:Busy = $false
                Set-Status "Suppression interrompue : le NAS n a pas repondu en 20 s (fichier verrouille ou SMB bloque). Verifiez que le fichier n est pas ouvert sur le NAS." -Error
            }
            return
        }
        $delTimer.Stop()
        try {
            $null = $delPs.EndInvoke($delAsync)
            Set-Status "Disque supprime : $delTitle"
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
        finally {
            $delPs.Dispose()
            $delRunspace.Dispose()
            $window.Cursor = 'Arrow'
            $script:Busy = $false
            Update-DiskGrid
        }
    })
    $delTimer.Start()
})

Set-Status "Pret. $($viewModels.Count) disque(s) dans l'index."

$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-ErrorLog -Context 'DISPATCHER' -Error $e.Exception
    [System.Windows.MessageBox]::Show(
        "Erreur interne de l'interface :`n`n$($e.Exception.Message)`n`nL'application reste ouverte. Details dans CdRepositoryGui.log.",
        'Erreur interne', 'OK', 'Error') | Out-Null
    $e.Handled = $true
})
$window.Add_Loaded({
    [void]$window.Activate()
    [void]$window.Focus()
    [System.Windows.Input.Keyboard]::Focus($window)
})
[void]$window.Activate()
[void]$window.Focus()
[void]$window.ShowDialog()
