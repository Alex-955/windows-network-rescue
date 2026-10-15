$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../Windows-Net-Rescue/NetRescue.ps1'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($def in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) { Invoke-Expression $def.Extent.Text }
$script:ProxyPath='MOCK-REGISTRY'
$script:ProxyNames=@('ProxyEnable','ProxyServer','ProxyOverride','AutoConfigURL')
$script:Machine='test-machine'; $script:UserSid='test-user'
$script:ReportDir=Join-Path ([IO.Path]::GetTempPath()) ('net-rescue-auto-test-'+[guid]::NewGuid().ToString('N'))
$script:BackupDir=Join-Path $script:ReportDir 'Backups'
$null=New-Item -ItemType Directory -Path $script:BackupDir -Force
$script:Log=Join-Path $script:ReportDir 'test.log'
$script:Writes=0; $script:Protection=''; $script:PortOpen=$false
$script:Admin=$true; $script:Domain=$false; $script:RawDns=''; $script:Dns=@('192.0.2.1')
$script:Adapter=[pscustomobject]@{ifIndex=17;InterfaceGuid='11111111-1111-1111-1111-111111111111';Name='Wi-Fi';Status='Up';HardwareInterface=$true}
$script:Adapters=@($script:Adapter)
$script:Proxy=@(
    [pscustomobject]@{Name='ProxyEnable';Exists=$true;Value=1;Kind='DWord'},
    [pscustomobject]@{Name='ProxyServer';Exists=$true;Value='127.0.0.1:7897';Kind='String'},
    [pscustomobject]@{Name='ProxyOverride';Exists=$true;Value='192.168.*;<local>';Kind='String'},
    [pscustomobject]@{Name='AutoConfigURL';Exists=$false;Value=$null;Kind=''}
)
function Assert($condition,[string]$message) {if(-not $condition){throw "FAIL: $message"}}
function Clone($x) {return ($x|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
function State([int]$Normal=0,[int]$Direct=2) {
    $p=@(Clone $script:Proxy)
    return [pscustomobject]@{Proxy=$p;Fingerprint=(Proxy-Fingerprint $p);Manual=($p[0].Value-eq 1);Pac=[bool]$p[3].Value;Endpoint=(Get-LoopbackProxy ([string]$p[1].Value));LocalPortClosed=$true;Protection=$script:Protection;NormalOK=$Normal;DirectOK=$Direct;Dns=@()}
}
function Need-Admin {if(-not $script:Admin){throw 'Admin required'}}
function Get-ProxyProtection {return $script:Protection}
function Get-ProxySnapshot {return @(Clone $script:Proxy)}
function Notify-Proxy {}
function Tcp-Probe {return $script:PortOpen}
function Get-CimInstance {return [pscustomobject]@{PartOfDomain=$script:Domain}}
function Get-NetAdapter {return $script:Adapters}
function Get-NetIPInterface {return [pscustomobject]@{Dhcp='Enabled'}}
function Get-NetIPConfiguration {return [pscustomobject]@{InterfaceIndex=17;InterfaceAlias='Wi-Fi';IPv4Address=@([pscustomobject]@{IPAddress='192.0.2.7'});IPv4DefaultGateway=[pscustomobject]@{NextHop='192.0.2.1'}}}
function Get-NetIPAddress {return [pscustomobject]@{InterfaceIndex=17;IPAddress='192.0.2.7';AddressState='Preferred';PrefixOrigin='Dhcp'}}
function Get-NetRoute {return [pscustomobject]@{InterfaceIndex=17;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10}}
function Get-StaticDns {return $script:RawDns}
function Get-V4Dns {return [pscustomobject]@{InterfaceIndex=17;AddressFamily=2;ServerAddresses=@($script:Dns)}}
function Run-Local {return [pscustomobject]@{Text='Mock DNS cache flushed';ExitCode=0}}
function New-ItemProperty {
    param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force)
    Assert (@(Get-ChildItem $script:BackupDir -Filter '*-Proxy-*.json').Count -gt 0) 'Proxy mutation requires readable backup'
    $v=$script:Proxy|Where-Object{$_.Name-eq $Name}; $v.Exists=$true;$v.Value=$Value;$v.Kind=[string]$PropertyType
    $script:Writes++
}
function Remove-ItemProperty {
    param($LiteralPath,$Name,$ErrorAction)
    $v=$script:Proxy|Where-Object{$_.Name-eq $Name};$v.Exists=$false;$v.Value=$null;$v.Kind='';$script:Writes++
}
function Set-DnsClientServerAddress {
    param([Parameter(ValueFromPipeline=$true)]$InputObject,[string[]]$ServerAddresses,[switch]$ResetServerAddresses)
    process {
        Assert ($InputObject.InterfaceIndex-eq 17 -and $InputObject.AddressFamily-eq 2) 'Only selected IPv4 DNS may change'
        Assert (@(Get-ChildItem $script:BackupDir -Filter '*-Dns-*.json').Count -gt 0) 'DNS mutation requires backup'
        if($ResetServerAddresses){$script:RawDns='';$script:Dns=@('192.0.2.1')}
        else{$script:RawDns=$ServerAddresses-join ',';$script:Dns=@($ServerAddresses)}
        $script:Writes++
    }
}
$script:Queue=New-Object 'System.Collections.Generic.Queue[object]'
function Get-RepairState {
    if(-not $script:Queue.Count){throw 'Unexpected extra probe'}
    $item=$script:Queue.Dequeue()
    if($item-is [scriptblock]){return (& $item)}
    return $item
}
function Queue($x) {$script:Queue.Enqueue($x)}
function Verify-EmptyQueue {Assert ($script:Queue.Count-eq 0) 'All expected probes must run'}
try {
    foreach($input in @('127.0.0.1:7897','localhost:7897','[::1]:7897')) {Assert ($null-ne (Get-LoopbackProxy $input)) "Accept local endpoint $input"}
    foreach($input in @('http=127.0.0.1:7897;https=127.0.0.1:7897','192.0.2.2:7897','evil.example:7897','http://user:pass@localhost:7897','http://localhost:7897/a','localhost:99999')) {Assert ($null-eq (Get-LoopbackProxy $input)) "Reject ambiguous or nonlocal endpoint $input"}
    Write-Host 'PASS: Local endpoint parsing rejects remote, credentialed, and protocol-map proxies'
    Assert ((Get-AutoPlan (State 2 2)).Action-eq 'Healthy') 'Working Clash must stay enabled'
    Assert ((Get-AutoPlan (State 1 2)).Action-eq 'Partial') 'One failed website is insufficient'
    $s=State;$s.LocalPortClosed=$false;Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'Listening proxy must stay enabled'
    $s=State;$s.Protection='Running Clash';Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'Running client must stay enabled'
    $s=State;$s.Pac=$true;Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'PAC must stay untouched'
    $s=State 0 1;Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'Both direct probes required'
    Write-Host 'PASS: Healthy, partial, listening, running-client, PAC, and weak-evidence cases do not repair'

    $before=$script:Writes;Queue (State 2 2)
    $r=Auto-Repair;Assert ($r.Status-eq 'Healthy' -and $script:Writes-eq $before) 'Healthy automatic run must not write';Verify-EmptyQueue
    Queue (State);Queue (State);Queue {State 2 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'Repaired' -and $script:Proxy[0].Value-eq 0) 'Stale local proxy is disabled and verified'
    Assert ($script:Proxy[1].Value-eq '127.0.0.1:7897' -and $script:Proxy[2].Value-eq '192.168.*;<local>') 'Auto repair must retain address and bypass';Verify-EmptyQueue
    Write-Host 'PASS: Automatic stale proxy repair writes only its flag and requires successful post-tests'

    $script:Proxy[0].Value=1
    Queue (State);Queue (State);Queue {State 0 0};Queue {State 0 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'RolledBack' -and $script:Proxy[0].Value-eq 1) 'Failed proxy repair rolls back original config';Verify-EmptyQueue
    Write-Host 'PASS: Failed proxy repair restores original settings'

    $before=$script:Writes
    Queue (State);Queue { $script:Proxy[1].Value='127.0.0.1:9999'; State }
    $r=Auto-Repair;Assert ($r.Status-eq 'Changed' -and $script:Writes-eq $before) 'Configuration race must stop before mutation';Verify-EmptyQueue
    $script:Proxy[1].Value='127.0.0.1:7897'
    Queue (State);Queue (State);Queue { $script:Proxy[1].Value='127.0.0.1:8888'; State 0 2 }
    $r=Auto-Repair;Assert ($r.Status-eq 'Stopped' -and $script:Proxy[1].Value-eq '127.0.0.1:8888') 'Concurrent proxy change must not be overwritten';Verify-EmptyQueue
    Write-Host 'PASS: Proxy races are detected before writing and before rollback'

    $script:Proxy[0].Value=0;$script:Proxy[1].Value='127.0.0.1:7897'
    $script:DnsEvidence=@()
    foreach($n in @('www.baidu.com','www.qq.com')){
        $script:DnsEvidence += [pscustomobject]@{Name=$n;Server='';Success=$false}
        $script:DnsEvidence += [pscustomobject]@{Name=$n;Server='223.5.5.5';Success=$true}
        $script:DnsEvidence += [pscustomobject]@{Name=$n;Server='223.6.6.6';Success=$false}
    }
    function DnsState {$s=State 0 0;$s.Dns=$script:DnsEvidence;return $s}
    Assert ((Get-AutoPlan (DnsState)).Action-eq 'Dns') 'Correlated DNS evidence permits guarded DNS branch'
    $s=DnsState;$s.Dns=@($s.Dns|Where-Object{$_.Name-ne 'www.qq.com'});Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'One DNS domain is insufficient'
    $s=DnsState;$s.Dns=@($s.Dns|Where-Object{$_.Server});Assert ((Get-AutoPlan $s).Action-eq 'Unresolved') 'Timed-out/missing default results are insufficient'
    Write-Host 'PASS: DNS decision requires two default failures and same-provider successes for both domains'

    $script:Domain=$true
    try{$null=Get-AutoDnsAdapter;throw 'Unexpected success'}catch{Assert ($_.Exception.Message-match '组织域') 'Domain membership blocks automatic DNS'}
    $script:Domain=$false;$script:RawDns='10.0.0.53'
    try{$null=Get-AutoDnsAdapter;throw 'Unexpected success'}catch{Assert ($_.Exception.Message-match '手动 DNS') 'Static DNS blocks automatic DNS'}
    $script:RawDns='';$script:Adapters=@($script:Adapter,$script:Adapter)
    try{$null=Get-AutoDnsAdapter;throw 'Unexpected success'}catch{Assert ($_.Exception.Message-match '多个') 'Multiple adapters block automatic DNS'}
    $script:Adapters=@($script:Adapter)
    Write-Host 'PASS: Domain, static-DNS, and multi-interface environments are protected'

    $before=$script:Writes;$script:Admin=$false;Queue (DnsState);Queue (DnsState)
    $r=Auto-Repair;Assert ($r.Status-eq 'NeedsAdmin' -and $script:Writes-eq $before) 'Unprivileged DNS run must not write';Verify-EmptyQueue
    $script:Admin=$true
    Queue (DnsState);Queue (DnsState);Queue (DnsState);Queue {State 2 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'Repaired' -and ($script:Dns-join ',')-eq '223.5.5.5') 'Use only public DNS that passed both domains';Verify-EmptyQueue
    Write-Host 'PASS: Admin guard and DNS repair using only a tested provider'

    $script:RawDns='';$script:Dns=@('192.0.2.1')
    Queue (DnsState);Queue (DnsState);Queue (DnsState);Queue {State 0 0};Queue {State 0 0}
    $r=Auto-Repair;Assert ($r.Status-eq 'RolledBack' -and $script:RawDns-eq '' -and $script:Dns[0]-eq '192.0.2.1') 'Ineffective DNS trial must restore automatic mode';Verify-EmptyQueue
    Write-Host 'PASS: Ineffective DNS trial rolls back automatic mode'

    $script:Proxy[0].Value=1
    Queue (State);Queue (State);Queue {throw 'Injected probe failure'}
    $r=Auto-Repair;Assert ($r.Status-eq 'RolledBack' -and $script:Proxy[0].Value-eq 1) 'Post-write probe exception must restore proxy when no conflicting change exists';Verify-EmptyQueue
    $script:Proxy[0].Value=0
    Queue (DnsState);Queue (DnsState);Queue (DnsState);Queue {throw 'Injected DNS post-probe failure'}
    $r=Auto-Repair;Assert ($r.Status-eq 'RolledBack' -and $script:RawDns-eq '') 'Post-write DNS probe exception must restore automatic mode';Verify-EmptyQueue
    Write-Host 'PASS: Probe exceptions trigger guarded restoration of both proxy and DNS'

    function InfraState([string]$Type) {
        $s=State 0 0
        $f=[pscustomobject]@{Adapters=@($script:Adapter);UpCount=1;HasWireless=$true;Services=@();Domain=$false;DhcpBad=$false;Single=$script:Adapter;Portal=$null;ClockHint=$false;TlsErrors=0;EnvironmentProxy=@();WinHttp='';Hosts=@();InternetTcp=@($false,$false)}
        switch($Type){
            'Service' {$f.Services=@([pscustomobject]@{Name='Dhcp';Status='Stopped';StartType='Automatic'})}
            'Dhcp' {$f.DhcpBad=$true}
            'Time' {$f.ClockHint=$true}
            'Portal' {$f.Portal=[pscustomobject]@{Success=$true;Code=302;Content=''}}
            'NoAdapter' {$f.Adapters=@();$f.UpCount=0}
            'Disconnected' {$f.UpCount=0}
        }
        $s|Add-Member -NotePropertyName Facts -NotePropertyValue $f
        return $s
    }
    $before=$script:Writes
    foreach($type in @('Portal','NoAdapter','Disconnected')){
        $s=InfraState $type;Assert ((Get-InfrastructurePlan $s).Action-eq 'UserAction') "Specific user guidance for $type"
        Queue $s;$r=Auto-Repair;Assert ($r.Status-eq 'UserAction' -and $script:Writes-eq $before) "No writes for $type";Verify-EmptyQueue
    }
    $s=InfraState 'Service';$s.Facts.Services[0].StartType='Disabled';Assert ($null-eq (Get-InfrastructurePlan $s)) 'Intentionally disabled service must not auto-start'
    $s=InfraState 'Dhcp';$s.Facts.Domain=$true;Assert ($null-eq (Get-InfrastructurePlan $s)) 'Domain DHCP must not auto-renew'
    $s=InfraState 'Dhcp';$s.Protection='Active VPN';Assert ($null-eq (Get-InfrastructurePlan $s)) 'Active VPN prevents lease mutation'
    Write-Host 'PASS: Portal, missing driver, and disconnected WiFi produce targeted instructions; disabled services/domain/VPN protected'

    $script:Service=[pscustomobject]@{Status='Stopped';StartType='Automatic'}
    $script:Service|Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($status,$timeout)}
    $script:Service|Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
    function Get-Service {return $script:Service}
    function Start-Service {$script:Service.Status='Running';$script:Writes++}
    $script:Commands=@()
    function Run-Local([string]$File,[string]$Arguments,[int]$Seconds=12){$script:Commands+="$File $Arguments";return [pscustomobject]@{Text='Mock native command completed';ExitCode=0}}
    function Get-ItemProperty {return [pscustomobject]@{Type='NTP'}}
    Queue (InfraState 'Service');Queue (InfraState 'Service');Queue {State 2 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'Repaired' -and $script:Service.Status-eq 'Running') 'Stopped automatic network service started and retested';Verify-EmptyQueue
    Queue (InfraState 'Dhcp');Queue (InfraState 'Dhcp');Queue {State 2 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'Repaired' -and 'ipconfig.exe /renew "Wi-Fi"'-in $script:Commands) 'Only selected adapter DHCP renewal';Verify-EmptyQueue
    Assert (@($script:Commands|Where-Object{$_-match '/release|winsock|reset proxy'}).Count-eq 0) 'No global reset/release commands'
    Queue (InfraState 'Time');Queue (InfraState 'Time');Queue {State 2 2}
    $r=Auto-Repair;Assert ($r.Status-eq 'Repaired' -and 'w32tm.exe /resync'-in $script:Commands) 'Clock hint triggers only existing-source sync';Verify-EmptyQueue
    Write-Host 'PASS: Network service, scoped DHCP renewal, and existing-source time sync require post-tests'

    $script:Admin=$false;$before=$script:Writes;Queue (InfraState 'Service')
    $r=Auto-Repair;Assert ($r.Status-eq 'NeedsAdmin' -and $script:Writes-eq $before) 'Infrastructure repair requires administrator';Verify-EmptyQueue
    $script:Admin=$true
    Queue (InfraState 'Dhcp');Queue (InfraState 'Dhcp');Queue (InfraState 'Dhcp');Queue (InfraState 'Dhcp')
    $r=Auto-Repair;Assert ($r.Status-eq 'Unresolved') 'Same DHCP fault is not repeatedly renewed';Verify-EmptyQueue
    Write-Host 'PASS: Infrastructure permission guard and bounded repair attempts'

    $receipt=[pscustomobject]@{Status='UserAction';Reason='<script>alert(1)</script>';Before=$null;After=$null;Backup='';Actions=@('Test only')}
    $preview=Join-Path $script:ReportDir 'test.html';Write-ResultHtml $receipt $preview
    $html=Get-Content $preview -Raw
    Assert ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') -and -not $html.Contains('<script>')) 'HTML report must encode diagnostic content'
    Assert (-not $html.Contains('<script src=') -and -not $html.Contains('fonts.googleapis.com')) 'HTML report works offline'
    Write-Host 'PASS: HTML diagnostics are escaped and have no external dependencies'
    $facts=Get-NetworkFacts @() $false
    Assert ($facts.Single.ifIndex-eq 17 -and -not $facts.DhcpBad -and $facts.Configs[0].Gateway[0]-eq '192.0.2.1') 'Network facts collector must retain correct interface/address/gateway relationships'
    function Get-NetIPAddress {return [pscustomobject]@{InterfaceIndex=17;IPAddress='192.0.2.7';AddressState='Duplicate';PrefixOrigin='Dhcp'}}
    $facts=Get-NetworkFacts @() $false
    Assert ($facts.DhcpBad) 'Windows-reported duplicate DHCP address must be detected'
    Write-Host 'PASS: Actual facts collector handles valid DHCP and duplicate-address evidence'
    Write-Host 'ALL AUTO-REPAIR TESTS PASSED. No real machine settings were accessed.'
}finally{Remove-Item -LiteralPath $script:ReportDir -Recurse -Force}
