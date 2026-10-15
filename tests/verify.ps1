$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../Windows-Net-Rescue/NetRescue.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Load functions only; never run the Windows entry point or touch real settings.
$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($def in $defs) { Invoke-Expression $def.Extent.Text }
$script:ProxyPath = 'MOCK-REGISTRY'
$script:ProxyNames = @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')
$script:Machine = 'test-machine'
$script:UserSid = 'test-user'
$script:ReportDir = Join-Path ([IO.Path]::GetTempPath()) ('net-rescue-test-' + [guid]::NewGuid().ToString('N'))
$script:BackupDir = Join-Path $script:ReportDir 'Backups'
$null = New-Item -ItemType Directory -Path $script:BackupDir -Force
$script:Log = Join-Path $script:ReportDir 'test.log'
$script:Adapter = [pscustomobject]@{ ifIndex = 17; Name = 'Wi-Fi'; InterfaceGuid = '11111111-1111-1111-1111-111111111111'; Status = 'Up'; InterfaceDescription = 'Mock WiFi' }
$script:Commands = @()
$script:Writes = 0
$script:AdminAllowed = $true
$script:Answers = New-Object 'System.Collections.Generic.Queue[string]'
function Assert($condition, [string]$message) { if (-not $condition) { throw "FAIL: $message" } }
function Need-Admin { if (-not $script:AdminAllowed) { throw 'Admin required' } }
function Confirm-Change { return $true }
function Notify-Proxy { }
function Read-Host { return $script:Answers.Dequeue() }
function Select-Adapter { return $script:Adapter }
function Get-NetAdapter { return $script:Adapter }
function Get-StaticDns { return $script:RawDns }
function Get-V4Dns { return [pscustomobject]@{ InterfaceIndex = 17; AddressFamily = 2; ServerAddresses = @($script:Dns) } }
function Set-DnsClientServerAddress {
    param([Parameter(ValueFromPipeline=$true)]$InputObject, [string[]]$ServerAddresses, [switch]$ResetServerAddresses)
    process {
        Assert ($InputObject.AddressFamily -eq 2 -and $InputObject.InterfaceIndex -eq 17) 'Only selected IPv4 object may be mutated'
        Assert (@(Get-ChildItem $script:BackupDir -Filter '*.json').Count -gt 0) 'Backup must exist before DNS write'
        $script:Writes++
        if ($ResetServerAddresses) { $script:RawDns = ''; $script:Dns = @('192.0.2.1') }
        else { $script:RawDns = $ServerAddresses -join ','; $script:Dns = @($ServerAddresses) }
    }
}
function Run-Local([string]$File, [string]$Arguments, [int]$Seconds = 12) {
    $script:Commands += "$File $Arguments"
    return [pscustomobject]@{ Text = 'Mock command OK'; ExitCode = 0 }
}
function Get-ProxySnapshot {
    return @($script:Proxy | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Exists=$_.Exists; Value=$_.Value; Kind=$_.Kind } })
}
function New-ItemProperty {
    param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force)
    Assert (@(Get-ChildItem $script:BackupDir -Filter '*.json').Count -gt 0) 'Backup must exist before proxy write'
    $v = $script:Proxy | Where-Object { $_.Name -eq $Name }
    $v.Exists=$true; $v.Value=$Value; $v.Kind=[string]$PropertyType
    $script:Writes++
}
function Remove-ItemProperty {
    param($LiteralPath,$Name,$ErrorAction)
    $v = $script:Proxy | Where-Object { $_.Name -eq $Name }
    $v.Exists=$false; $v.Value=$null; $v.Kind=''
    $script:Writes++
}
function Choose-Backup([string]$path) {
    $all = @(Get-ChildItem $script:BackupDir -Filter '*.json' | Sort-Object Name -Descending)
    for ($i=0; $i -lt $all.Count; $i++) { if ($all[$i].FullName -eq $path) { $script:Answers.Enqueue([string]($i+1)); return } }
    throw 'Test backup missing'
}
try {
    $script:RawDns = ''; $script:Dns = @('192.0.2.1')
    Change-Dns
    $autoBackup = @(Get-ChildItem $script:BackupDir -Filter '*-Dns-*.json')[0].FullName
    Assert (($script:Dns -join ',') -eq '223.5.5.5,223.6.6.6') 'DNS repair applies public servers'
    Choose-Backup $autoBackup
    Restore-Backup
    Assert ($script:RawDns -eq '' -and $script:Dns[0] -eq '192.0.2.1') 'DHCP DNS must restore automatic mode, not pin previous DHCP address'
    Write-Host 'PASS: DNS backup, selected interface/family, and automatic-mode restoration'

    $script:RawDns = '10.0.0.53 10.0.0.54'; $script:Dns = @('10.0.0.53','10.0.0.54')
    $staticBackup = Save-Backup 'Dns' ([pscustomobject]@{ Guid=[string]$script:Adapter.InterfaceGuid; Alias='Wi-Fi'; StaticRaw=$script:RawDns; Servers=$script:Dns })
    $script:RawDns='223.5.5.5'; $script:Dns=@('223.5.5.5')
    Choose-Backup $staticBackup
    Restore-Backup
    Assert (($script:Dns -join ',') -eq '10.0.0.53,10.0.0.54') 'Static DNS list must restore both addresses'
    Write-Host 'PASS: Static DNS restoration'

    $script:Proxy=@(
        [pscustomobject]@{ Name='ProxyEnable'; Exists=$true; Value=1; Kind='DWord' },
        [pscustomobject]@{ Name='ProxyServer'; Exists=$true; Value='127.0.0.1:7890'; Kind='String' },
        [pscustomobject]@{ Name='ProxyOverride'; Exists=$false; Value=$null; Kind='' },
        [pscustomobject]@{ Name='AutoConfigURL'; Exists=$true; Value='http://localhost/test.pac'; Kind='String' }
    )
    Disable-Proxy
    $proxyBackup = @(Get-ChildItem $script:BackupDir -Filter '*-Proxy-*.json')[0].FullName
    Assert ($script:Proxy[0].Value -eq 0 -and -not $script:Proxy[3].Exists) 'Manual proxy and PAC disabled'
    Choose-Backup $proxyBackup
    Restore-Backup
    Assert ($script:Proxy[0].Value -eq 1 -and $script:Proxy[3].Value -eq 'http://localhost/test.pac' -and -not $script:Proxy[2].Exists) 'Proxy values and missing properties restored'
    Write-Host 'PASS: Proxy backup, PAC restoration, and absent property preservation'

    $savedMachine=$script:Machine; $script:Machine='other-machine'; $before=$script:Writes
    Choose-Backup $staticBackup
    try { Restore-Backup; throw 'Unexpected success' } catch { Assert ($_.Exception.Message -match '不属于本机') 'Wrong machine must be rejected' }
    Assert ($before -eq $script:Writes) 'Wrong-machine backup must not mutate configuration'
    $script:Machine=$savedMachine
    $savedUser=$script:UserSid; $script:UserSid='other-user'
    Choose-Backup $proxyBackup
    try { Restore-Backup; throw 'Unexpected success' } catch { Assert ($_.Exception.Message -match '其他用户') 'Wrong user must be rejected' }
    Assert ($before -eq $script:Writes) 'Wrong-user backup must not mutate configuration'
    $script:UserSid=$savedUser
    Write-Host 'PASS: Wrong machine and wrong user are rejected without writes'

    $script:AdminAllowed=$false
    try { Change-Dns; throw 'Unexpected success' } catch { Assert ($_.Exception.Message -eq 'Admin required') 'DNS requires administrator' }
    Assert ($before -eq $script:Writes) 'Unprivileged DNS request must not write'
    $script:AdminAllowed=$true
    Write-Host 'PASS: Administrator guard'

    function Confirm-Change { return $false }
    Change-Dns
    Disable-Proxy
    Reset-Winsock
    Assert ($before -eq $script:Writes) 'Cancel must not mutate settings'
    Assert (@($script:Commands | Where-Object { $_ -like '*winsock reset*' }).Count -eq 0) 'Cancel must not reset Winsock'
    Write-Host 'PASS: Canceled repairs do not write'
    Write-Host 'ALL ISOLATED TESTS PASSED. No real Windows configuration was accessed.'
} finally {
    # Only remove the generated, uniquely named test output directory.
    Remove-Item -LiteralPath $script:ReportDir -Recurse -Force
}
