# CD Repository Tools

Ensemble d'outils pour archiver des compact disks sur un **NAS Synology** (partage SMB) et les remonter à la demande sur Windows.

## Architecture

- **Composant 1 — Repository NAS** : un dossier partagé SMB sur le Synology (ex. `\\NAS\cd-repository`) contenant :
  - un sous-répertoire par thème : `jeux`, `peripheriques`, `films`, `musique`, `autre`
  - un dossier `index\` avec `index.json` (titre, catégorie, taille, date, aperçu du contenu)
- **Composant 2 — Logiciel Windows** (PowerShell 5.1, natif, aucune dépendance) :
  - `CdRepository.psd1` / `CdRepository.psm1` : module (API + logique)
  - `CdRepositoryGui.ps1` : **interface graphique WPF** (recommandée)
  - `Start-CdRepository.ps1` : menu interactif en console
  - `config.example.json` : configuration à copier en `config.json`

## Configuration Synology (composant 1)

1. DSM : **Centre des paquets** → installer *SAMBA* (activé par défaut).
2. **Panneau de configuration → Dossier partagé** → créer `cd-repository`.
3. **Panneau de configuration → Services de fichiers → SMB** → activer, puis accorder les permissions du dossier à un utilisateur/dépôt (contrôle d'accès : lecture/écriture).
4. Sur Windows : `config.json` → `"RepositoryRoot": "\\\\NAS\\cd-repository"`.
   Optionnel — monter le partage comme lecteur réseau :
   ```powershell
   net use Z: \\NAS\cd-repository /persistent:yes
   ```

Le module écrit directement sur le partage SMB ; l'index est écrit de façon atomique (`.tmp` puis renommage) pour résister aux coupures réseau.

## Configuration Windows (composant 2)

1. Copier le dossier `cd-repository-tools` sur le PC Windows.
2. `Copy-Item config.example.json config.json` puis adapter `RepositoryRoot` (chemin UNC ou lecteur réseau) et `DriveLetters` (lettres autorisées pour le montage, ex. `"EFGHIJK..."`).
3. Le module s'appuie sur des composants natifs :
   - **IMAPI2** (`IMAPI2.MsftFileSystemImage`) pour créer les ISO — inclus dans Windows ;
   - **Mount-DiskImage / Add-PartitionAccessPath** pour le montage — Windows 8+/Server 2012+, doit être exécuté **administrateur** ;
   - le partage SMB est directement utilisé par les chemins de fichiers.

## Utilisation

```powershell
# Interface graphique WPF (en administrateur)
powershell -ExecutionPolicy Bypass -File .\CdRepositoryGui.ps1

# Ou menu interactif console
powershell -ExecutionPolicy Bypass -File .\Start-CdRepository.ps1
```

L'interface WPF offre :
- **DataGrid** de l'index (titre, catégorie, taille, date, description) avec sélection
- **Recherche** plein texte + filtre par catégorie
- Boutons **Copier un CD** (boîte de dialogue lettre/titre), **Monter** (première lettre libre, ouvre l'Explorateur), **Demonter**, **Deplacer** (changement de catégorie avec choix), **Supprimer** (confirmation)
- Panneau **Contenu du disque sélectionné** (aperçu indexé) et barre d'état

Ou en API :

```powershell
Import-Module .\CdRepository.psd1

# 2.2 Copier un CD (crée l'ISO dans la catégorie, met à jour l'index)
Copy-CdToRepository -Title 'Age of Empires' -DriveLetter 'D' -Category 'jeux' -Description 'CD original 1997'

# 2.1 Monter sur la première lettre disponible (ou lettre préférée)
Mount-CdFromRepository -Id '<guid>'
Mount-CdFromRepository -Id '<guid>' -PreferredLetter 'M'
Dismount-CdFromRepository -Id '<guid>'

# 2.3 Organiser par thèmes (sous-répertoires)
Move-CdEntry -Id '<guid>' -Category 'films'
Get-CdCategories   # jeux, peripheriques, films, musique, autre

# 2.4 Visualiser l'index / rechercher
Show-CdIndex
Show-CdIndex -Category 'musique'
Search-CdIndex -Query 'empire' -Category 'jeux'

# 2.5 Afficher le contenu d'un CD (monte, liste, démonte)
Show-CdContent -Id '<guid>'
Show-CdContent -Id '<guid>' -Full

# Supprimer
Remove-CdFromRepository -Id '<guid>'
```

## Remarques

- Le rip des CD de **données** utilise une copie locale temporaire puis produit une ISO ISO9660+Joliet.
- **CD audio (CDDA)** : détectés automatiquement (`Test-CdIsAudio`), la copie bascule sur un rip audio via **Windows Media Player** (`Invoke-CdAudioRip`, interface COM `IWMPCdromRip`) : les pistes sont extraites au format configuré dans WMP (par défaut WMA ; configurez MP3 dans WMP → Options → Extraire de la musique), puis transférées dans un sous-dossier `musique/<titre>` du NAS et indexées (entrées avec `sourceLabel = "CD Audio"`). Le bouton Monter ouvre directement le dossier pour ces entrées.
- Prérequis pour le rip audio : Windows Media Player installé (inclus dans Windows ; fonctionnalité optionnelle sur Windows 11).
- La gravure n'est pas incluse : clic droit sur l'ISO → *Graver l'image du disque*.
- L'index (`index\index.json`) est au format JSON et peut aussi être interrogé directement ou par tout autre outil ; il inclut un aperçu des premiers éléments du contenu pour la recherche plein texte.
