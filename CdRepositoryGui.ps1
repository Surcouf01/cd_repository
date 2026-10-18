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
$window.FindName('BtnRip')      | Out-Null
foreach ($n in 'BtnRip','BtnMount','BtnDismount','BtnMove','BtnDelete','BtnRefresh',
               'TxtSearch','CmbCategory','BtnSearch','BtnClear',
               'GridDisks','ListContent','TxtStatus') {
    $controls[$n] = $window.FindName($n)
}

function Set-Status {
    param([string]$Text, [switch]$Error)
    $controls['TxtStatus'].Text = $Text
    if ($Error) { $controls['TxtStatus'].Foreground = 'Red' }
    else { $controls['TxtStatus'].Foreground = 'Black' }
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
    $dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copier un CD" Height="230" Width="420" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Lettre du lecteur de CD (ex: D) :"/>
        <TextBox x:Name="DlgLetter" Grid.Row="1" Height="24" Margin="0,4,0,8"/>
        <TextBlock Grid.Row="2" Text="Titre :"/>
        <TextBox x:Name="DlgTitle" Grid.Row="3" Height="24" Margin="0,4,0,8"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgOk" Content="Copier" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="DlgCancel" Content="Annuler" Width="90" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dlgXaml)))
    $dlgLetter = $dialog.FindName('DlgLetter')
    $dlgTitle  = $dialog.FindName('DlgTitle')
    $dlgOk     = $dialog.FindName('DlgOk')
    $result = $false
    $dlgOk.Add_Click({
        if ($dlgLetter.Text.Trim() -and $dlgTitle.Text.Trim()) { $result = $true; $dialog.DialogResult = $true }
        else { [System.Windows.MessageBox]::Show('Lettre et titre requis.', 'Validation', 'OK', 'Warning') | Out-Null }
    })
    $dialog.Owner = $window
    if ($dialog.ShowDialog()) {
        $letter = $dlgLetter.Text.Trim()
        $title  = $dlgTitle.Text.Trim()
        $cat    = $controls['CmbCategory'].SelectedItem
        if (-not $cat -or $cat -eq '(toutes)') { $cat = 'autre' }
        Wait-Cursor {
            try {
                Set-Status "Copie de '$title' depuis $letter`: ... (peut prendre plusieurs minutes)"
                $iso = Copy-CdToRepository -Title $title -DriveLetter $letter -Category $cat
                if ($iso) { Set-Status "Copie terminee : $iso" }
                Update-DiskGrid
            }
            catch { Set-Status "Erreur : $($_.Exception.Message)" -Error }
        }
    }
})

$controls['BtnMount'].Add_Click({
    $sel = Get-SelectedDisk
    if (-not $sel) { return }
    Wait-Cursor {
        try {
            $m = Mount-CdFromRepository -Id $sel.Id
            Set-Status "Monte sur $($m.Letter): . Explorateur..."
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
