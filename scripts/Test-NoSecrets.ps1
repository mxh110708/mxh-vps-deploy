[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$excludedDirectories = @('.git', '.test-output', '.tmp', 'TestResults')
$textExtensions = @('.ps1', '.psm1', '.psd1', '.sh', '.md', '.json', '.yml', '.yaml', '.txt', '.cmd')
$patterns = [ordered]@{
    'Private key block' = '-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----'
    'GitHub token' = '\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b'
    'Cloudflare tunnel token' = '\beyJ[a-zA-Z0-9_-]{40,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\b'
    'Concrete UUID' = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
    'Accidental root credential file' = '(?i)(^|[\\/])root\.txt$'
    'Accidental params file' = '(?i)(^|[\\/])params\.json$'
}

$findings = [Collections.Generic.List[object]]::new()
$files = Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File | Where-Object {
    $_.Extension -in $textExtensions -and
    -not ($_.FullName.Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $_ -in $excludedDirectories })
}
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($ProjectRoot, $file.FullName)
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($entry in $patterns.GetEnumerator()) {
        $target = if ($entry.Key -like 'Accidental*') { $relative } else { $content }
        if ($target -match $entry.Value) {
            $findings.Add([pscustomobject]@{ Rule = $entry.Key; File = $relative })
        }
    }
}

if ($findings.Count -gt 0) {
    $findings | Sort-Object Rule, File | Format-Table -AutoSize
    throw '检测到可能的实例秘密或私有归档文件。'
}
Write-Host "Secret scan passed: $($files.Count) text files" -ForegroundColor Green
