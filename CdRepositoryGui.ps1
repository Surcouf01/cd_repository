#Requires -Version 5.1
<#
.SYNOPSIS
    Interface graphique WPF du repository de compact disks (NAS Synology via SMB).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\CdRepositoryGui.ps1
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'CdRepository.psd1') -Force

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
                <Button x:Name="BtnRefresh" Content="Actualiser"     Width="85"  Margin="0,0,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
                <TextBox x:Name="TxtSearch" Width="220" Height="24"
                         VerticalContentAlignment="Center" ToolTip="Recherche titre, description, fichier, contenu"/>
                <ComboBox x:Name="CmbCategory" Width="130" Height="24" Margin="6,0,0,0"/>
                <Button x:Name="BtnSearch" Content="Rechercher" Width="95" Margin="6,0,0,0"/>
                <Button x:Name="BtnClear"   Content="Effacer"   Width="70" Margin="6,0,0,0"/>
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
                <TextBlock x:Name="TxtStatus" Text="Pret."/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
foreach ($n in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh',
               'TxtSearch','CmbCategory','BtnSearch','BtnClear',
               'GridDisks','ListContent','TxtStatus') {
    $controls[$n] = $window.FindName($n)
}

$script:Busy = $false
$script:CopyPs = $null
$script:CopyResult = $null

function Set-Status {
    param([string]$Text, [switch]$Error)
    $controls['TxtStatus'].Text = $Text
    if ($Error) { $controls['TxtStatus'].Foreground = 'Red' }
    else { $controls['TxtStatus'].Foreground = 'Black' }
}

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
    foreach ($b in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh','BtnSearch','BtnClear') {
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
    foreach ($b in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh','BtnSearch','BtnClear') {
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

function Update-DiskGrid {
    $viewModels.Clear()
    $cat = $controls['CmbCategory'].SelectedItem
    $disks = Show-CdIndex -Raw
    if ($cat -and $cat -ne '(toutes)') {
        $disks = @($disks | Where-Object { (Get-MediaCategory $_.category) -eq (Get-MediaCategory $cat) })
    }
    foreach ($d in $disks) {
        $viewModels.Add([pscustomobject]@{
            Id          = $d.id
            Title       = $d.title
            Category    = Get-MediaCategory $d.category
            SizeMB      = [math]::Round($d.sizeBytes / 1MB, 1)
            Added       = ([datetime]$d.addedUtc).ToString('yyyy-MM-dd')
            Description = $d.description
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
$combo.Items.Add('(toutes)') | Out-Null
foreach ($c in (Get-CdCategories)) { $combo.Items.Add($c) | Out-Null }
$combo.SelectedIndex = 0

Update-DiskGrid

# --- Evenements ---

$controls['BtnRefresh'].Add_Click({ Wait-Cursor { Update-DiskGrid } })

$controls['GridDisks'].Add_SelectionChanged({ Update-ContentPane })

$controls['BtnSearch'].Add_Click({
    Wait-Cursor {
        $q = $controls['TxtSearch'].Text.Trim()
        if (-not $q) { Update-DiskGrid; return }
        $cat = $controls['CmbCategory'].SelectedItem
        $index = Get-CdIndex
        $hits = @($index.disks | Where-Object {
            (($_.title, $_.description, $_.fileName, ($_.contents -join ' ')) -join ' ').ToLower() -match [regex]::Escape($q.ToLower())
        })
        if ($cat -and $cat -ne '(toutes)') {
            $hits = @($hits | Where-Object { (Get-MediaCategory $_.category) -eq (Get-MediaCategory $cat) })
        }
        $viewModels.Clear()
        foreach ($d in $hits) {
            $viewModels.Add([pscustomobject]@{
                Id          = $d.id
                Title       = $d.title
                Category    = Get-MediaCategory $d.category
                SizeMB      = [math]::Round($d.sizeBytes / 1MB, 1)
                Added       = ([datetime]$d.addedUtc).ToString('yyyy-MM-dd')
                Description = $d.description
            })
        }
        Set-Status "$($hits.Count) resultat(s) pour '$q'."
    }
})

$controls['BtnClear'].Add_Click({
    $controls['TxtSearch'].Text = ''
    $controls['CmbCategory'].SelectedIndex = 0
    Update-DiskGrid
})

$controls['CmbCategory'].Add_SelectionChanged({
    if ($viewModels) { Update-DiskGrid }
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
        <TextBlock Grid.Row="4" Text="Categorie :"/>
        <ComboBox x:Name="DlgCat" Grid.Row="5" Height="24" Margin="0,4,0,8"/>
        <TextBlock Grid.Row="6" Text=""/>
        <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgOk" Content="Copier" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="DlgCancel" Content="Annuler" Width="90" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)))
    $dlgLetter = $dialog.FindName('DlgLetter')
    $dlgTitle  = $dialog.FindName('DlgTitle')
    $dlgCat    = $dialog.FindName('DlgCat')
    $dlgOk     = $dialog.FindName('DlgOk')
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
    $cat = $dlgCat.SelectedItem
    if (-not $cat) { $cat = 'autre' }

    Show-CopyOverlay -Title $title -SourceLetter $letter

    $modulePath = Join-Path $here 'CdRepository.psd1'
    $ps = [powershell]::Create().AddScript({
        param($mod, $letter, $title, $cat, $uiHash)
        Import-Module $mod -Force
        $cb = {
            param([int]$pct, [string]$detail)
            $uiHash.Queue.Add(@{ Pct = $pct; Detail = $detail })
        }
        Copy-CdToRepository -Title $title -DriveLetter $letter -Category $cat -ProgressCallback $cb
    })
    $null = $ps.AddArgument($modulePath).AddArgument($letter).AddArgument($title).AddArgument($cat)
    $uiQueue = New-Object System.Collections.ArrayList
    $script:CopyQueue = $uiQueue
    $uiHash = @{ Queue = $uiQueue }
    $null = $ps.AddArgument($uiHash)
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = 'MTA'
    $ps.Runspace.Open()

    $script:CopyPs = $ps
    $script:CopyResult = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:CopyTimer = $timer
    $timer.Add_Tick({
        while ($script:CopyQueue.Count -gt 0) {
            $item = $script:CopyQueue[0]
            $script:CopyQueue.RemoveAt(0)
            $fileName = ''
            $detail = [string]$item.Detail
            if ($detail -match '^Copie\s*:\s*(.+?)\s*\((\d+)/(\d+)\)$') {
                $fileName = $Matches[1]
                $detail = "Fichier $($Matches[2]) / $($Matches[3])"
            }
            Update-CopyProgress -Percent $item.Pct -Detail $detail -FileName $fileName
        }
        if ($script:CopyResult.IsCompleted) {
            $script:CopyTimer.Stop()
            try {
                $out = $script:CopyPs.EndInvoke($script:CopyResult)
                $errs = @($script:CopyPs.Streams.Error.ReadAll())
                if ($errs.Count -gt 0) {
                    Set-Status "Erreur : $($errs[0].Exception.Message)" -Error
                } else {
                    $iso = ($out | Select-Object -Last 1)
                    $warns = @($script:CopyPs.Streams.Warning.ReadAll())
                    if ($warns.Count -gt 0) {
                        $warnMsg = ($warns | ForEach-Object { $_.Message }) -join ' | '
                        Set-Status "Copie terminee avec avertissements : $warnMsg"
                        [System.Windows.MessageBox]::Show(
                            "La copie s'est terminee, mais des erreurs de lecture sont survenues :`n`n$warnMsg`n`nLes fichiers concernes ont ete exclus de l'ISO.",
                            'Copie terminee avec avertissements', 'OK', 'Warning') | Out-Null
                    } else {
                        Set-Status "Copie terminee : $iso"
                    }
                }
            }
            catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
            finally {
                $script:CopyQueue.Clear()
                Hide-CopyOverlay
                $script:CopyPs.Runspace.Close()
                $script:CopyPs.Dispose()
                $script:CopyPs = $null
                Update-DiskGrid
            }
        }
    })
    $timer.Start()
})

$controls['BtnMount'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            $m = Mount-CdFromRepository -Id $sel.Id
            Set-Status "Monte sur $($m.Letter): . Ouverture de l'Explorateur..."
            Start-Process "explorer.exe" ("$($m.Letter):\")
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
    }
})

$controls['BtnDismount'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            Dismount-CdFromRepository -Id $sel.Id
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
    $confirm = [System.Windows.MessageBox]::Show(
        "Supprimer '$($sel.Title)' (fichier ISO + entree d'index) ?", 'Confirmation', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    Wait-Cursor {
        try {
            Remove-CdFromRepository -Id $sel.Id
            Update-DiskGrid
        }
        catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
    }
})

Set-Status "Pret. $($viewModels.Count) disque(s) dans l'index."
[void]$window.ShowDialog()
