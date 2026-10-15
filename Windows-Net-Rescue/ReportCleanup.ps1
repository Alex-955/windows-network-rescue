#requires -Version 5.1
# Report maintenance only. This library never changes network settings or deletes backups.
function Test-OwnedReportName([string]$Name) {
    return $Name -cmatch '^\d{8}-\d{6}-\d{3}-(report\.txt|dns\.json|auto-result\.(json|html)|approved-plan\.json|infrastructure-before\.json|winsock-before\.txt)$'
}
function Test-ReportReparsePoint($Item) {
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Get-ReportSignature([string]$Path, [bool]$Directory) {
    $items = if ($Directory) { @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name) } else { @(Get-Item -LiteralPath $Path -Force) }
    return (($items | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks, [int]$_.Attributes }) -join "`n")
}
function Convert-ReportUtc($Value) {
    # PowerShell 7 can deserialize JSON dates as DateTime; avoid string casts that drop UTC/precision.
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Test-ReportProcessActive($Marker) {
    try {
        $process = Get-Process -Id ([int]$Marker.ProcessId) -ErrorAction Stop
        $expected = Convert-ReportUtc $Marker.ProcessStartUtc
        return ([Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 1)
    } catch {
        # A missing PID is inactive; a PID we cannot inspect is protected.
        return [bool](Get-Process -Id ([int]$Marker.ProcessId) -ErrorAction SilentlyContinue)
    }
}
function Get-ReportCleanupInventory([string]$Root) {
    $candidates = @(); $skipped = @(); $active = 0
    if (-not (Test-Path -LiteralPath $Root)) { return [pscustomobject]@{ Candidates = @(); Skipped = @(); ActiveCount = 0 } }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer -or (Test-ReportReparsePoint $rootItem)) { throw '报告目录不是普通本地目录，停止清理，避免处理链接目标。' }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
        if (Test-ReportReparsePoint $item) { $skipped += $item.FullName; continue }
        if (-not $item.PSIsContainer) {
            if (Test-OwnedReportName $item.Name) {
                $candidates += [pscustomobject]@{ Path = $item.FullName; Directory = $false; Kind = '旧版报告'; Files = 1; Bytes = $item.Length; Stamp = $item.LastWriteTimeUtc; Signature = (Get-ReportSignature $item.FullName $false) }
            } else { $skipped += $item.FullName }
            continue
        }
        if ($item.Name -cnotmatch '^\d{8}-\d{6}-\d{3}-[0-9a-f]{6}$') { $skipped += $item.FullName; continue }
        $children = @(Get-ChildItem -LiteralPath $item.FullName -Force)
        if (@($children | Where-Object { $_.PSIsContainer -or (Test-ReportReparsePoint $_) -or ($_.Name -ne 'session.json' -and -not (Test-OwnedReportName $_.Name)) }).Count) { $skipped += $item.FullName; continue }
        $markerPath = Join-Path $item.FullName 'session.json'
        try {
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($marker.Tool -cne 'Windows-Net-Rescue' -or $marker.Schema -ne 1 -or $marker.SessionId -cne $item.Name -or [int]$marker.ProcessId -eq 0) { throw '标记无效' }
            $stamp = Convert-ReportUtc $marker.StartedUtc
            $null = Convert-ReportUtc $marker.ProcessStartUtc
        } catch { $skipped += $item.FullName; continue }
        if (Test-ReportProcessActive $marker) { $active++; $skipped += $item.FullName; continue }
        $candidates += [pscustomobject]@{ Path = $item.FullName; Directory = $true; Kind = '一次检测记录'; Files = $children.Count; Bytes = ($children | Measure-Object Length -Sum).Sum; Stamp = $stamp; Signature = (Get-ReportSignature $item.FullName $true) }
    }
    return [pscustomobject]@{ Candidates = $candidates; Skipped = $skipped; ActiveCount = $active }
}
function New-ReportSession([string]$Root) {
    if (Test-Path -LiteralPath $Root) {
        $rootItem = Get-Item -LiteralPath $Root -Force
        if (-not $rootItem.PSIsContainer -or (Test-ReportReparsePoint $rootItem)) { throw '报告目录含链接或不是普通目录，未创建记录。' }
    } else { $null = New-Item -ItemType Directory -Path $Root -Force }
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $path = Join-Path $Root $id
    $null = New-Item -ItemType Directory -Path $path
    $process = Get-Process -Id $PID
    [pscustomobject]@{ Tool = 'Windows-Net-Rescue'; Schema = 1; SessionId = $id; StartedUtc = [DateTimeOffset]::UtcNow.ToString('o'); ProcessId = $PID; ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $path 'session.json') -Encoding UTF8
    return $path
}
function Initialize-ReportRecycleApi {
    if ('NetRescue.ReportRecycle' -as [type]) { return }
    # IFileOperation is available on supported Windows versions. RECYCLEONDELETE is an explicit
    # recycle operation (Windows 8+), unlike the older SHFileOperation ALLOWUNDO best-effort flag.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetRescue {
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IReportShellItem {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IReportShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IReportShellItem other, uint hint, out int order);
    }
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IReportFileOperation {
        void Advise(IntPtr sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr changes);
        void SetOwnerWindow(IntPtr owner);
        void ApplyPropertiesToItem(IntPtr item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IntPtr item, IntPtr name, IntPtr sink);
        void RenameItems(IntPtr items, IntPtr name);
        void MoveItem(IntPtr item, IntPtr destination, IntPtr name, IntPtr sink);
        void MoveItems(IntPtr items, IntPtr destination);
        void CopyItem(IntPtr item, IntPtr destination, IntPtr name, IntPtr sink);
        void CopyItems(IntPtr items, IntPtr destination);
        void DeleteItem(IReportShellItem item, IntPtr sink);
        void DeleteItems(IntPtr items);
        void NewItem(IntPtr destination, uint attributes, IntPtr name, IntPtr template, IntPtr sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    public static class ReportRecycle {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=true, ExactSpelling=true)]
        static extern int SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid,
            out IReportShellItem item);
        public static void Move(string path) {
            IReportShellItem item = null;
            IReportFileOperation operation = null;
            try {
                var shellItemId = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref shellItemId, out item));
                var operationType = Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09"));
                operation = (IReportFileOperation)Activator.CreateInstance(operationType);
                const uint RECYCLEONDELETE = 0x00080000;
                const uint ADDUNDORECORD = 0x20000000;
                const uint SILENT = 0x0004, NOCONFIRMATION = 0x0010, NOERRORUI = 0x0400, EARLYFAILURE = 0x00100000;
                operation.SetOperationFlags(RECYCLEONDELETE | ADDUNDORECORD | SILENT | NOCONFIRMATION | NOERRORUI | EARLYFAILURE);
                operation.DeleteItem(item, IntPtr.Zero);
                operation.PerformOperations();
                bool aborted;
                operation.GetAnyOperationsAborted(out aborted);
                if (aborted) throw new InvalidOperationException("Recycle operation was interrupted; verify original path and Recycle Bin.");
            } finally {
                if (operation != null && Marshal.IsComObject(operation)) Marshal.FinalReleaseComObject(operation);
                if (item != null && Marshal.IsComObject(item)) Marshal.FinalReleaseComObject(item);
            }
        }
    }
}
'@
}
function Move-ReportToRecycleBin([string]$Path, [bool]$Directory) {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw '回收站操作需要 STA 模式，请通过新版 CMD 入口运行。原文件未由此调用移动。' }
    Initialize-ReportRecycleApi
    [NetRescue.ReportRecycle]::Move($Path)
}
function Move-OwnedReports([string]$Root, $Selected) {
    $moved = 0; $files = 0; $bytes = 0; $failed = @()
    foreach ($entry in @($Selected)) {
        if ($null -eq $entry) { continue }
        try {
            # Re-enumerate before every move. Changed, active, linked, or unknown content is protected.
            $fresh = Get-ReportCleanupInventory $Root
            $match = @($fresh.Candidates | Where-Object { $_.Path -ceq $entry.Path -and $_.Directory -eq $entry.Directory -and $_.Signature -ceq $entry.Signature })
            if ($match.Count -ne 1) { throw '记录已变化、正在使用或不再符合清理范围' }
            Move-ReportToRecycleBin $entry.Path $entry.Directory
            if (Test-Path -LiteralPath $entry.Path) { throw '回读发现原路径仍存在，未确认清理成功' }
            $moved++; $files += $entry.Files; $bytes += $entry.Bytes
        } catch { $failed += ($entry.Path + '：' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ MovedItems = $moved; MovedFiles = $files; Bytes = $bytes; Failed = $failed }
}
function Update-ReportRetention([string]$Root, [int]$Keep = 3) {
    if ($Keep -lt 1) { throw '至少保留一次记录。' }
    $inventory = Get-ReportCleanupInventory $Root
    # Legacy flat files are only removed by explicit cleanup, never guessed into sessions.
    $sessions = @($inventory.Candidates | Where-Object { $_.Directory } | Sort-Object Stamp -Descending)
    $slots = [Math]::Max(0, $Keep - $inventory.ActiveCount)
    $old = @($sessions | Select-Object -Skip $slots)
    return Move-OwnedReports $Root $old
}
function Invoke-ReportCleanup([string]$Root, [string]$Backups) {
    Write-Host "报告清理 v2.2`r`n仅处理本工具生成的报告，移入回收站；不会删除恢复备份或修改网络配置。"
    Write-Host '建议先退出其他检测窗口；运行中、有其他文件或含链接的目录会保留。'
    $inventory = Get-ReportCleanupInventory $Root
    $items = @($inventory.Candidates)
    $backupCount = if (Test-Path -LiteralPath $Backups) { @(Get-ChildItem -LiteralPath $Backups -File -Filter '*.json').Count } else { 0 }
    Write-Host "恢复备份：$backupCount 份，保留在 $Backups（START.cmd → 菜单 5 可恢复）。"
    if (-not $items.Count) { Write-Host '没有可清理的报告。'; return [pscustomobject]@{ Status = 'Empty'; MovedFiles = 0; Protected = $inventory.Skipped.Count } }
    foreach ($entry in $items) { Write-Host ("将移入回收站：{0}（{1} 个文件）" -f $entry.Path, $entry.Files) }
    $total = ($items | Measure-Object Bytes -Sum).Sum
    Write-Host ("合计约 {0:N1} KB；保留的运行中或未知项目：{1}。" -f ($total / 1KB), $inventory.Skipped.Count)
    if ((Read-Host '确认清理以上报告请输入 CLEAN；直接回车取消') -cne 'CLEAN') { Write-Host '已取消，没有移动文件。'; return [pscustomobject]@{ Status = 'Cancelled'; MovedFiles = 0; Protected = $inventory.Skipped.Count } }
    $result = Move-OwnedReports $Root $items
    Write-Host ("已移入回收站并回读确认：{0} 个报告文件。恢复备份保持原样。" -f $result.MovedFiles)
    foreach ($message in $result.Failed) { Write-Host ('未确认清理完成，请核对原路径与回收站：' + $message) }
    return $result
}
