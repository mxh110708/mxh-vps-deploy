[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProjectRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $ProjectRoot 'src/VpsDeploy.Core.psm1') -Force
if(-not $IsWindows){Write-Host 'Windows SSH ACL tests skipped on this platform.';return}
& (Get-Module VpsDeploy.Core) {
    param($root)
    $directory=Join-Path $root ('.tmp/ssh-acl-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $key=Join-Path $directory 'id_ed25519'
    try{
        $keygen=Get-VpsCommandPath 'ssh-keygen.exe'
        $generated=Invoke-VpsProcess $keygen @('-t','ed25519','-N','','-f',$key) -TimeoutSeconds 20
        if($generated.ExitCode -ne 0){throw 'Test key generation failed'}
        $before=(Get-FileHash -LiteralPath $key).Hash
        $grant=Invoke-VpsProcess (Get-VpsCommandPath 'icacls.exe') @($key,'/grant','*S-1-5-11:(R)') -TimeoutSeconds 20
        if($grant.ExitCode -ne 0){throw 'Test ACL fixture creation failed'}
        Set-VpsOpenSshPrivateKeyAccess $key
        $probe=Invoke-VpsProcess $keygen @('-y','-P','','-f',$key) -TimeoutSeconds 20
        if($probe.ExitCode -ne 0){throw 'Repaired key is still rejected by OpenSSH'}
        if((Get-FileHash -LiteralPath $key).Hash -ne $before){throw 'ACL repair modified key content'}
        $sddl=(Get-Acl -LiteralPath $key).Sddl
        Set-VpsOpenSshPrivateKeyAccess $key
        if((Get-Acl -LiteralPath $key).Sddl -ne $sddl){throw 'Already accepted key ACL was changed'}
        function Invoke-VpsProcess {return @{ExitCode=1;StdOut='';StdErr='Load key: invalid format'}}
        $rejected=$false
        try{Set-VpsOpenSshPrivateKeyAccess $key}catch{$rejected=$true}
        if(-not $rejected -or (Get-Acl -LiteralPath $key).Sddl -ne $sddl){throw 'Non-ACL failure changed permissions or was not reported'}
        Write-Host 'SSH key ACL tests passed: explicit grant repaired; content preserved; valid ACL unchanged; non-ACL error preserved.' -ForegroundColor Green
    }finally{
        $resolved=[IO.Path]::GetFullPath($directory)
        if(-not $resolved.StartsWith([IO.Path]::GetFullPath((Join-Path $root '.tmp'))+[IO.Path]::DirectorySeparatorChar)){throw 'Unexpected cleanup path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
} $ProjectRoot
