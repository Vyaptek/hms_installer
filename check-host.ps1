<#
  Host evidence for an audit of the HMS server (backend plan 24 section 11, OP12). Reads only; changes
  nothing. Run it through Check-HMS-Host.bat (it asks for administrator rights, which BitLocker and some
  Defender details need). It writes a text report next to itself and opens it; send that file to Vyaptek
  or give it to the auditor. Hospital IT can run it again at any time.

  Each line is PASS, WARN or INFO with what was seen:
    BitLocker on the system drive, Defender (real-time protection, signature age), the three firewall
    profiles, SMBv1, Remote Desktop and network-level authentication, Windows updates still pending,
    the HMS services and the accounts they run as, the nightly backup, and every listening TCP port
    with its process.
#>
param(
  [string]$OutFile = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ("host-check-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))),
  [switch]$NoOpen
)
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line([string]$level, [string]$text) { $lines.Add(('{0,-5} {1}' -f $level, $text)) }
function Add-Heading([string]$text) { $lines.Add(''); $lines.Add("== $text") }
function Try-Check([string]$what, [scriptblock]$check) {
  try { & $check } catch { Add-Line 'WARN' "$what could not be read: $($_.Exception.Message)" }
}

$os = Get-CimInstance Win32_OperatingSystem
$lines.Add("Vyaptek HMS host check, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$lines.Add("Computer $env:COMPUTERNAME; $($os.Caption) $($os.Version) (build $($os.BuildNumber)); last boot $($os.LastBootUpTime)")
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { $lines.Add('Not run as administrator: BitLocker and some Defender lines may be missing.') }

Add-Heading 'Disk encryption'
Try-Check 'BitLocker' {
  $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
  if ($vol.ProtectionStatus -eq 'On') { Add-Line 'PASS' "BitLocker is on for $env:SystemDrive ($($vol.EncryptionMethod))." }
  else { Add-Line 'WARN' "BitLocker is off for $env:SystemDrive (the hospital database is on it). Status: $($vol.VolumeStatus)." }
}

Add-Heading 'Antivirus'
Try-Check 'Microsoft Defender' {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  if ($mp.RealTimeProtectionEnabled) { Add-Line 'PASS' 'Defender real-time protection is on.' }
  else { Add-Line 'WARN' 'Defender real-time protection is off (another antivirus may be in use; check below).' }
  $age = $mp.AntivirusSignatureAge
  if ($age -le 3) { Add-Line 'PASS' "Defender signatures are $age day(s) old." }
  else { Add-Line 'WARN' "Defender signatures are $age days old." }
}
Try-Check 'Security Center' {
  Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
    ForEach-Object { Add-Line 'INFO' "Antivirus registered with Windows: $($_.displayName)" }
}

Add-Heading 'Firewall'
Try-Check 'Firewall profiles' {
  foreach ($p in Get-NetFirewallProfile -ErrorAction Stop) {
    if ($p.Enabled) { Add-Line 'PASS' "$($p.Name) profile is on (inbound default: $($p.DefaultInboundAction))." }
    else { Add-Line 'WARN' "$($p.Name) profile is off." }
  }
  foreach ($c in Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
    Add-Line 'INFO' "Network '$($c.Name)' on $($c.InterfaceAlias) is $($c.NetworkCategory)."
  }
  $rule = Get-NetFirewallRule -DisplayName 'Vyaptek HMS Web' -ErrorAction SilentlyContinue
  if ($rule) {
    $addr = (($rule | Get-NetFirewallAddressFilter).RemoteAddress) -join ', '
    Add-Line 'INFO' "HMS web rule: port 80 from $addr."
  } else { Add-Line 'WARN' 'The "Vyaptek HMS Web" firewall rule is missing; other computers cannot open HMS.' }
}

Add-Heading 'File sharing and remote access'
Try-Check 'SMBv1' {
  $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
  if ($smb1) { Add-Line 'WARN' 'SMBv1 is on (obsolete; WannaCry spread over it).' } else { Add-Line 'PASS' 'SMBv1 is off.' }
}
Try-Check 'Remote Desktop' {
  $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop
  if ($ts.fDenyTSConnections -eq 1) { Add-Line 'PASS' 'Remote Desktop is off.' }
  else {
    $nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').UserAuthentication
    if ($nla -eq 1) { Add-Line 'INFO' 'Remote Desktop is on, with network-level authentication.' }
    else { Add-Line 'WARN' 'Remote Desktop is on WITHOUT network-level authentication.' }
  }
}

Add-Heading 'Windows updates'
Try-Check 'Pending updates' {
  $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
  $pending = @($searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates)
  if ($pending.Count -eq 0) { Add-Line 'PASS' 'No software updates are waiting.' }
  else {
    Add-Line 'WARN' "$($pending.Count) update(s) are waiting:"
    $pending | Select-Object -First 15 | ForEach-Object { $lines.Add("      $($_.Title)") }
  }
  $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
  if ($last) { Add-Line 'INFO' "Last update installed $($last.InstalledOn.ToString('yyyy-MM-dd')) ($($last.HotFixID))." }
}

Add-Heading 'HMS services'
Try-Check 'Services' {
  foreach ($name in 'VyaptekHMS', 'NginxWebProxy', 'VyaptekGarnet', 'postgresql-x64-18') {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction Stop
    if (-not $svc) { Add-Line 'WARN' "$name is not installed."; continue }
    $level = if ($svc.StartName -eq 'LocalSystem') { 'WARN' } else { 'PASS' }
    Add-Line $level "$name is $($svc.State), runs as $($svc.StartName)."
  }
}

Add-Heading 'Backups'
Try-Check 'Backups' {
  $root = Join-Path $env:ProgramData 'Vyaptek\HMS\backups'
  $task = Get-ScheduledTask -TaskPath '\Vyaptek\' -TaskName 'Vyaptek HMS Backup' -ErrorAction SilentlyContinue
  if ($task) { Add-Line 'PASS' "The nightly backup task is $($task.State)." } else { Add-Line 'WARN' 'The nightly backup task is missing; run the HMS installer again.' }
  $status = @{}
  Get-Content (Join-Path $root 'last-backup.txt') -ErrorAction SilentlyContinue | ForEach-Object { $k, $v = $_ -split '=', 2; $status[$k] = $v }
  if (-not $status.status) { Add-Line 'WARN' "No backup has run yet ($root)." }
  elseif ($status.status -ne 'OK') { Add-Line 'WARN' "The last backup FAILED at $($status.time): $($status.message)" }
  elseif ((Get-Date) - [datetime]$status.time -gt (New-TimeSpan -Hours 36)) { Add-Line 'WARN' "The last backup is from $($status.time), more than a day and a half ago." }
  else { Add-Line 'PASS' "Last backup $($status.time): $($status.set)." }
  $sets = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'backup.txt') })
  Add-Line 'INFO' "$($sets.Count) backup set(s) on this computer, encrypted so that only Vyaptek can read them. A copy kept off this computer is the hospital's to arrange."
}

Add-Heading 'Listening TCP ports'
Try-Check 'Ports' {
  $procs = @{}
  Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
  Get-NetTCPConnection -State Listen -ErrorAction Stop | Sort-Object LocalPort, LocalAddress | ForEach-Object {
    $scope = if ($_.LocalAddress -in '127.0.0.1', '::1') { 'this computer only' } else { 'network' }
    Add-Line 'INFO' ('{0,-5} {1,-16} {2,-20} {3}' -f $_.LocalPort, $_.LocalAddress, $procs[[int]$_.OwningProcess], $scope)
  }
  foreach ($port in 5432, 6379, 8080) {
    $open = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' }
    if ($open) { Add-Line 'WARN' "Port $port (an HMS internal service) listens beyond this computer." }
  }
}

Set-Content -Path $OutFile -Encoding UTF8 -Value $lines
Write-Output "Report written to $OutFile"
if (-not $NoOpen) { Start-Process notepad.exe $OutFile }
