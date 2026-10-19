@{
    RootModule        = 'CdRepository.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b8a4d9f2-2c7e-4f1a-9d3b-6e5a8c1f0d24'
    Author            = 'CdRepository Tools'
    Description       = 'Gestion dun repository de compact disks (ISO) sur NAS Synology via SMB : copie, montage, index, recherche, categories.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Import-CdConfig','New-CdIndex','Get-CdIndex','Save-CdIndex',
        'Get-DriveLettersInUse','Get-MediaCategory','New-IsoImageFromDirectory',
        'Test-CdRepositoryRequirements','Test-CdIsAudio','Invoke-CdAudioRip','Get-KnownMusicFolder','Get-RippedFiles',
        'Copy-CdToRepository','Mount-CdFromRepository','Dismount-CdFromRepository',
        'Remove-CdFromRepository','Show-CdIndex','Search-CdIndex','Show-CdContent',
        'Get-CdCategories','Update-CdCategories','Move-CdEntry'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
}
