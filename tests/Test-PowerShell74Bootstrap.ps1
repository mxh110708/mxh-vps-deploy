[CmdletBinding()]
param([Parameter(Mandatory)] [string]$ProjectRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$initializer = Join-Path $ProjectRoot 'scripts/Initialize-PowerShell74.ps1'
$work = Join-Path $ProjectRoot ('.tmp/ps74-bootstrap-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$checks = 0
function Assert-Bootstrap([bool]$Value, [string]$Reason) {
    if (-not $Value) { throw ('PowerShell bootstrap regression: ' + $Reason) }
    $script:checks++
}
try {
    $badArchive = Join-Path $work 'invalid.zip'
    [IO.File]::WriteAllBytes($badArchive, [byte[]]@(1, 2, 3, 4))
    $destination = Join-Path $work 'runtime'
    $message = ''
    try { & $initializer -Destination $destination -ArchivePath $badArchive | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Bootstrap ($message -match 'checksum mismatch') 'wrong digest is rejected before extraction'
    Assert-Bootstrap (-not (Test-Path -LiteralPath $destination)) 'wrong archive creates no runtime directory'
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $sentinel = Join-Path $destination 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'preserved fixture')
    $before = (Get-FileHash -LiteralPath $sentinel).Hash
    $message = ''
    try { & $initializer -Destination $destination -ArchivePath $badArchive | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Bootstrap ($message -match 'new destination') 'existing runtime refuses overwrite'
    Assert-Bootstrap ((Get-FileHash -LiteralPath $sentinel).Hash -eq $before) 'existing files retain their bytes'
    Write-Output ('PowerShell bootstrap tests passed: {0} assertions; no download or system installation.' -f $checks)
}
finally {
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $temporaryRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.tmp')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWork.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Bootstrap fixture cleanup escaped test directory.' }
    [IO.Directory]::Delete($resolvedWork, $true)
}
