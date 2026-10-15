$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../Windows-Net-Rescue/ReportCleanup.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('net-rescue-cleanup-test-' + [guid]::NewGuid().ToString('N'))
$reportRoot = Join-Path $testRoot 'Reports'
$backupRoot = Join-Path $testRoot 'Backups'
$trashRoot = Join-Path $testRoot 'MockRecycleBin'
$null = New-Item -ItemType Directory -Path $reportRoot, $backupRoot, $trashRoot
$script:Moves = 0; $script:FailMove = $false
$script:Answer = 'CLEAN'
function Assert($condition,[string]$message) { if(-not $condition){throw "FAIL: $message"} }
function Read-Host { return $script:Answer }
function Move-ReportToRecycleBin([string]$Path,[bool]$Directory) {
    if($script:FailMove){throw 'Injected recycle bin unavailable'}
    Move-Item -LiteralPath $Path -Destination (Join-Path $trashRoot ([guid]::NewGuid().ToString('N')))
    $script:Moves++
}
function Seed-Report([string]$Name,[string]$Content='report') {
    $p=Join-Path $reportRoot $Name
    Set-Content -LiteralPath $p -Value $Content -Encoding UTF8
    return $p
}
function Seed-Session([int]$Day) {
    $id='202601{0:D2}-120000-000-abcdef'-f $Day
    $p=Join-Path $reportRoot $id
    $null=New-Item -ItemType Directory -Path $p
    [pscustomobject]@{Tool='Windows-Net-Rescue';Schema=1;SessionId=$id;StartedUtc=('2026-01-{0:D2}T12:00:00Z'-f $Day);ProcessId=-1;ProcessStartUtc='2026-01-01T00:00:00Z'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $p 'session.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $p ('202601{0:D2}-120000-000-report.txt'-f $Day)) -Value 'report' -Encoding UTF8
    return $p
}
try {
    Initialize-ReportRecycleApi
    Assert ($null-ne ('NetRescue.ReportRecycle'-as [type])) 'Windows recycle interop must compile without performing file operations'
    $backup=Join-Path $backupRoot '20260101-120000-000-Proxy-abcdef.json'
    Set-Content -LiteralPath $backup -Value 'must be preserved' -Encoding UTF8
    $backupHash=(Get-FileHash -LiteralPath $backup).Hash
    $legacy=Seed-Report '20260101-120000-000-report.txt'
    $legacyHtml=Seed-Report '20260101-120000-001-auto-result.html'
    $unknown=Seed-Report 'my-notes.txt' 'personal file'
    $sessions=@(1..5|ForEach-Object{Seed-Session $_})
    $current=New-ReportSession $reportRoot
    $inventory=Get-ReportCleanupInventory $reportRoot
    Assert ($inventory.ActiveCount-eq 1) 'Running session protected'
    Assert (@($inventory.Candidates|Where-Object{$_.Path-eq $legacy}).Count-eq 1) 'Legacy timestamped reports recognized'
    Assert (@($inventory.Candidates|Where-Object{$_.Path-eq $unknown}).Count-eq 0) 'Personal files not candidates'
    $r=Update-ReportRetention $reportRoot 3
    Assert ($r.MovedItems-eq 3 -and (Test-Path $current) -and (Test-Path $sessions[4]) -and (Test-Path $sessions[3])) 'Retention keeps current run plus latest two inactive runs'
    Assert ((Test-Path $legacy) -and (Test-Path $legacyHtml)) 'Legacy files are not guessed into automatic sessions'
    Assert ((Get-FileHash $backup).Hash-eq $backupHash -and (Test-Path $unknown)) 'Retention does not touch backups or personal files'
    Write-Host 'PASS: Retention keeps three runs, protects active sessions, and preserves backups/unknown/legacy files'

    $before=$script:Moves;$script:Answer=''
    $r=Invoke-ReportCleanup $reportRoot $backupRoot
    Assert ($r.Status-eq 'Cancelled' -and $script:Moves-eq $before) 'Cancel performs no file moves'
    $script:Answer='CLEAN';$r=Invoke-ReportCleanup $reportRoot $backupRoot
    Assert (-not (Test-Path $legacy) -and -not (Test-Path $legacyHtml) -and $r.MovedFiles-eq 6) 'Explicit cleanup includes known legacy files and inactive sessions'
    Assert ((Test-Path $current) -and (Test-Path $unknown) -and (Get-FileHash $backup).Hash-eq $backupHash) 'Manual cleanup preserves active records, notes, and backup bytes'
    Write-Host 'PASS: Confirmed cleanup handles old/new reports; cancellation, active runs, and restore backups remain safe'

    $mixed=Seed-Session 6
    $personal=Join-Path $mixed 'holiday.txt';Set-Content $personal 'personal'
    $invalid=Seed-Session 7
    Set-Content -LiteralPath (Join-Path $invalid 'session.json') -Value '{broken'
    $inventory=Get-ReportCleanupInventory $reportRoot
    Assert (@($inventory.Candidates|Where-Object{$_.Path-in @($mixed,$invalid)}).Count-eq 0) 'Unknown content and invalid markers protect folders'
    $race=Seed-Report '20260108-120000-000-report.txt'
    $selected=@((Get-ReportCleanupInventory $reportRoot).Candidates|Where-Object{$_.Path-eq $race})
    Add-Content -LiteralPath $race -Value 'changed after preview'
    $before=$script:Moves;$r=Move-OwnedReports $reportRoot $selected
    Assert ($r.Failed.Count-eq 1 -and $script:Moves-eq $before -and (Test-Path $race)) 'Changed report not moved from stale preview'
    Write-Host 'PASS: Mixed-content folders, corrupt markers, and preview/write races are protected'

    $script:FailMove=$true
    $selected=@((Get-ReportCleanupInventory $reportRoot).Candidates|Where-Object{$_.Path-eq $race})
    $r=Move-OwnedReports $reportRoot $selected
    Assert ($r.Failed.Count-eq 1 -and (Test-Path $race)) 'Recycle failure must retain original, with no permanent-delete fallback'
    $script:FailMove=$false
    $outside=Join-Path $testRoot 'outside.txt';Set-Content $outside 'outside'
    $link=Join-Path $reportRoot '20260109-120000-000-report.txt'
    $linkCreated=$false
    try{$null=New-Item -ItemType SymbolicLink -Path $link -Target $outside;$linkCreated=$true}catch{Write-Host 'SKIP: Symlink creation unavailable on this test platform'}
    if($linkCreated){
        $inventory=Get-ReportCleanupInventory $reportRoot
        Assert (@($inventory.Candidates|Where-Object{$_.Path-eq $link}).Count-eq 0 -and (Test-Path $outside)) 'Symlink targets must be protected'
        $linkRoot=Join-Path $testRoot 'linked-root';$null=New-Item -ItemType SymbolicLink -Path $linkRoot -Target $reportRoot
        try{$null=Get-ReportCleanupInventory $linkRoot;throw 'Unexpected success'}catch{Assert ($_.Exception.Message-match '目录') 'Linked report root must be rejected'}
    }
    Write-Host 'PASS: Recycle failure retains originals; available symlink cases cannot reach outside data'
    $emptyRoot=Join-Path $testRoot 'never-created'
    $r=Invoke-ReportCleanup $emptyRoot $backupRoot
    Assert ($r.Status-eq 'Empty' -and -not (Test-Path $emptyRoot)) 'Cleanup itself creates no report directory or report'
    Assert ((Get-FileHash $backup).Hash-eq $backupHash) 'Backup still byte-identical after all cases'
    Write-Host 'PASS: Cleanup creates no new reports or directories; backup remains byte-identical'
    # Verify the real Main dispatch: cleanup must return before Windows identity/network diagnostics/session creation.
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Windows-Net-Rescue/NetRescue.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors|Out-String)}
    foreach($def in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)){Invoke-Expression $def.Extent.Text}
    $oldOS=$env:OS;$oldLocal=$env:LOCALAPPDATA
    try{
        $env:OS='Windows_NT';$env:LOCALAPPDATA=$testRoot
        $CleanupReports=$true;$AutoRepair=$false;$PreviewOnly=$false;$PreviewRepair=$false;$DiagnoseOnly=$false
        function Get-RepairState {throw 'Cleanup must never diagnose the network'}
        function Run-Local {throw 'Cleanup must never invoke network commands'}
        $null=Main
        Assert (-not (Test-Path -LiteralPath (Join-Path $testRoot 'Windows-Net-Rescue'))) 'Cleanup Main must not create data/report folders'
    }finally{$env:OS=$oldOS;$env:LOCALAPPDATA=$oldLocal}
    Write-Host 'PASS: Real cleanup entry bypasses diagnostics, Windows identity, network commands, and new report creation'
    Write-Host 'ALL REPORT CLEANUP TESTS PASSED. Recycle operations were simulated in a temporary directory.'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
