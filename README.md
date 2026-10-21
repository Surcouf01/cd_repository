# CD Repository Tools

Ensemble d'outils pour archiver des compact disks sur un **NAS Synology** (partage SMB) et les remonter à la demande sur Windows.

## État des fonctionnalités (octobre 2025)

| Fonctionnalité | État | Notes |
|---|---|---|
| Copie CD de données → ISO sur le NAS | ✅ | Copie locale temporaire puis ISO ISO9660+Joliet via IMAPI2 |
| Copie CD audio (CDDA) | ✅ | Rip via WMP 32 bits (sous-job dédié), réutilisation des pistes déjà extraites si l'album est connu de WMP |
| Copie CD/DVD chiffré (CSS) | ❌ | Arrêt immédiat avec message explicite : les DVD vidéo commerciaux ne sont pas archivables par copie de fichiers |
| Montage ISO (CD de données) | ✅ | Élévation UAC à la demande (comme une installation) ; l'ISO est copié localement avant montage car le compte élevé n'a pas la session SMB |
| Démontage ISO | ✅ | Mémo persistant du chemin local (`ProgramData\cdrepo\mounted_paths.json`), nettoyage de la copie |
| Montage CD audio | ✅ | Mappage `net use` d'une lettre libre vers le dossier NAS, sans élévation |
| Démontage CD audio | ✅ | `net use /delete /y`, vérification réelle de la libération de la lettre |
| Recherche / filtre par catégorie | ✅ | Recherche plein texte (titre, description, fichier, contenu) |
| Resynchronisation de l'index au démarrage | ✅ | Scan du NAS : ajoute les ISO non référencés, marque les fichiers manquants/invalides et catégories inconnues |
| Code couleur dans la grille | ✅ | Rouge = ISO invalide/manquant, orange = catégorie inconnue, bleu = ajouté par scan, blanc = OK |
| Suppression d'un disque | ✅ | Asynchrone (runspace, l'UI reste fluide), timeout 20 s, `-Recurse` pour les conteneurs audio |
| Impression de la liste | ✅ | Dialogue de choix d'imprimante, tableau de la vue courante |
| Message d'état copiable | ✅ | Clic = tout sélectionner, Ctrl+C |
| Purge des fichiers temporaires | ✅ | Au démarrage du GUI : fichiers de plus de 24 h (ISO locaux orphelins, traces de rip, résultats d'élévation) |
| Overlay de progression | ✅ | Limité à la fenêtre principale (Owner), plus de Topmost global |
| Gravure | ❌ | Non incluse : clic droit sur l'ISO → *Graver l'image du disque* |

## Architecture

- **Composant 1 — Repository NAS** : un dossier partagé SMB sur le Synology (ex. `\\NAS\cd-repository`) contenant :
  - un sous-répertoire par thème : `jeux`, `peripheriques`, `films`, `musique`, `autre`
  - un dossier `index\` avec `index.json` (titre, catégorie, taille, date, aperçu du contenu)
- **Composant 2 — Logiciel Windows** (PowerShell 5.1, natif, aucune dépendance) :
  - `CdRepository.psd1` / `CdRepository.psm1` : module (API + logique)
  - `CdRepositoryGui.ps1` : **interface graphique WPF** (recommandée)
  - `Start-CdRepository.ps1` : menu interactif en console
  - `Copy-CdJob.ps1` / `Rip-CdJob.ps1` : sous-jobs isolés (copie 64 bits, rip WMP 32 bits)
  - `Launch-Gui-Debug.cmd` : lanceur console (affiche le code de sortie en cas de disparition du GUI)
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

1. Copier le dossier du dépôt sur le PC Windows.
2. `Copy-Item config.example.json config.json` puis adapter `RepositoryRoot` (chemin UNC ou lecteur réseau) et `DriveLetters` (lettres autorisées pour le montage, ex. `"EFGHIJK..."`).
3. Le module s'appuie sur des composants natifs :
   - **IMAPI2** (`IMAPI2.MsftFileSystemImage`) pour créer les ISO — inclus dans Windows ;
   - **Mount-DiskImage / Add-PartitionAccessPath** pour le montage — Windows 8+/Server 2012+, exige une élévation administrateur (demandée à la demande via UAC) ;
   - **Windows Media Player** pour le rip des CD audio (contrôle ActiveX 32 bits : le rip tourne dans un sous-job 32 bits dédié) ;
   - le partage SMB est directement utilisé par les chemins de fichiers.

## Utilisation

```powershell
# Interface graphique WPF (lanceur recommandé : nouvelle console à chaque fois)
.\Launch-Gui-Debug.cmd

# Ou directement
powershell -ExecutionPolicy Bypass -File .\CdRepositoryGui.ps1

# Ou menu interactif console
powershell -ExecutionPolicy Bypass -File .\Start-CdRepository.ps1
```

### Interface graphique

- **DataGrid** de l'index (titre, catégorie, taille, date, description) avec code couleur d'anomalies
- **Recherche** plein texte + filtre par catégorie
- Boutons : **Copier un CD** (boîte de dialogue lettre/titre/catégorie, overlay de progression avec piste en cours pour les CD audio), **Monter** (première lettre libre, ouvre l'Explorateur ; UAC uniquement pour les ISO), **Démonter**, **Déplacer** (changement de catégorie), **Supprimer** (confirmation, asynchrone), **Imprimer...** (choix de l'imprimante)
- Panneau **Contenu du disque sélectionné** et barre d'état copiable
- Au démarrage : purge des temporaires anciens, resynchronisation de l'index depuis le NAS

### Comportements spécifiques

- **Élévation à la demande** : Monter/Démonter un ISO demande l'élévation UAC (comme une installation de programme), uniquement pour ces opérations. Le GUI lui-même reste non élevé. L'ISO est copié en local (`C:\ProgramData\cdrepo\`) avant l'élévation car le compte administrateur de l'UAC n'a pas la session SMB du NAS.
- **CD audio** : le montage mappe le dossier NAS sur une lettre libre (`net use`, sans élévation) ; le démontage libère la lettre (force la fermeture des fichiers ouverts). Si WMP a déjà extrait l'album, la copie réutilise les fichiers existants au lieu de re-ripper.
- **DVD vidéo chiffrés** : la copie s'arrête immédiatement avec un message explicite (chiffrement CSS détecté).

### API (module)

```powershell
Import-Module .\CdRepository.psd1

# Copier un CD (crée l'ISO dans la catégorie, met à jour l'index)
Copy-CdToRepository -Title 'Age of Empires' -DriveLetter 'D' -Category 'jeux' -Description 'CD original 1997'

# Monter sur la première lettre disponible (ou lettre préférée)
Mount-CdFromRepository -Id '<guid>'
Mount-CdFromRepository -Id '<guid>' -PreferredLetter 'M'
Dismount-CdFromRepository -Id '<guid>'

# Organiser par thèmes (sous-répertoires)
Move-CdEntry -Id '<guid>' -Category 'films'
Get-CdCategories   # jeux, peripheriques, films, musique, autre

# Visualiser l'index / rechercher
Show-CdIndex
Show-CdIndex -Category 'musique'
Search-CdIndex -Query 'empire' -Category 'jeux'

# Afficher le contenu d'un CD (monte, liste, démonte)
Show-CdContent -Id '<guid>'
Show-CdContent -Id '<guid>' -Full

# Resynchroniser l'index depuis le NAS (ajouts, détection d'anomalies)
Sync-CdIndexFromDisk

# Supprimer
Remove-CdFromRepository -Id '<guid>'
```

## Diagnostic

- **Logs** : `%TEMP%\CdRepositoryGui.log` (GUI), `%TEMP%\cdrepo_job\job.log` (job de copie), `[RIP32]`/`[WMPRAW]` pour le rip audio.
- **Lanceur debug** : `Launch-Gui-Debug.cmd` garde la console ouverte et affiche le code de sortie du GUI (utile en cas de disparition de la fenêtre : `0` = arrêt propre, `-1073741819` = crash natif, etc.).
- Le message d'état du GUI est sélectionnable/copiable pour rapporter les erreurs exactes.

## Limites connues

- **DVD vidéo commerciaux (CSS)** : non archivables — arrêt immédiat avec message.
- **CD de plus de 2 Go** : pris en charge (comptes 64 bits), la copie locale de gros volumes prend plusieurs minutes.
- Le montage d'un gros ISO copie tout le volume en local avant l'UAC (limite de l'architecture session-utilisateur/session-admin séparées).
- La gravure n'est pas incluse.
- L'index (`index\index.json`) est au format JSON et peut aussi être interrogé directement ou par tout autre outil.
