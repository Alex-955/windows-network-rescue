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

$script:Answers=New-Object 'System.Collections.Generic.Queue[string]'
$script:BackupCalls=0;$script:NotifyCalls=0;$script:NativeWrites=0;$script:AdminChecks=0
$script:RealSaveBackup=(Get-Item Function:\Save-Backup).ScriptBlock
function Save-Backup([string]$Kind,$Data){$script:BackupCalls++;return (& $script:RealSaveBackup $Kind $Data)}
function Notify-Proxy {$script:NotifyCalls++}
function Need-Admin {$script:AdminChecks++;if(-not $script:Admin){throw 'Admin required'}}
function Read-Host {if(-not $script:Answers.Count){throw 'Unexpected confirmation prompt'};return $script:Answers.Dequeue()}
function Open-ResultReport {}
function Run-Local([string]$File,[string]$Arguments,[int]$Seconds=12){
    if($Arguments-match '/flushdns|/renew|/resync|reset'){$script:NativeWrites++}
    return [pscustomobject]@{Text='Mock native command';ExitCode=0}
}
$script:Service=[pscustomobject]@{Status='Stopped';StartType='Automatic'}
$script:Service|Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {param($status,$timeout)}
$script:Service|Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
function Get-Service {return $script:Service}
function Start-Service {$script:Service.Status='Running';$script:Writes++}
function Get-ItemProperty {return [pscustomobject]@{Type='NTP';NtpServer='time.example.test,0x9'}}
function Counts {return "$script:Writes/$script:BackupCalls/$script:NotifyCalls/$script:NativeWrites/$script:AdminChecks"}
function DnsState {
    $s=State 0 0;$s.Manual=$false;$s.Dns=@()
    foreach($n in @('www.baidu.com','www.qq.com')){
        $s.Dns+=[pscustomobject]@{Name=$n;Server='';Success=$false}
        $s.Dns+=[pscustomobject]@{Name=$n;Server='223.5.5.5';Success=$true}
        $s.Dns+=[pscustomobject]@{Name=$n;Server='223.6.6.6';Success=$true}
    }
    return $s
}
function InfraState([string]$Type){
    $s=State 0 0
    $f=[pscustomobject]@{Adapters=@($script:Adapter);UpCount=1;HasWireless=$true;Services=@();Domain=$false;DhcpBad=$false;Single=$script:Adapter;Portal=$null;ClockHint=$false;TlsErrors=0;EnvironmentProxy=@();WinHttp='';Hosts=@();InternetTcp=@($false,$false)}
    switch($Type){'Service'{$f.Services=@([pscustomobject]@{Name='Dhcp';Status='Stopped';StartType='Automatic'})};'Dhcp'{$f.DhcpBad=$true};'Time'{$f.ClockHint=$true}}
    $s|Add-Member -NotePropertyName Facts -NotePropertyValue $f
    return $s
}
try{
    foreach($kind in @('Healthy','Partial','Proxy','Dns','Service','Dhcp','Time')){
        $script:Proxy[0].Value=if($kind-eq 'Proxy'){1}else{0}
        $s=switch($kind){'Healthy'{State 2 2};'Partial'{State 1 2};'Proxy'{State};'Dns'{DnsState};default{InfraState $kind}}
        $before=Counts;Queue $s;$r=Invoke-RepairPreview -Only
        Assert ($r.Status-eq 'Preview' -and (Counts)-ceq $before) "Read-only $kind must never mutate, flush, back up config, notify, elevate, or prompt"
        Assert ($null-ne $r.PreparedPlan -and $null-eq $r.After) 'A preview is not an executed result';Verify-EmptyQueue
    }
    Write-Host 'PASS: Read-only healthy, partial, proxy, DNS, service, DHCP, and time previews never call repair operations'
    $script:Proxy[0].Value=0;$script:RawDns='10.0.0.53';$before=Counts;Queue (DnsState);$r=Invoke-RepairPreview -Only
    Assert (-not $r.PreparedPlan.CanRepair -and (Counts)-ceq $before -and $r.PreparedPlan.Reason-match '手动 DNS') 'Static DNS blocker must be explained without repair';Verify-EmptyQueue
    $script:RawDns='';$script:Proxy[0].Value=1
    foreach($answer in @('','Y','apply')){
        $before=Counts;$script:Answers.Enqueue($answer);Queue (State);$r=Invoke-RepairPreview
        Assert ($r.Status-eq 'Cancelled' -and (Counts)-ceq $before) "No exact APPLY means no repair ($answer)";Verify-EmptyQueue
    }
    Write-Host 'PASS: Preflight blockers and empty/Y/lowercase confirmation cannot authorize changes'
    $before=$script:Writes;$script:Answers.Enqueue('APPLY');Queue (State);Queue (State);Queue (State);Queue {State 2 2}
    $r=Invoke-RepairPreview
    Assert ($r.Status-eq 'Repaired' -and $script:Writes-eq ($before+1) -and $script:Proxy[0].Value-eq 0) 'Exact APPLY permits only the fresh-state-validated proxy repair'
    Assert (@(Get-ChildItem $script:ReportDir -Filter '*-approved-plan.json').Count-gt 0) 'Approval must be recorded';Verify-EmptyQueue
    Write-Host 'PASS: Explicit confirmation permits the matching repair after independent fresh probes'
    $script:Proxy[0].Value=1;$before=Counts;$script:Answers.Enqueue('APPLY');Queue (State);Queue (State 2 2)
    $r=Invoke-RepairPreview;Assert ($r.Status-eq 'Changed' -and (Counts)-ceq $before) 'Recovered network invalidates prior approval';Verify-EmptyQueue
    $script:Answers.Enqueue('APPLY');Queue (State);Queue {$script:Proxy[1].Value='127.0.0.1:9999';State}
    $r=Invoke-RepairPreview;Assert ($r.Status-eq 'Changed' -and (Counts)-ceq $before) 'A different proxy target requires new approval';Verify-EmptyQueue
    $script:Proxy[1].Value='127.0.0.1:7897';$script:Answers.Enqueue('APPLY');Queue (State);Queue (State);Queue {$script:Proxy[1].Value='127.0.0.1:8888';State}
    $r=Invoke-RepairPreview;Assert ($r.Status-eq 'Changed' -and (Counts)-ceq $before) 'Late target change also stops before write';Verify-EmptyQueue
    $script:Proxy[1].Value='127.0.0.1:7897'
    Write-Host 'PASS: Recovery and early/late target changes invalidate stale approval without writes'
    $script:Proxy[0].Value=0;$before=$script:Writes;$nativeBefore=$script:NativeWrites;$backupBefore=$script:BackupCalls
    $script:Answers.Enqueue('APPLY');Queue (DnsState);Queue (DnsState);Queue (DnsState)
    Queue {$s=DnsState;foreach($d in $s.Dns){if($d.Server-eq '223.6.6.6'){$d.Success=$false}};return $s}
    $r=Invoke-RepairPreview
    Assert ($r.Status-eq 'Changed' -and $script:Writes-eq $before -and $script:NativeWrites-eq ($nativeBefore+1) -and $script:BackupCalls-eq $backupBefore) 'Changed DNS provider list cannot execute after approved cache flush'
    Assert ($r.Reason-match '清除 DNS 缓存' -and $r.Reason-match '未更换 DNS') 'Receipt distinguishes cache flush from DNS write';Verify-EmptyQueue
    Write-Host 'PASS: DNS plan changes after cache flush require renewed approval, with accurate receipt'
    $before=$script:Writes;$script:Answers.Enqueue('APPLY');Queue (InfraState 'Service');Queue (InfraState 'Service');Queue (InfraState 'Service');Queue (DnsState)
    $r=Invoke-RepairPreview
    Assert ($r.Status-eq 'Unresolved' -and $script:Writes-eq ($before+1) -and $r.Reason-match '另行确认') 'Service approval must not silently authorize another DNS repair';Verify-EmptyQueue
    Write-Host 'PASS: A confirmed infrastructure action cannot expand into another repair category'
    $script:Admin=$false;$script:Answers.Enqueue('APPLY');$before=$script:Writes;$nativeBefore=$script:NativeWrites
    Queue (DnsState);Queue (DnsState);Queue (DnsState);$r=Invoke-RepairPreview
    Assert ($r.Status-eq 'NeedsAdmin' -and $script:Writes-eq $before -and $script:NativeWrites-eq $nativeBefore -and $r.Reason-match 'PREVIEW.cmd') 'Elevation cannot bypass renewed preview/confirmation';Verify-EmptyQueue
    $script:Admin=$true
    Write-Host 'PASS: Administrator retry preserves preview and confirmation requirements'
    $script:Proxy[0].Value=1;Queue (State);$r=Invoke-RepairPreview -Only;$html=Get-Content -LiteralPath $r.HtmlReport -Raw
    Assert ($html.Contains('拟执行方案（尚未执行）') -and $html.Contains('CHECK-ONLY.cmd') -and $html.Contains('没有执行网络修复')) 'HTML separates proposed and completed work'
    $before=Counts;Queue (State);$r=Auto-Repair -RequireApproval
    Assert ($r.Status-eq 'Changed' -and (Counts)-ceq $before) 'Approval cannot be omitted';Verify-EmptyQueue
    Write-Host 'PASS: HTML separates plans from execution; missing approval is rejected'
    Write-Host 'ALL PREVIEW AND CONFIRMATION TESTS PASSED. No real machine settings were accessed.'
}finally{Remove-Item -LiteralPath $script:ReportDir -Recurse -Force}
