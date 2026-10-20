@echo off
echo === Lancement GUI avec surveillance du processus ===
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CdRepositoryGui.ps1"
echo === GUI termine - code de sortie : %ERRORLEVEL% ===
echo Code 0            : arret propre (script arrive a sa fin)
echo Code 1            : erreur PowerShell non geree
echo Code -1073741819  : access violation (0xC0000005) - crash natif
echo Code -1073741515  : DLL manquante (0xC0000135)
pause
