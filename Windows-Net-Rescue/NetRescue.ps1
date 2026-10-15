#requires -Version 5.1
# Offline Windows 10/11 toolkit. Save as UTF-8 with BOM for Windows PowerShell.
[CmdletBinding()]
param([switch]$DiagnoseOnly, [switch]$AutoRepair, [switch]$PreviewOnly, [switch]$PreviewRepair, [switch]$CleanupReports)

$ErrorActionPreference = 'Stop'
$cleanupLibrary = Join-Path $PSScriptRoot 'ReportCleanup.ps1'
if (-not (Test-Path -LiteralPath $cleanupLibrary)) { throw '缺少 ReportCleanup.ps1，请复制或解压整个新版工具文件夹。' }
. $cleanupLibrary
$script:ProxyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:ProxyNames = @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')

function Say([string]$Text) {
    Write-Host $Text
    Add-Content -LiteralPath $script:Log -Value $Text -Encoding UTF8
}
function Section([string]$Title) { Say "`r`n======== $Title ========" }
function Need-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '此操作需要管理员权限。退出工具，右键 START.cmd，选择“以管理员身份运行”，再选择这个操作。'
    }
}
function Confirm-Change([string]$Text) {
    Say $Text
    return ((Read-Host '确认执行请输入 Y，其他输入取消') -eq 'Y')
}
function Run-Local([string]$File, [string]$Arguments, [int]$Seconds = 12) {
    # Concurrent stream reads avoid deadlocks; no command shell is involved.
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $File
    $si.Arguments = $Arguments
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $si.StandardErrorEncoding = $si.StandardOutputEncoding
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    try {
        [void]$p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($Seconds * 1000)) {
            $p.Kill()
            [void]$p.WaitForExit(3000)
            throw "命令超时：$File $Arguments。结果不确定，请重新检测后判断。"
        }
        $out = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ Text = $out; ExitCode = $p.ExitCode }
    } finally { $p.Dispose() }
}
function Tcp-Probe([string]$Address, [int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect($Address, $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne(2500)) { return $false }
        $c.EndConnect($a)
        return $true
    } catch { return $false } finally { $c.Close() }
}
function Web-Probe([string]$Url, [bool]$Direct) {
    $response = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $req.AllowAutoRedirect = $false
        if ($Direct) { $req.Proxy = $null }
        else { $req.Proxy = [Net.WebRequest]::GetSystemWebProxy() }
        $response = $req.GetResponse()
        $content = ''
        if ($Url -eq 'http://www.msftconnecttest.com/connecttest.txt') {
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $buffer = New-Object char[] 256; $count = $reader.Read($buffer, 0, 256); if ($count -gt 0) { $content = -join $buffer[0..($count - 1)] } } finally { $reader.Dispose() }
        }
        return [pscustomobject]@{ Url = $Url; Direct = $Direct; Success = $true; Healthy = ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300); Code = [int]$response.StatusCode; Date = [string]$response.Headers['Date']; Content = $content; ErrorKind = ''; Detail = "HTTP $([int]$response.StatusCode)，Location=$($response.Headers['Location'])" }
    } catch {
        # An HTTP error still proves an HTTP server answered, but not usable Internet.
        $errorItem = $_.Exception
        while ($errorItem.InnerException -and $errorItem -isnot [Net.WebException]) { $errorItem = $errorItem.InnerException }
        $kind = [string]$errorItem.Status
        return [pscustomobject]@{ Url = $Url; Direct = $Direct; Success = $false; Healthy = $false; Code = 0; Date = ''; Content = ''; ErrorKind = $kind; Detail = $_.Exception.Message }
    } finally { if ($null -ne $response) { $response.Close() } }
}
function Dns-Probes {
    $jobs = @()
    try {
        foreach ($name in @('www.baidu.com', 'www.qq.com')) {
            foreach ($server in @('', '223.5.5.5', '223.6.6.6')) {
                $jobs += Start-Job -ArgumentList $name, $server -ScriptBlock {
                    param($n, $s)
                    try {
                        $argsDns = @{ Name = $n; Type = 'A'; DnsOnly = $true; NoHostsFile = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
                        if ($s) { $argsDns.Server = $s }
                        $ips = @(Resolve-DnsName @argsDns | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
                        [pscustomobject]@{ Name = $n; Server = $s; Success = ($ips.Count -gt 0); Addresses = $ips; Error = '' }
                    } catch {
                        [pscustomobject]@{ Name = $n; Server = $s; Success = $false; Addresses = @(); Error = $_.Exception.Message }
                    }
                }
            }
        }
        $null = Wait-Job -Job $jobs -Timeout 15
        foreach ($job in $jobs) {
            if ($job.State -eq 'Completed') { Receive-Job $job }
            else { [pscustomobject]@{ Name = [string]$job.Id; Server = '超时或任务异常'; Success = $false; Addresses = @(); Error = '本项未完成，不能据此断言 DNS 失败' } }
        }
    } finally {
        foreach ($job in $jobs) {
            if ($job.State -eq 'Running') { Stop-Job $job -ErrorAction SilentlyContinue }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}
function Get-ProxySnapshot {
    $key = Get-Item -LiteralPath $script:ProxyPath
    $values = @()
    foreach ($n in $script:ProxyNames) {
        $exists = @($key.GetValueNames()) -contains $n
        $values += [pscustomobject]@{ Name = $n; Exists = $exists; Value = $null; Kind = '' }
        if ($exists) {
            $values[-1].Value = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $values[-1].Kind = [string]$key.GetValueKind($n)
        }
    }
    return $values
}
function Notify-Proxy {
    if (-not ('NetRescue.WinInet' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetRescue {
    public class WinInet {
        [DllImport("wininet.dll", SetLastError=true)]
        public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
    }
}
'@
    }
    [void][NetRescue.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][NetRescue.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}
function Save-Backup([string]$Kind, $Data) {
    $backup = [ordered]@{
        Version = 1; Kind = $Kind; Time = (Get-Date -Format o)
        Machine = $script:Machine; UserSid = $script:UserSid; Data = $Data
    }
    $path = Join-Path $script:BackupDir ("{0}-{1}-{2}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $Kind, ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $backup | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    # Ensure the backup is readable before any write.
    $null = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Say "已保存修改前备份：$path"
    return $path
}
function Select-Adapter {
    $list = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex)
    if (-not $list.Count) { throw '没有已连接网卡，请先连接 WiFi。' }
    Say '请选择当前连接家庭 WiFi 的真实网卡，避开 VPN、虚拟网卡。'
    foreach ($a in $list) { Say ("索引 {0}：{1} / {2}" -f $a.ifIndex, $a.Name, $a.InterfaceDescription) }
    $number = Read-Host '输入网卡索引，输入其他内容取消'
    $selected = @($list | Where-Object { [string]$_.ifIndex -eq $number })
    if ($selected.Count -ne 1) { throw '已取消：未选中网卡。' }
    return $selected[0]
}
function Get-V4Dns($Adapter) {
    return Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
}
function Get-StaticDns($Adapter) {
    $guid = ([guid]$Adapter.InterfaceGuid).ToString('B')
    $key = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
    return [string]$key.NameServer
}
function Show-Dns($Adapter) {
    Say ("网卡 {0} 当前 IPv4 DNS：{1}" -f $Adapter.Name, ((Get-V4Dns $Adapter).ServerAddresses -join ', '))
    Say ("静态 DNS 配置：{0}（空白代表自动获取）" -f (Get-StaticDns $Adapter))
}
function Diagnose {
    Section '开始只读诊断（会向公开网站发送少量网络测试请求）'
    Say ("系统时间：{0}。请与手机时间核对；时间严重错误会造成 HTTPS 错误。" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    Say "本次报告：$script:Log"
    foreach ($command in @(
        @('ipconfig.exe', '/all'), @('route.exe', 'print'),
        @('netsh.exe', 'wlan show interfaces'), @('netsh.exe', 'winhttp show proxy')
    )) {
        try {
            $result = Run-Local $command[0] $command[1]
            Say "`r`n> $($command -join ' ')`r`n$($result.Text)"
        } catch { Say "读取失败：$($_.Exception.Message)" }
    }
    Section 'IP、默认网关及 VPN / 虚拟网卡'
    $configs = @(Get-NetIPConfiguration)
    Say ($configs | Format-List InterfaceAlias, InterfaceIndex, IPv4Address, IPv4DefaultGateway, IPv6Address, IPv6DefaultGateway, DNSServer | Out-String -Width 180)
    Say (Get-NetAdapter | Format-Table ifIndex, Name, Status, InterfaceDescription -AutoSize | Out-String -Width 180)
    $gateways = @($configs | ForEach-Object { $_.IPv4DefaultGateway } | Where-Object { $_ } | Select-Object -ExpandProperty NextHop -Unique)
    foreach ($gateway in $gateways) {
        $ping = New-Object Net.NetworkInformation.Ping
        try { Say "网关 $gateway Ping：$($ping.Send($gateway, 1800).Status)" }
        catch { Say "网关 $gateway Ping 未得到回复：$($_.Exception.Message)" }
        finally { $ping.Dispose() }
    }
    if (-not $gateways.Count) { Say '未发现 IPv4 默认网关：需检查 IP、DHCP 或路由；IPv6 情况需结合上方信息判断。' }
    if (@($configs | ForEach-Object { $_.IPv4Address } | Where-Object { $_.IPAddress -like '169.254.*' }).Count) {
        Say '发现 169.254.x.x 地址：该网卡可能没有从路由器取得有效的 IPv4 地址。'
    }
    Section '代理与 hosts（只读）'
    $proxy = @(Get-ProxySnapshot)
    Say ($proxy | Format-Table Name, Exists, Value -AutoSize | Out-String -Width 180)
    foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($n)
        if ($value) { Say "进程环境变量 $n = $value" }
    }
    $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsLines = @(Get-Content -LiteralPath $hostsFile | Where-Object { $_ -match '^\s*[^#\s]' })
    Say ("hosts 有效条目：{0}" -f $hostsLines.Count)
    if ($hostsLines.Count) { Say ($hostsLines -join "`r`n") }
    Section 'DNS 对照测试（两个域名，默认 DNS 与阿里公共 DNS）'
    $script:LastDns = @(Dns-Probes)
    foreach ($d in $script:LastDns) {
        $label = $d.Server
        if (-not $label) { $label = '系统默认 DNS' }
        Say ("{0} / {1}：{2}，{3} {4}" -f $d.Name, $label, $d.Success, ($d.Addresses -join ', '), $d.Error)
    }
    $dnsFile = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-dns.json')
    $script:LastDns | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $dnsFile -Encoding UTF8
    Section '直接访问公网 IP 的 TCP 测试（不依赖 DNS）'
    $tcp = @((Tcp-Probe '223.5.5.5' 443), (Tcp-Probe '1.1.1.1' 443))
    Say "223.5.5.5:443 = $($tcp[0])；1.1.1.1:443 = $($tcp[1])"
    Say '任一成功说明该地址端口可达；全部失败也不能单独证明外网断开，目标或网络可能限制测试。'
    Section '网页连通性测试'
    $webResults = @()
    foreach ($url in @('https://www.baidu.com/', 'https://www.qq.com/')) {
        foreach ($direct in @($true, $false)) {
            $w = Web-Probe $url $direct
            $webResults += $w
            Say ("{0} / 强制直连={1}：{2} {3}" -f $w.Url, $w.Direct, $w.Success, $w.Detail)
        }
    }
    $http = Web-Probe 'http://www.msftconnecttest.com/connecttest.txt' $true
    Say "HTTP 辅助测试：$($http.Success) $($http.Detail)。重定向可能是网络认证，请结合浏览器确认。"
    Section '初步判断与建议'
    $defaultOk = @($script:LastDns | Where-Object { -not $_.Server -and $_.Success }).Count
    $publicOk = @($script:LastDns | Where-Object { $_.Server -in @('223.5.5.5', '223.6.6.6') -and $_.Success }).Count
    if ($defaultOk -eq 0 -and $publicOk -gt 0) {
        Say '默认 DNS 查询未成功，但公共 DNS 有成功结果：DNS 路径或配置值得优先排查。可先选 2 清缓存；仍不行再选 4。'
    } elseif ($defaultOk -gt 0) {
        Say '至少一个默认 DNS 查询成功，不能认定为 DNS 故障。请继续看代理与网页测试。'
    } else { Say '默认和公共 DNS 都未成功，先检查 VPN、外网路由和防火墙；不要只凭这一项更换 DNS。' }
    $proxyOn = @($proxy | Where-Object { ($_.Name -eq 'ProxyEnable' -and $_.Value -eq 1) -or ($_.Name -eq 'AutoConfigURL' -and $_.Value) }).Count
    if ($proxyOn) { Say '检测到手动代理或自动代理脚本。若以前开过加速器/代理且现在不用，可选 3 暂时关闭。' }
    $directOk = @($webResults | Where-Object { $_.Direct -and $_.Success }).Count
    $normalOk = @($webResults | Where-Object { -not $_.Direct -and $_.Success }).Count
    if ($directOk -gt $normalOk) { Say '部分直连测试优于系统代理路径，代理值得优先检查；这只是线索。' }
    if ($directOk -gt 0 -or $normalOk -gt 0) {
        Say '本工具至少一次收到 HTTPS 网站响应。这不代表浏览器或语音软件已恢复，请亲自重新打开验证。'
    } else { Say 'HTTPS 测试未成功。可试手机移动热点作对照；若仍失败，再查 VPN、系统时间及本机网络组件。' }
    Say '如 NAS 通过主机名访问，修改 DNS 后请同时确认 NAS 仍能打开；必要时先用 NAS 的 IP 地址。'
    Say 'Ping 未回复不等于断网；公共 DNS 在有些网络会被限制；本工具不会仅凭单个结果判定故障。'
    Say "诊断完成。完整报告：$script:Log"
}
function Flush-Dns {
    Need-Admin
    $r = Run-Local 'ipconfig.exe' '/flushdns'
    Say $r.Text
    if ($r.ExitCode -ne 0) { throw "清缓存命令失败，退出码 $($r.ExitCode)" }
    Say 'DNS 缓存已刷新。这不改变 DNS 地址；请重新打开网页验证。'
}
function Disable-Proxy {
    $snapshot = @(Get-ProxySnapshot)
    Say ($snapshot | Format-Table Name, Exists, Value -AutoSize | Out-String -Width 180)
    if (-not (Confirm-Change '将关闭当前运行用户的手动代理和自动代理 URL。影响依赖该代理的应用；可从菜单 5 恢复。WinHTTP、VPN 和自动发现保持原样。')) { return }
    $null = Save-Backup 'Proxy' $snapshot
    New-ItemProperty -LiteralPath $script:ProxyPath -Name ProxyEnable -Value 0 -PropertyType DWord -Force | Out-Null
    Remove-ItemProperty -LiteralPath $script:ProxyPath -Name AutoConfigURL -ErrorAction SilentlyContinue
    Notify-Proxy
    $after = @(Get-ProxySnapshot)
    Say ($after | Format-Table Name, Exists, Value -AutoSize | Out-String -Width 180)
    if (@($after | Where-Object { ($_.Name -eq 'ProxyEnable' -and $_.Value -ne 0) -or ($_.Name -eq 'AutoConfigURL' -and $_.Exists) }).Count) { throw '代理配置回读未通过，请查看报告和备份。' }
    Say '代理配置已修改并回读；请完全退出并重开浏览器、语音软件，再验证。'
}
function Change-Dns {
    Need-Admin
    $a = Select-Adapter
    Show-Dns $a
    $raw = Get-StaticDns $a
    $data = [pscustomobject]@{ Guid = [string]$a.InterfaceGuid; Alias = $a.Name; StaticRaw = $raw; Servers = @((Get-V4Dns $a).ServerAddresses) }
    if (-not (Confirm-Change "仅把网卡 $($a.Name) 的 IPv4 DNS 改为 223.5.5.5、223.6.6.6。域名查询将发往阿里公共 DNS；局域网名称解析可能受影响。可选 5 恢复。建议仅在默认 DNS 失败、公共 DNS 成功时尝试。")) { return }
    $null = Save-Backup 'Dns' $data
    Get-V4Dns $a | Set-DnsClientServerAddress -ServerAddresses @('223.5.5.5', '223.6.6.6')
    $actual = @((Get-V4Dns $a).ServerAddresses)
    Show-Dns $a
    if (($actual -join ',') -ne '223.5.5.5,223.6.6.6') { throw 'DNS 写入后回读不匹配，请查看备份并重新检测。' }
    $r = Run-Local 'ipconfig.exe' '/flushdns'
    Say $r.Text
    Say 'DNS 配置已写入并回读，尚需检测和浏览器验证。'
}
function Restore-Backup {
    $files = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter '*.json' | Sort-Object Name -Descending)
    if (-not $files.Count) { throw "没有备份：$script:BackupDir" }
    for ($i = 0; $i -lt $files.Count; $i++) { Say ("{0}. {1}" -f ($i + 1), $files[$i].Name) }
    $n = 0
    if (-not [int]::TryParse((Read-Host '选择要恢复的备份编号'), [ref]$n) -or $n -lt 1 -or $n -gt $files.Count) { return }
    $b = Get-Content -LiteralPath $files[$n - 1].FullName -Raw | ConvertFrom-Json
    if ($b.Machine -ne $script:Machine -or $b.Version -ne 1) { throw '备份不属于本机或版本不支持，拒绝恢复。' }
    if ($b.Kind -eq 'Dns') {
        Need-Admin
        $matches = @(Get-NetAdapter | Where-Object { [string]$_.InterfaceGuid -eq $b.Data.Guid })
        if ($matches.Count -ne 1) { throw '找不到备份对应的网卡，拒绝恢复。' }
        $a = $matches[0]
        $servers = @(([string]$b.Data.StaticRaw -split '[,;\s]+') | Where-Object { $_ })
        $expected = if ($servers.Count) { $servers -join ', ' } else { '自动获取 DNS' }
        if (-not (Confirm-Change "恢复网卡 $($a.Name) 到：$expected")) { return }
        $null = Save-Backup 'Dns' ([pscustomobject]@{ Guid = [string]$a.InterfaceGuid; Alias = $a.Name; StaticRaw = (Get-StaticDns $a); Servers = @((Get-V4Dns $a).ServerAddresses) })
        if ($servers.Count) { Get-V4Dns $a | Set-DnsClientServerAddress -ServerAddresses $servers }
        else { Get-V4Dns $a | Set-DnsClientServerAddress -ResetServerAddresses }
        Show-Dns $a
        $restoredRaw = Get-StaticDns $a
        if ($servers.Count) {
            if ((@((Get-V4Dns $a).ServerAddresses) -join ',') -ne ($servers -join ',')) { throw '恢复 DNS 后回读不匹配。' }
        } elseif (-not [string]::IsNullOrWhiteSpace($restoredRaw)) { throw '自动 DNS 恢复后的回读未通过。' }
        Say (Run-Local 'ipconfig.exe' '/flushdns').Text
    } elseif ($b.Kind -eq 'Proxy') {
        if ($b.UserSid -ne $script:UserSid) { throw '代理备份属于其他用户，请使用原用户运行。' }
        Say ($b.Data | Format-Table Name, Exists, Value -AutoSize | Out-String -Width 180)
        if (-not (Confirm-Change '把当前用户的代理恢复为以上备份值？')) { return }
        $null = Save-Backup 'Proxy' @(Get-ProxySnapshot)
        foreach ($v in $b.Data) {
            if ($v.Name -notin $script:ProxyNames) { throw '备份含不支持的代理字段。' }
            if ($v.Exists) { New-ItemProperty -LiteralPath $script:ProxyPath -Name $v.Name -Value $v.Value -PropertyType $v.Kind -Force | Out-Null }
            else { Remove-ItemProperty -LiteralPath $script:ProxyPath -Name $v.Name -ErrorAction SilentlyContinue }
        }
        Notify-Proxy
        $restored = @(Get-ProxySnapshot)
        foreach ($v in $b.Data) {
            $now = $restored | Where-Object { $_.Name -eq $v.Name }
            if ($now.Exists -ne $v.Exists -or ($v.Exists -and ([string]$now.Value -cne [string]$v.Value -or $now.Kind -ne $v.Kind))) { throw "恢复代理后字段 $($v.Name) 回读不匹配。" }
        }
        Say ($restored | Format-Table Name, Exists, Value -AutoSize | Out-String -Width 180)
    } else { throw '未知备份类型。' }
    Say '配置恢复并回读完成，请重新检测和打开应用验证。'
}
function Reset-Winsock {
    Need-Admin
    if (-not (Confirm-Change '高级修复：重置 Winsock，可能影响第三方 VPN / 安全软件的网络组件，无法由本工具一键撤销，之后需要手动重启电脑。仅在前面排查无效后尝试；请先保存工作。')) { return }
    $catalog = Run-Local 'netsh.exe' 'winsock show catalog'
    $path = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-winsock-before.txt')
    $catalog.Text | Set-Content -LiteralPath $path -Encoding UTF8
    Say "已记录原 Winsock 目录（仅诊断记录，不是可恢复备份）：$path"
    $r = Run-Local 'netsh.exe' 'winsock reset' 25
    Say $r.Text
    if ($r.ExitCode -ne 0) { throw "重置命令失败，退出码 $($r.ExitCode)" }
    Say '重置命令成功返回，修复尚未验证。请手动重启电脑，重连 WiFi 后再次运行检测。'
}
function Proxy-Fingerprint($Values) { return ($Values | ConvertTo-Json -Depth 5 -Compress) }
function Proxy-Value($Values, [string]$Name) {
    return ($Values | Where-Object { $_.Name -eq $Name } | Select-Object -First 1).Value
}
function Get-LoopbackProxy([string]$Text) {
    # Only a single, unambiguous local endpoint; protocol maps/PAC/remote proxies are manual-only.
    if (-not $Text -or $Text -match '[;=\s]') { return $null }
    $url = $Text
    if ($url -notmatch '^https?://') { $url = 'http://' + $url }
    $uri = $null
    if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Host -notin @('127.0.0.1', 'localhost', '[::1]', '::1') -or $uri.Port -lt 1 -or $uri.Port -gt 65535 -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { return $null }
    return [pscustomobject]@{ Address = $uri.DnsSafeHost; Port = $uri.Port }
}
function Get-ProxyProtection {
    # Do not fight policy or a running proxy client/guard, even if it is starting or unhealthy.
    foreach ($path in @(
        'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings',
        'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings',
        'HKCU:\Software\Policies\Microsoft\Internet Explorer\Control Panel',
        'HKLM:\Software\Policies\Microsoft\Internet Explorer\Control Panel'
    )) {
        if (Test-Path -LiteralPath $path) { return '检测到代理相关策略，自动模式不修改。' }
    }
    $clients = @(Get-Process | Where-Object { $_.ProcessName -match '(?i)clash|mihomo|verge|sing-box|v2ray|xray|v2rayn|nekoray' })
    if ($clients.Count) { return ('代理/VPN 进程仍在运行：' + (($clients | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') + '。请先在该软件内关闭系统代理并正常退出，再运行自动修复。') }
    return ''
}
function Get-RepairState {
    $proxy = @(Get-ProxySnapshot)
    $web = @()
    foreach ($url in @('https://www.baidu.com/', 'https://www.qq.com/')) {
        foreach ($direct in @($true, $false)) { $web += Web-Probe $url $direct }
    }
    $endpoint = Get-LoopbackProxy ([string](Proxy-Value $proxy 'ProxyServer'))
    $closed = $false
    if ($null -ne $endpoint) {
        $closed = -not (Tcp-Probe $endpoint.Address $endpoint.Port)
        if ($closed) { $closed = -not (Tcp-Probe $endpoint.Address $endpoint.Port) }
    }
    $dns = @()
    $normalCount = @($web | Where-Object { -not $_.Direct -and $_.Healthy }).Count
    if ($normalCount -eq 0) { $dns = @(Dns-Probes) }
    $facts = Get-NetworkFacts $web ($normalCount -eq 0)
    return [pscustomobject]@{
        Time = (Get-Date -Format o); Proxy = $proxy; Fingerprint = (Proxy-Fingerprint $proxy)
        Manual = ((Proxy-Value $proxy 'ProxyEnable') -eq 1)
        Pac = [bool](Proxy-Value $proxy 'AutoConfigURL')
        Endpoint = $endpoint; LocalPortClosed = $closed; Protection = (Get-ProxyProtection)
        NormalOK = $normalCount; DirectOK = @($web | Where-Object { $_.Direct -and $_.Healthy }).Count
        Web = $web; Dns = $dns; Facts = $facts
    }
}
function Get-NetworkFacts($Web, [bool]$Deep) {
    $adapters = @(Get-NetAdapter | Select-Object ifIndex, Name, Status, HardwareInterface, InterfaceDescription, NdisPhysicalMedium)
    $up = @($adapters | Where-Object { $_.Status -eq 'Up' })
    $services = @(Get-Service -Name WlanSvc, Dhcp, Dnscache -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
    $configs = @(Get-NetIPConfiguration | ForEach-Object {
        [pscustomobject]@{ Index = $_.InterfaceIndex; Alias = $_.InterfaceAlias; IPv4 = @($_.IPv4Address | Select-Object -ExpandProperty IPAddress); Gateway = @($_.IPv4DefaultGateway | Select-Object -ExpandProperty NextHop); IPv6 = @($_.IPv6Address | Select-Object -ExpandProperty IPAddress); IPv6Gateway = @($_.IPv6DefaultGateway | Select-Object -ExpandProperty NextHop) }
    })
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object InterfaceIndex, IPAddress, AddressState, PrefixOrigin)
    $routes = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1', '::/0') } | Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric)
    $single = $null
    if ($up.Count -eq 1 -and $up[0].HardwareInterface) { $single = $up[0] }
    $dhcpBad = $false
    if ($null -ne $single) {
        $c = $configs | Where-Object { $_.Index -eq $single.ifIndex }
        $ipif = Get-NetIPInterface -InterfaceIndex $single.ifIndex -AddressFamily IPv4
        $valid = @($c.IPv4 | Where-Object { $_ -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
        $duplicate = @($addresses | Where-Object { $_.InterfaceIndex -eq $single.ifIndex -and [string]$_.AddressState -eq 'Duplicate' }).Count -gt 0
        $dhcpBad = ([string]$ipif.Dhcp -eq 'Enabled' -and (-not $valid.Count -or -not $c.Gateway.Count -or $duplicate))
    }
    $wireless = @($adapters | Where-Object { $_.HardwareInterface -and ([string]$_.NdisPhysicalMedium -match '802_11|WirelessLan' -or $_.InterfaceDescription -match '(?i)wi-fi|wireless|802\.11|wlan') }).Count -gt 0
    $domain = $null
    try { $domain = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain } catch { }
    $portal = $null; $clockHint = $false; $winhttp = ''; $environment = @(); $hosts = @(); $gatewayPing = @(); $internet = @()
    if ($Deep) {
        $portal = Web-Probe 'http://www.msftconnecttest.com/connecttest.txt' $true
        # HTTP dates are only hints. Never set the clock from these headers.
        if (@($Web | Where-Object { $_.ErrorKind -in @('TrustFailure', 'SecureChannelFailure') }).Count -gt 0 -and $portal.Date) {
            $other = Web-Probe 'http://www.qq.com/' $true
            try {
                $d1 = [DateTimeOffset]::Parse($portal.Date, [Globalization.CultureInfo]::InvariantCulture); $d2 = [DateTimeOffset]::Parse($other.Date, [Globalization.CultureInfo]::InvariantCulture)
                $clockHint = ([Math]::Abs(($d1 - $d2).TotalSeconds) -lt 120 -and [Math]::Abs(($d1 - [DateTimeOffset]::Now).TotalSeconds) -gt 600)
            } catch { }
        }
        try { $winhttp = (Run-Local 'netsh.exe' 'winhttp dump').Text } catch { $winhttp = $_.Exception.Message }
        foreach ($n in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            if ([Environment]::GetEnvironmentVariable($n)) { $environment += $n }
        }
        try {
            $hosts = @(Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') | Where-Object { $_ -match '^\s*[^#\s]' })
        } catch { }
        foreach ($g in @($configs | ForEach-Object { $_.Gateway } | Select-Object -Unique)) {
            $ping = New-Object Net.NetworkInformation.Ping
            try { $gatewayPing += [pscustomobject]@{ Address = $g; Result = [string]$ping.Send($g, 1500).Status } }
            catch { $gatewayPing += [pscustomobject]@{ Address = $g; Result = 'Unknown' } }
            finally { $ping.Dispose() }
        }
        $internet = @((Tcp-Probe '223.5.5.5' 443), (Tcp-Probe '1.1.1.1' 443))
    }
    return [pscustomobject]@{
        Adapters = $adapters; UpCount = $up.Count; Services = $services; Configs = $configs; Addresses = $addresses; Routes = $routes
        Single = $single; DhcpBad = $dhcpBad; HasWireless = $wireless; Domain = $domain
        Portal = $portal; ClockHint = $clockHint; WinHttp = $winhttp; EnvironmentProxy = $environment
        Hosts = $hosts; GatewayPing = $gatewayPing; InternetTcp = $internet
        TlsErrors = @($Web | Where-Object { $_.ErrorKind -in @('TrustFailure', 'SecureChannelFailure') }).Count
    }
}
function Get-InfrastructurePlan($State) {
    $f = $State.Facts
    if ($null -eq $f -or $State.NormalOK -gt 0) { return $null }
    if (-not @($f.Adapters).Count) { return [pscustomobject]@{ Action = 'UserAction'; Target = ''; Reason = '系统未发现网卡。打开设备管理器检查网络适配器；可能需要用另一台电脑下载对应型号驱动，再通过 NAS/U 盘安装。' } }
    foreach ($name in @('WlanSvc', 'Dhcp', 'Dnscache')) {
        if ($name -eq 'WlanSvc' -and -not $f.HasWireless) { continue }
        $s = $f.Services | Where-Object { $_.Name -eq $name }
        if ([string]$s.Status -eq 'Stopped' -and [string]$s.StartType -eq 'Automatic' -and $f.Domain -eq $false -and -not $State.Protection) {
            return [pscustomobject]@{ Action = 'Service'; Target = $name; Reason = "网络服务 $name 已停止，但启动类型为自动，将尝试启动该服务。" }
        }
    }
    if ($f.UpCount -eq 0) { return [pscustomobject]@{ Action = 'UserAction'; Target = ''; Reason = '没有已连接的网卡。请打开 WiFi、关闭飞行模式并选择家庭 WiFi；若网卡被禁用，请在网络设置中启用。工具不会猜测要连接的网络或输入密码。' } }
    if ($f.DhcpBad -and $f.Domain -eq $false -and -not $State.Protection) { return [pscustomobject]@{ Action = 'Dhcp'; Target = [string]$f.Single.ifIndex; Reason = '唯一真实网卡使用 DHCP，但没有有效 IPv4 地址或网关。将仅为这张网卡重新申请地址，不先释放现有地址。' } }
    if ($null -ne $f.Portal -and $f.Portal.Success -and ($f.Portal.Code -ge 300 -or $f.Portal.Content.Trim() -ne 'Microsoft Connect Test')) {
        return [pscustomobject]@{ Action = 'UserAction'; Target = ''; Reason = 'HTTP 测试被重定向或内容发生变化，疑似需要网络登录认证或网页被拦截。请在浏览器打开 http://www.msftconnecttest.com/connecttest.txt，查看是否有登录页面。' }
    }
    if ($f.ClockHint -and -not $State.Protection -and $f.Domain -eq $false) { return [pscustomobject]@{ Action = 'Time'; Target = 'W32Time'; Reason = 'HTTPS 存在证书/安全通道错误，且两个服务器时间提示本机时钟偏差较大。将请求 Windows 使用原有时间源同步；不会采用网页时间直接改钟。' } }
    return $null
}
function Get-UnresolvedAdvice($State) {
    $f = $State.Facts
    $tips = @()
    if ($null -ne $f) {
        if ($State.Protection) { $tips += $State.Protection }
        if ($f.DhcpBad) { $tips += 'IP/DHCP 仍异常：重新连接 WiFi；若其他设备正常，检查路由器是否限制了这台电脑。' }
        if (@($f.Addresses | Where-Object { [string]$_.AddressState -eq 'Duplicate' }).Count) { $tips += 'Windows 报告 IPv4 地址冲突：DHCP 网卡可尝试重新申请地址；手动 IP 需要核对路由器地址分配，自动模式不擅自改静态 IP。' }
        if (@($f.Routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/1', '128.0.0.0/1') }).Count) { $tips += '存在拆分默认路由，可能由 VPN 建立；请在 VPN 软件里断开连接后复测，工具不会删除路由。' }
        if ($f.TlsErrors) { $tips += 'HTTPS 存在证书/安全通道错误：核对系统日期时间，检查 Windows 更新和安全软件的 HTTPS 过滤。工具不会关闭证书验证。' }
        if ($f.EnvironmentProxy.Count) { $tips += ('检测到环境变量代理：' + ($f.EnvironmentProxy -join ', ') + '，部分软件可能单独使用它们；自动模式保留。') }
        if ($f.WinHttp -match '(?im)^\s*set\s+proxy\s+') { $tips += '检测到 WinHTTP 代理配置，可能影响更新器或后台软件；它是系统级设置，自动模式保留。' }
        if (@($f.Hosts | Where-Object { $_ -match '(?i)baidu\.com|qq\.com|microsoft\.com' }).Count) { $tips += 'hosts 中有测试网站相关条目；可能是自定义映射，自动模式保留，完整诊断可查看。' }
        if ($f.InternetTcp.Count -gt 0 -and @($f.InternetTcp | Where-Object { $_ }).Count -eq 0) { $tips += '两个公网 IP 的 TCP 测试均未成功，但这不能单独证明断网。请用手机移动热点对照：热点正常则重点查家庭路由器/宽带；热点也失败则重点查本机 VPN、过滤软件和驱动。' }
        foreach ($s in $f.Services) { if ([string]$s.Status -eq 'Stopped' -and [string]$s.StartType -ne 'Automatic') { $tips += "服务 $($s.Name) 已停止、启动类型为 $($s.StartType)，可能是有意设置；自动模式未改。" } }
    }
    if (-not $tips.Count) { $tips += '请连接手机移动数据热点作对照，并检查路由器设备限制、VPN 状态。更详细的驱动、hosts 和路由信息可用 START.cmd 查看。' }
    return ($tips -join "`r`n")
}
function Get-AutoPlan($State) {
    $action = 'Unresolved'; $reason = '证据不足，未修改配置。可连接手机移动热点对照，或用 START.cmd 查看完整诊断。'
    if ($State.NormalOK -eq 2) { $action = 'Healthy'; $reason = '两个网站的系统网络路径均通过 HTTPS 测试，保留现有配置。' }
    elseif ($State.NormalOK -gt 0) { $action = 'Partial'; $reason = '部分网站可达，可能是单个网站或路径异常，保留配置。' }
    elseif ($State.Protection) { $reason = $State.Protection }
    elseif ($State.Manual -and -not $State.Pac -and $null -ne $State.Endpoint -and $State.LocalPortClosed -and $State.DirectOK -eq 2) {
        $action = 'Proxy'; $reason = '两个网站均可直连、系统路径均失败；本地手动代理端口连续两次不可达，符合代理残留特征。'
    } elseif (-not $State.Manual -and -not $State.Pac -and $State.DirectOK -eq 0) {
        $default = @($State.Dns | Where-Object { -not $_.Server })
        $good = @(Get-GoodPublicDns $State.Dns)
        if ($default.Count -eq 2 -and @($default | Where-Object { $_.Success }).Count -eq 0 -and $good.Count -gt 0) {
            $action = 'Dns'; $reason = '默认 DNS 两个域名均未成功，同一公共 DNS 对两个域名均成功，可继续检查是否适合自动调整。'
        }
    }
    if ($State.Pac -and $action -eq 'Unresolved') { $reason = '存在自动代理脚本，可能有特定用途。自动模式保留它；可用菜单 3 在备份后手动关闭。' }
    elseif ($State.Manual -and $action -eq 'Unresolved' -and -not $State.Protection) { $reason = '代理仍在监听、不是单一本地代理，或直连证据不足；保留代理。请在 Clash 内检查连接，或先正常退出后重试。' }
    if ($action -eq 'Unresolved') { $reason += "`r`n" + (Get-UnresolvedAdvice $State) }
    return [pscustomobject]@{ Action = $action; Reason = $reason }
}
function Get-GoodPublicDns($Results) {
    foreach ($server in @('223.5.5.5', '223.6.6.6')) {
        $goodNames = @($Results | Where-Object { $_.Server -eq $server -and $_.Success } | Select-Object -ExpandProperty Name -Unique)
        if ('www.baidu.com' -in $goodNames -and 'www.qq.com' -in $goodNames) { $server }
    }
}
function Get-AutoDnsAdapter {
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { throw '电脑已加入组织域，自动模式保留 DNS。' }
    $up = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -ne 1 -or -not $up[0].HardwareInterface) { throw '存在多个已连接网卡、虚拟网卡，或无单一真实网卡，自动模式不选择 DNS 网卡。' }
    $a = $up[0]
    $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4
    if ([string]$ipif.Dhcp -ne 'Enabled') { throw '该网卡使用手动 IP，自动模式保留 DNS。' }
    $config = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex
    $valid = @($config.IPv4Address | Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '0.0.0.0' })
    if (-not $valid.Count -or -not $config.IPv4DefaultGateway) { throw '网卡缺少有效 IPv4 地址或网关，请检查 WiFi、DHCP 和路由器。' }
    $defaults = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore)
    if ($defaults.Count -ne 1 -or $defaults[0].InterfaceIndex -ne $a.ifIndex) { throw '默认路由不唯一或不属于所选网卡，自动模式保留 DNS。' }
    if (-not [string]::IsNullOrWhiteSpace((Get-StaticDns $a))) { throw '该网卡已有手动 DNS，自动模式保留它。可在菜单 4 中自行决定。' }
    return $a
}
function Get-DnsData($Adapter) {
    return [pscustomobject]@{ Guid = [string]$Adapter.InterfaceGuid; Alias = $Adapter.Name; StaticRaw = (Get-StaticDns $Adapter); Servers = @((Get-V4Dns $Adapter).ServerAddresses) }
}
function Restore-ProxyValues($Values) {
    foreach ($v in $Values) {
        if ($v.Name -notin $script:ProxyNames) { throw '备份字段不支持，停止恢复。' }
        if ($v.Exists) { New-ItemProperty -LiteralPath $script:ProxyPath -Name $v.Name -Value $v.Value -PropertyType $v.Kind -Force | Out-Null }
        else { Remove-ItemProperty -LiteralPath $script:ProxyPath -Name $v.Name -ErrorAction SilentlyContinue }
    }
    Notify-Proxy
    if ((Proxy-Fingerprint @(Get-ProxySnapshot)) -cne (Proxy-Fingerprint $Values)) { throw '代理恢复回读未通过，请查看备份。' }
}
function Get-RepairPreview($State) {
    # Read-only planning. No repair, cache flush, service start, or backup creation here.
    $plan = Get-InfrastructurePlan $State
    if ($null -eq $plan) { $plan = Get-AutoPlan $State }
    $action = $plan.Action; $reason = $plan.Reason; $target = [string]$plan.Target
    $steps = @(); $impact = '本次只做网络测试并保存本地报告。'; $admin = $false
    $canRepair = $action -in @('Proxy', 'Dns', 'Service', 'Dhcp', 'Time')
    $details = $null
    try {
        switch ($action) {
            'Proxy' {
                $target = [string](Proxy-Value $State.Proxy 'ProxyServer')
                $steps = @('重新检测并核对原代理配置及本地监听状态。', '保存原代理备份，只关闭当前用户的手动代理开关。', '回读配置，复测两个 HTTPS 网站；无效时在配置仍属于本工具的前提下恢复原代理。')
                $impact = '依赖该代理的应用会改走直连。保留代理地址和绕过列表，备份可从菜单 5 恢复。'
            }
            'Dns' {
                $admin = $true
                $a = Get-AutoDnsAdapter
                $servers = @(Get-GoodPublicDns $State.Dns)
                $details = [ordered]@{ Before = (Get-DnsData $a); Servers = $servers }
                $target = "$($a.Name) / IPv4 DNS → $($servers -join ', ')"
                $steps = @('重新检测，确认网卡、原 DNS 和拟用服务器均与本方案一致。', '清除 DNS 缓存并复测；若已恢复则不更换 DNS。', '只有故障与方案仍一致时，备份后试用上面列出的公共 DNS，回读并复测；无效则在未被其他程序改动时恢复自动 DNS。')
                $impact = '清缓存会移除临时 DNS 记录；若更换 DNS，域名查询会发往列出的阿里公共 DNS，局域网主机名解析可能受影响。'
            }
            'Service' {
                $admin = $true
                $details = @($State.Facts.Services | Where-Object { $_.Name -eq $target })
                $steps = @("重新核对服务 $target 仍是自动启动且已停止。", '启动这一项服务，不改变启动类型；回读运行状态并复测。')
                $impact = '该网络服务会开始运行。若复测后仍有其他问题，将停止并要求重新预览，不自动处理下一类故障。'
            }
            'Dhcp' {
                $admin = $true
                $a = @(Get-NetAdapter | Where-Object { [string]$_.ifIndex -eq $target })
                if ($a.Count -ne 1) { throw '无法唯一确定拟续租网卡。' }
                $details = [ordered]@{ Guid = [string]$a[0].InterfaceGuid; Index = $a[0].ifIndex; Name = $a[0].Name }
                $target = "$($a[0].Name) / 索引 $($a[0].ifIndex)"
                $steps = @('重新核对同一张真实网卡仍使用 DHCP，且地址或网关异常。', '只为这一张网卡重新申请 DHCP 地址，不先释放现有地址；随后复测。')
                $impact = '可能短暂影响 NAS/局域网连接，IP、网关和 DHCP 提供的 DNS 可能改变。续租结果不能用菜单 5 撤销；其他故障需要另行预览确认。'
            }
            'Time' {
                $admin = $true
                $cfg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                $svc = Get-Service W32Time
                if ([string]$cfg.Type -notin @('NTP', 'AllSync') -or [string]$svc.StartType -eq 'Disabled') { throw '原时间源或服务设置不适合自动同步，请在系统日期和时间中手动核对。' }
                $details = [ordered]@{ Type = [string]$cfg.Type; Source = [string]$cfg.NtpServer; StartType = [string]$svc.StartType; Status = [string]$svc.Status }
                $target = 'Windows 时间服务 / 保留原时间源'
                $steps = @('重新核对 HTTPS、时钟异常线索及原时间源。', '必要时启动 Windows 时间服务，再向原时间源请求同步；复测 HTTPS。')
                $impact = '可能调整系统时钟或启动 Windows 时间服务；不会直接照网页时间改钟，也不更换时间源。此操作不能用菜单 5 撤销。'
            }
            default { $steps = @('保留配置，按检测结果中的建议继续操作。') }
        }
    } catch {
        $canRepair = $false
        $reason += "`r`n预检未通过：$($_.Exception.Message)"
        $steps = @('暂不执行系统修复；请按上面的具体原因处理。')
        $impact = '未准备可执行的修复方案，保持网络配置。'
    }
    $keyData = [ordered]@{
        Version = '2.2'; Machine = $script:Machine; User = $script:UserSid
        Action = $action; Target = $target; CanRepair = $canRepair; Proxy = $State.Fingerprint
        NormalOK = $State.NormalOK; DirectOK = $State.DirectOK; PortClosed = $State.LocalPortClosed
        Protection = $State.Protection; Domain = $State.Facts.Domain; Details = $details
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($keyData | ConvertTo-Json -Depth 8 -Compress))))).Replace('-', '') } finally { $sha.Dispose() }
    if (-not $target) { $target = '无待执行的系统修复对象' }
    return [pscustomobject]@{ Action = $action; CanRepair = $canRepair; Reason = $reason; Target = $target; Steps = $steps; Impact = $impact; NeedsAdmin = $admin; ApprovalKey = $key }
}
function Test-PreviewApproval($State, $Approved) {
    if ($null -eq $Approved -or -not $Approved.CanRepair) { return $false }
    $now = Get-RepairPreview $State
    return ($now.CanRepair -and $now.ApprovalKey -ceq $Approved.ApprovalKey)
}
function Open-ResultReport($Result) {
    if ($Result.HtmlReport) { try { Start-Process $Result.HtmlReport } catch { Say "HTML 结果页：$($Result.HtmlReport)" } }
}
function Invoke-RepairPreview {
    param([switch]$Only)
    $script:AutoActions = @()
    Section '只读检测与修复方案预览 v2.2'
    Say '此阶段不会修改代理、DNS、IP、服务或系统时间，也不会清除 DNS 缓存。仅发送测试请求并保存本地报告。'
    $state = $null; $confirmed = $false
    try {
        $state = Get-RepairState
        $preview = Get-RepairPreview $state
        Say ("检测判断：{0}`r`n{1}" -f $preview.Action, $preview.Reason)
        Say ("拟处理对象：{0}" -f $preview.Target)
        Say '准备执行（尚未执行）：'
        foreach ($step in $preview.Steps) { Say ('- ' + $step) }
        Say ('影响与恢复方式：' + $preview.Impact)
        if ($preview.NeedsAdmin -and $preview.CanRepair) { Say '执行此方案需要管理员权限；重新以管理员运行后仍须重新检测、预览和确认。' }
        $result = Finish-AutoRepair 'Preview' ('只读检测完成，尚未执行任何网络修复。' + "`r`n" + $preview.Reason) $state $null '' $preview
        if ($Only -or -not $preview.CanRepair) { return $result }
        Open-ResultReport $result
        Say '确认仅适用于上面这一份方案；复测发现其他问题时不会自动扩大修复范围。'
        $answer = Read-Host '如确认执行请输入 APPLY；直接回车或其他输入退出，不修改网络配置'
        if ($answer -cne 'APPLY') { return Finish-AutoRepair 'Cancelled' '未收到明确确认，未执行网络修复。' $state $null '' $preview }
        $confirmed = $true
        $approvalFile = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-approved-plan.json')
        [pscustomobject]@{ Time = (Get-Date -Format o); Plan = $preview; UserSid = $script:UserSid } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $approvalFile -Encoding UTF8
        Say '已确认。现在重新检测；方案或目标变化则停止，请重新预览确认。'
        return Auto-Repair -RequireApproval -ApprovedPreview $preview
    } catch {
        if ($confirmed) { return Finish-AutoRepair 'Stopped' ("确认后的流程中断：$($_.Exception.Message)。请查看操作记录核对执行情况，不会自动重试。") $state $null }
        return Finish-AutoRepair 'Stopped' ("预览未完成：$($_.Exception.Message)。未执行网络修复。") $state $null
    }
}
function Write-ResultHtml($Receipt, [string]$Path) {
    $labels = @{ Preview = '只读检测 · 尚未执行修复'; Cancelled = '已取消 · 未执行修复'; Healthy = '检测正常'; Repaired = '修复后测试通过'; Partial = '部分网络可用'; Unresolved = '需要继续处理'; NeedsAdmin = '需要管理员权限'; UserAction = '需要你完成一步操作'; Changed = '状态已变化，已停止修改'; RolledBack = '尝试无效，已恢复原配置'; Stopped = '已停止，请查看原因' }
    $label = $labels[$Receipt.Status]
    if (-not $label) { $label = $Receipt.Status }
    $title = [Net.WebUtility]::HtmlEncode($label)
    $reason = [Net.WebUtility]::HtmlEncode($Receipt.Reason)
    $log = [Net.WebUtility]::HtmlEncode($script:Log)
    $backupText = [Net.WebUtility]::HtmlEncode($Receipt.Backup)
    $kind = if ($Receipt.Status -in @('Healthy', 'Repaired')) { 'good' } else { 'attention' }
    $rows = ''
    foreach ($stage in @(@{ Label = '检测前'; Value = $Receipt.Before }, @{ Label = '处理后'; Value = $Receipt.After })) {
        foreach ($w in $stage.Value.Web) {
            $pathLabel = if ($w.Direct) { '强制直连' } else { '系统网络路径' }
            $resultLabel = if ($w.Healthy) { '通过' } else { '未通过' }
            $rows += '<tr><td>' + $stage.Label + '</td><td>' + [Net.WebUtility]::HtmlEncode($w.Url) + '</td><td>' + $pathLabel + '</td><td>' + $resultLabel + '</td></tr>'
        }
    }
    $operations = ''
    foreach ($a in $Receipt.Actions) { $operations += '<li>' + [Net.WebUtility]::HtmlEncode($a) + '</li>' }
    if (-not $operations) { $operations = '<li>没有执行网络修复；仅检测并保存报告。</li>' }
    $previewPanel = ''
    if ($null -ne $Receipt.PreparedPlan) {
        $p = $Receipt.PreparedPlan
        $preparedSteps = ''; foreach ($step in $p.Steps) { $preparedSteps += '<li>' + [Net.WebUtility]::HtmlEncode($step) + '</li>' }
        $targetText = [Net.WebUtility]::HtmlEncode($p.Target)
        $impactText = [Net.WebUtility]::HtmlEncode($p.Impact)
        $previewPanel = '<section class="card"><h2>拟执行方案（尚未执行）</h2><p>对象：<code>' + $targetText + '</code></p><ol>' + $preparedSteps + '</ol><p><strong>影响与恢复：</strong>' + $impactText + '</p><p class="muted">CHECK-ONLY.cmd 永不执行修复。PREVIEW.cmd 可回到检测窗口输入 APPLY 确认；浏览器页面本身不能批准或执行修复。方案变化需要重新预览。</p></section>'
    }
    $json = [Net.WebUtility]::HtmlEncode(($Receipt | ConvertTo-Json -Depth 12))
    $html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>网络诊断结果</title><style>
:root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#f4f2ed;color:#252d2c;font:16px/1.7 system-ui,"Microsoft YaHei",sans-serif}main{max-width:1020px;margin:auto;padding:44px 24px 64px}.eyebrow{font-size:13px;letter-spacing:.12em;color:#56736b}h1{font-size:32px;line-height:1.25;margin:12px 0 24px}h2{font-size:20px;margin:0 0 12px}.card{background:#fff;border:1px solid #dddcd4;border-radius:12px;padding:24px;margin:18px 0}.status{border-left:6px solid #bd7f27}.good{border-left-color:#36745c}.pill{display:inline-block;padding:3px 11px;background:#eef3ef;color:#37614d;border-radius:20px;font-size:13px}.reason{white-space:pre-wrap;font-size:18px}p{margin:10px 0}.muted{color:#66716b;font-size:14px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.grid .card{margin:0}table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:12px 8px;border-bottom:1px solid #e7e7df}code,pre{overflow-wrap:anywhere;font-size:13px;background:#f2f4f1;padding:4px 6px;border-radius:4px}pre{white-space:pre-wrap;padding:16px;max-height:500px;overflow:auto}.scroll{overflow:auto}a{color:#2c6c59}summary{cursor:pointer}li{margin:8px 0}@media(max-width:650px){main{padding:24px 14px}.grid{grid-template-columns:1fr}h1{font-size:27px}.card{padding:18px}}
</style></head><body><main><div class="eyebrow">WINDOWS NETWORK RESCUE · V2.2 · 本地离线报告</div><h1>网络诊断与修复结果</h1><section class="card status $kind"><span class="pill">$title</span><p class="reason">$reason</p><p class="muted">请重新打开浏览器和语音软件验证。测试通过不代表每个网站、每款软件都已恢复。</p></section>$previewPanel<div class="grid"><section class="card"><h2>本次处理</h2><ul>$operations</ul><p class="muted">自动修复按证据执行。驱动、路由器和认证账号等问题可能仍需要你操作。</p></section><section class="card"><h2>以后再遇到断网</h2><p>先运行 <strong>CHECK-ONLY.cmd</strong> 只读检测；需要确认后修复时运行 <strong>PREVIEW.cmd</strong>。若提示管理员权限，以管理员身份重开 PREVIEW.cmd 并重新确认。</p><p>如需恢复 DNS 或代理，打开 <strong>START.cmd → 菜单 5</strong>。</p><p class="muted">此 HTML 页面只展示结果，不会直接修改系统。工具不会后台常驻。</p></section></div><section class="card"><h2>网页对照测试</h2><div class="scroll"><table><thead><tr><th>阶段</th><th>目标</th><th>路径</th><th>结果</th></tr></thead><tbody>$rows</tbody></table></div></section><section class="card"><h2>本地记录与清理</h2><p>新版默认保留最近 3 次检测记录。用完后关闭检测窗口，双击 <strong>CLEAN-REPORTS.cmd</strong>，查看清理范围并输入 CLEAN，可把剩余报告移入回收站。恢复备份会保留，清理过程不会再生成报告。</p><p>完整报告：<code>$log</code></p><p>本次配置备份：<code>$backupText</code></p><p class="muted">报告和备份不会上传。记录可能包含局域网地址、WiFi 名称或代理配置，分享前请核对。</p><details><summary>查看诊断数据</summary><pre>$json</pre></details></section><p class="muted">需要连接 WiFi 时可打开 Windows 网络设置；疑似认证网络请访问 <a href="http://www.msftconnecttest.com/connecttest.txt">HTTP 测试页面</a>。此报告不依赖 CDN、外部脚本或在线字体。</p></main></body></html>
"@
    $html | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Finish-AutoRepair([string]$Status, [string]$Reason, $Before, $After, [string]$Backup = '', $Preview = $null) {
    if ($null -ne $Preview) { Section '只读检测与方案预览结果' } else { Section '自动检测与修复结果' }
    Say "状态：$Status"
    Say $Reason
    if ($null -ne $Preview) { Say '以上方案尚未执行；HTML 页面只展示结果，确认操作在命令窗口进行。' }
    else { Say '测试仅代表这两个网站的 Windows 网络路径；请重新打开浏览器和语音软件确认。' }
    $base = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-auto-result')
    $receipt = [pscustomobject]@{ Version = '2.2'; Status = $Status; Reason = $Reason; Backup = $Backup; Before = $Before; After = $After; Actions = @($script:AutoActions); PreparedPlan = $Preview; HtmlReport = ($base + '.html') }
    $file = $base + '.json'
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $file -Encoding UTF8
    try { Write-ResultHtml $receipt $receipt.HtmlReport } catch { Say "HTML 报告未生成：$($_.Exception.Message)"; $receipt.HtmlReport = '' }
    Say "结果与过程已保存：$script:Log"
    return $receipt
}
function Auto-Repair {
    param([int]$Depth = 0, [switch]$RequireApproval, $ApprovedPreview = $null)
    if ($Depth -eq 0) { $script:AutoActions = @(); $script:AutoAttempts = @() }
    Section '自动检测与修复 v2.2'
    Say '将检查网卡、网络服务、DHCP/IP、路由线索、DNS、代理/VPN、认证、时钟与 HTTPS。按证据启动原本设为自动的网络服务、重新申请 DHCP 地址、请求原时间源同步、处理 DNS 和残留代理。'
    Say 'DNS/代理修改前备份，复测无效则尝试恢复。重新申请 DHCP 可能短暂改变局域网连接；时间同步可能调整系统时钟。'
    Say '不会后台常驻、自动终止 Clash、重置 Winsock、重置 IP、关闭防火墙或自动重启。'
    $before = $null; $after = $null; $backup = ''; $pending = ''; $ours = ''; $restoreData = $null
    try {
        $before = Get-RepairState
        if ($RequireApproval -and -not (Test-PreviewApproval $before $ApprovedPreview)) { return Finish-AutoRepair 'Changed' '重新检测后方案、目标或配置与已确认预览不一致。未执行修复，请重新运行 PREVIEW.cmd 预览确认。' $before $null }
        $infra = Get-InfrastructurePlan $before
        if ($null -ne $infra) {
            Say $infra.Reason
            if ($infra.Action -eq 'UserAction') { return Finish-AutoRepair 'UserAction' $infra.Reason $before $before }
            $attempt = $infra.Action + ':' + $infra.Target
            if ($Depth -ge 3 -or $attempt -in $script:AutoAttempts) { return Finish-AutoRepair 'Unresolved' ('已完成有限次数的针对性处理，避免重复断开网络。' + "`r`n" + (Get-UnresolvedAdvice $before)) $before $before }
            try { Need-Admin } catch { return Finish-AutoRepair 'NeedsAdmin' ($infra.Reason + ' 请右键原启动入口（确认模式用 PREVIEW.cmd），以管理员身份运行后重新检测、预览并确认。本次未执行此修复。') $before $before }
            $fresh = Get-RepairState
            $again = Get-InfrastructurePlan $fresh
            if ($RequireApproval -and -not (Test-PreviewApproval $fresh $ApprovedPreview)) { return Finish-AutoRepair 'Changed' '执行前复测的方案已变化，未执行修复，请重新预览确认。' $before $fresh }
            if ($null -eq $again -or $again.Action -ne $infra.Action -or $again.Target -ne $infra.Target -or $fresh.Fingerprint -cne $before.Fingerprint) { return Finish-AutoRepair 'Changed' '复测后判断已变化，未执行网络基础修复，请重新运行。' $before $fresh }
            if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain -or (Get-ProxyProtection)) { throw '写入前发现组织域或运行中的代理/VPN，停止自动调整。' }
            $script:AutoAttempts += $attempt
            $record = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-infrastructure-before.json')
            $fresh.Facts | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $record -Encoding UTF8
            switch ($infra.Action) {
                'Service' {
                    $service = Get-Service -Name $infra.Target
                    if ([string]$service.Status -ne 'Stopped' -or [string]$service.StartType -ne 'Automatic') { throw '服务状态或启动类型已变化，未启动。' }
                    Start-Service -Name $infra.Target
                    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(8))
                    $service.Refresh()
                    if ([string]$service.Status -ne 'Running') { throw '服务启动后的回读未通过。' }
                    $script:AutoActions += "已启动原本设为自动的网络服务 $($infra.Target)，并回读为 Running。"
                }
                'Dhcp' {
                    $up = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
                    if ($up.Count -ne 1 -or -not $up[0].HardwareInterface -or [string]$up[0].ifIndex -ne $infra.Target) { throw '网卡状态已变化，未重新申请地址。' }
                    $a = $up[0]
                    if ([string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4).Dhcp -ne 'Enabled') { throw '网卡已改为手动 IP，停止自动处理。' }
                    if ($a.Name -match '["\\\r\n*?]') { throw '网卡名称含特殊字符，请在 Windows 网络设置里重新连接。' }
                    $r = Run-Local 'ipconfig.exe' ('/renew "{0}"' -f $a.Name) 40
                    Say $r.Text
                    if ($r.ExitCode -ne 0) { throw 'DHCP 续租未成功。请重新连接 WiFi，检查路由器的 DHCP/设备限制；不会反复释放地址。' }
                    $script:AutoActions += "已为 $($a.Name) 请求 DHCP 续租；后续状态需要复测，命令返回不代表已经上网。"
                }
                'Time' {
                    $timeConfig = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                    if ([string]$timeConfig.Type -notin @('NTP', 'AllSync')) { throw 'Windows 未配置普通 NTP 同步，保留原时间设置；请在“日期和时间”中核对。' }
                    $service = Get-Service W32Time
                    if ([string]$service.StartType -eq 'Disabled') { throw 'Windows 时间服务被禁用，工具保留设置，请手动核对日期和时间。' }
                    if ([string]$service.Status -ne 'Running') { Start-Service W32Time; $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(8)) }
                    $r = Run-Local 'w32tm.exe' '/resync' 25
                    Say $r.Text
                    if ($r.ExitCode -ne 0) { throw 'Windows 时间同步未成功；未更改时间源。请在设置里核对日期、时间和时区。' }
                    $script:AutoActions += '已请求 Windows 使用原配置时间源同步；未采用网页时间直接改钟，接下来复测 HTTPS。'
                }
            }
            $after = Get-RepairState
            if ($after.NormalOK -eq 2) { return Finish-AutoRepair 'Repaired' '针对性处理后，两个 HTTPS 网站复测通过。请重新打开应用确认。' $before $after }
            if ($RequireApproval) { return Finish-AutoRepair 'Unresolved' '已执行本次确认的操作，但网络仍未全部通过。未处理其他故障；请重新运行 PREVIEW.cmd 查看下一份方案并另行确认。' $before $after }
            Say '基础处理已执行，网络尚未全部通过，将继续检查其他层。'
            return Auto-Repair -Depth ($Depth + 1)
        }
        $plan = Get-AutoPlan $before
        Say ("判断：{0} / {1}" -f $plan.Action, $plan.Reason)
        if ($plan.Action -in @('Healthy', 'Partial', 'Unresolved')) { return Finish-AutoRepair $plan.Action $plan.Reason $before $before }
        # Independent fresh tests and write-time reread. No repair from an old report.
        Say '正在复测确认，避免根据一次失败误改配置……'
        $fresh = Get-RepairState
        $again = Get-AutoPlan $fresh
        if ($RequireApproval -and -not (Test-PreviewApproval $fresh $ApprovedPreview)) { return Finish-AutoRepair 'Changed' '执行前方案已变化，未执行修复，请重新预览确认。' $before $fresh }
        if ($again.Action -ne $plan.Action -or $fresh.Fingerprint -cne $before.Fingerprint) {
            return Finish-AutoRepair 'Changed' '复测结果或代理配置已变化，本次停止自动修改。可稍后重新运行。' $before $fresh
        }
        if ($plan.Action -eq 'Proxy') {
            $backup = Save-Backup 'Proxy' $fresh.Proxy
            if ((Proxy-Fingerprint @(Get-ProxySnapshot)) -cne $fresh.Fingerprint -or (Get-ProxyProtection) -or (Tcp-Probe $fresh.Endpoint.Address $fresh.Endpoint.Port)) {
                return Finish-AutoRepair 'Changed' '写入前检测到代理配置、进程或监听状态变化，保留当前设置。' $before $fresh $backup
            }
            # Only disable the manual flag; retain server/bypass and never erase a PAC URL here.
            $expected = @($fresh.Proxy | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
            ($expected | Where-Object { $_.Name -eq 'ProxyEnable' }).Value = 0
            ($expected | Where-Object { $_.Name -eq 'ProxyEnable' }).Kind = 'DWord'
            $ours = Proxy-Fingerprint $expected
            $restoreData = $fresh.Proxy; $pending = 'Proxy'
            New-ItemProperty -LiteralPath $script:ProxyPath -Name ProxyEnable -Value 0 -PropertyType DWord -Force | Out-Null
            $script:AutoActions += '备份后关闭失效本地代理的手动开关；保留代理地址与绕过列表。'
            Notify-Proxy
            if ((Proxy-Fingerprint @(Get-ProxySnapshot)) -cne $ours) { throw '代理写入后的回读不匹配，结果不确定，未继续修改。备份已保存。' }
            $after = Get-RepairState
            if ($after.NormalOK -eq 2 -and $after.Fingerprint -ceq $ours) {
                return Finish-AutoRepair 'Repaired' '已备份并关闭失效的本地手动代理，配置回读通过，两个 HTTPS 网站复测通过。重新打开应用后再验证。' $before $after $backup
            }
            if ((Proxy-Fingerprint @(Get-ProxySnapshot)) -cne $ours) { throw '复测期间其他程序修改了代理，本工具停止写入，未覆盖其他程序的设置。' }
            Restore-ProxyValues $fresh.Proxy
            $pending = ''
            $script:AutoActions += '代理修复复测未通过，已恢复原设置并回读。'
            $after = Get-RepairState
            return Finish-AutoRepair 'RolledBack' '关闭代理后复测未全部通过，已恢复原代理并回读。可在 START.cmd 中进一步检查。' $before $after $backup
        }
        # DNS repair is restricted to an uncomplicated DHCP home-network interface.
        try { Need-Admin } catch { return Finish-AutoRepair 'NeedsAdmin' '发现 DNS 故障线索。请右键原启动入口（确认模式用 PREVIEW.cmd），以管理员身份运行后重新检测、预览并确认；本次未修改配置。' $before $fresh }
        $a = Get-AutoDnsAdapter
        Flush-Dns
        $script:AutoActions += '清除 DNS 缓存；不改变 DNS 地址。'
        $fresh = Get-RepairState
        if ($fresh.NormalOK -eq 2) { return Finish-AutoRepair 'Repaired' '清除 DNS 缓存后，两个 HTTPS 网站复测通过，未更换 DNS 地址。' $before $fresh }
        if ($RequireApproval -and -not (Test-PreviewApproval $fresh $ApprovedPreview)) { return Finish-AutoRepair 'Changed' '已按确认清除 DNS 缓存，但复测方案已变化，未更换 DNS。请重新预览确认。' $before $fresh }
        if ((Get-AutoPlan $fresh).Action -ne 'Dns') { return Finish-AutoRepair 'Unresolved' '清缓存后证据发生变化，未更换 DNS。请查看完整诊断。' $before $fresh }
        $a = Get-AutoDnsAdapter
        $data = Get-DnsData $a
        $servers = @(Get-GoodPublicDns $fresh.Dns)
        $backup = Save-Backup 'Dns' $data
        $check = Get-AutoDnsAdapter
        if ([string]$check.InterfaceGuid -ne $data.Guid -or ((Get-DnsData $check | ConvertTo-Json -Depth 5 -Compress) -cne ($data | ConvertTo-Json -Depth 5 -Compress)) -or (Proxy-Fingerprint @(Get-ProxySnapshot)) -cne $fresh.Fingerprint -or (Get-ProxyProtection)) {
            return Finish-AutoRepair 'Changed' '写入前网络或代理配置已变化，未修改 DNS。' $before $fresh $backup
        }
        $restoreData = $data; $pending = 'Dns'
        Get-V4Dns $a | Set-DnsClientServerAddress -ServerAddresses $servers
        $script:AutoActions += ('备份后试用已通过两域名查询测试的公共 DNS：' + ($servers -join ', '))
        if ((@((Get-V4Dns $a).ServerAddresses) -join ',') -ne ($servers -join ',')) { throw 'DNS 写入回读不匹配，结果不确定。请查看备份，不会继续重试。' }
        Say (Run-Local 'ipconfig.exe' '/flushdns').Text
        $after = Get-RepairState
        $matches = @((([string](Get-StaticDns $a)) -split '[,;\s]+') | Where-Object { $_ })
        if (($matches -join ',') -ne ($servers -join ',') -or (@((Get-V4Dns $a).ServerAddresses) -join ',') -ne ($servers -join ',')) { throw '复测期间 DNS 被其他程序改变，停止写入，未覆盖其他程序设置。' }
        if ($after.NormalOK -eq 2 -and $after.Fingerprint -ceq $fresh.Fingerprint) {
            return Finish-AutoRepair 'Repaired' ("已备份并为网卡 $($a.Name) 设置通过测试的公共 DNS：$($servers -join ', ')；两个 HTTPS 网站复测通过。可在菜单 5 恢复原自动 DNS。") $before $after $backup
        }
        Get-V4Dns $a | Set-DnsClientServerAddress -ResetServerAddresses
        if (-not [string]::IsNullOrWhiteSpace((Get-StaticDns $a))) { throw '自动恢复原 DNS 后回读未通过，请用备份核对。' }
        $pending = ''
        $script:AutoActions += 'DNS 试用复测未通过，已恢复自动获取并回读。'
        Say (Run-Local 'ipconfig.exe' '/flushdns').Text
        $after = Get-RepairState
        return Finish-AutoRepair 'RolledBack' '公共 DNS 试用后复测未全部通过，已恢复原先的自动 DNS 并回读。' $before $after $backup
    } catch {
        $failure = $_.Exception.Message
        # Even on a probe exception, restore only if the live configuration is still ours.
        try {
            if ($pending -eq 'Proxy' -and (Proxy-Fingerprint @(Get-ProxySnapshot)) -ceq $ours) {
                Restore-ProxyValues $restoreData
                $script:AutoActions += '后续检测异常，确认配置未被其他程序改动后已恢复原代理。'
                return Finish-AutoRepair 'RolledBack' ("检测中断：$failure。已恢复原代理并回读；实际连通性尚需验证。") $before $null $backup
            }
            if ($pending -eq 'Dns') {
                $sameAdapter = @(Get-NetAdapter | Where-Object { [string]$_.InterfaceGuid -eq $restoreData.Guid -and $_.ifIndex -eq $a.ifIndex })
                $rawNow = @((([string](Get-StaticDns $a)) -split '[,;\s]+') | Where-Object { $_ })
                if ($sameAdapter.Count -eq 1 -and ($rawNow -join ',') -eq ($servers -join ',') -and (@((Get-V4Dns $a).ServerAddresses) -join ',') -eq ($servers -join ',')) {
                    Get-V4Dns $a | Set-DnsClientServerAddress -ResetServerAddresses
                    if (-not [string]::IsNullOrWhiteSpace((Get-StaticDns $a))) { throw 'DNS 异常恢复后的回读未通过。' }
                    $script:AutoActions += '后续检测异常，确认 DNS 仍为本工具设置后已恢复原自动 DNS。'
                    return Finish-AutoRepair 'RolledBack' ("检测中断：$failure。已恢复原自动 DNS 并回读；实际连通性尚需验证。") $before $null $backup
                }
            }
        } catch { $failure += '；恢复检查也未完成：' + $_.Exception.Message }
        return Finish-AutoRepair 'Stopped' ("已停止：$failure；如有备份，可用 START.cmd 菜单 5 恢复。不会盲目重试或覆盖其他程序修改。") $before $after $backup
    }
}
function Main {
    if ($env:OS -ne 'Windows_NT') { throw '本工具只能在 Windows 10/11 上运行。' }
    if (@(@($AutoRepair, $DiagnoseOnly, $PreviewOnly, $PreviewRepair, $CleanupReports) | Where-Object { [bool]$_ }).Count -gt 1) { throw '各启动模式不能混用。' }
    $root = Join-Path $env:LOCALAPPDATA 'Windows-Net-Rescue'
    $script:ReportsRoot = Join-Path $root 'Reports'
    $script:BackupDir = Join-Path $root 'Backups'
    if ($CleanupReports) { $null = Invoke-ReportCleanup $script:ReportsRoot $script:BackupDir; return }
    # Windows PowerShell may otherwise inherit legacy TLS defaults. Process-local only.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:Machine = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $script:ReportDir = New-ReportSession $script:ReportsRoot
    $null = New-Item -ItemType Directory -Path $script:BackupDir -Force
    $script:Log = Join-Path $script:ReportDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-report.txt')
    try {
        Say 'Windows 断网诊断与修复工具 v2.2 / Windows 10、11 / 内置组件，无需下载依赖'
        Say "运行账户：$([Security.Principal.WindowsIdentity]::GetCurrent().Name)。若 UAC 要求另一账户密码，请注意代理设置只对应运行账户。"
        Say '每次检测记录集中在一个子文件夹，正常结束时默认保留最近 3 次；旧记录移入回收站，恢复备份始终保留。'
        if ($PreviewOnly) { $result = Invoke-RepairPreview -Only; Open-ResultReport $result; return }
        if ($PreviewRepair) { $result = Invoke-RepairPreview; Open-ResultReport $result; return }
        if ($AutoRepair) { $result = Auto-Repair; Open-ResultReport $result; return }
        Say 'START.cmd 打开后仅检测；自动修复请选 8 或使用 AUTO-FIX.cmd。不会上传报告、删除 WiFi 密码、关闭防火墙、卸载驱动或自动重启。'
        try { Diagnose } catch { Say "诊断部分未完成：$($_.Exception.Message)" }
        if ($DiagnoseOnly) { return }
        while ($true) {
            Write-Host "`r`n1 重新诊断     2 清除 DNS 缓存（管理员）`r`n3 暂时关闭当前用户代理     4 修改所选网卡 DNS（管理员）`r`n5 恢复 DNS / 代理备份     6 高级：重置 Winsock（管理员）`r`n7 打开报告文件夹     8 自动检测并修复`r`n9 只读预览并由我确认后修复     10 清理历史报告     0 退出"
            $choice = Read-Host '输入数字'
            if ($choice -eq '0') { break }
            try {
                switch ($choice) {
                    '1' { Diagnose }
                    '2' { Flush-Dns; Diagnose }
                    '3' { Disable-Proxy; Diagnose }
                    '4' { Change-Dns; Diagnose }
                    '5' { Restore-Backup; Diagnose }
                    '6' { Reset-Winsock }
                    '7' { Start-Process explorer.exe -ArgumentList ('"' + $script:ReportsRoot + '"') }
                    '8' { $result = Auto-Repair; Open-ResultReport $result }
                    '9' { $result = Invoke-RepairPreview; Open-ResultReport $result }
                    '10' { $null = Invoke-ReportCleanup $script:ReportsRoot $script:BackupDir }
                    default { Write-Host '请输入菜单数字。' }
                }
            } catch { Say "未完成 / 结果需核对：$($_.Exception.Message)" }
        }
        Say "已退出。报告保存在：$script:ReportDir"
    } finally {
        try {
            $retention = Update-ReportRetention $script:ReportsRoot 3
            if ($retention.MovedFiles -gt 0) { Say ("已整理历史报告：{0} 个文件移入回收站；保留最近 3 次可管理记录和恢复备份。" -f $retention.MovedFiles) }
            foreach ($message in $retention.Failed) { Say ('旧报告暂未清理：' + $message) }
        } catch { Write-Host ('报告整理未完成，已保留文件：' + $_.Exception.Message) }
    }
}

Main
