<#
  HTTPS on the hospital's network (backend plan 24 section 11, OP5).

  This computer is its own small certificate authority. The backend jar's BoxLanCertificate keeps it and the
  certificate nginx serves:
    %ProgramData%\Vyaptek\HMS\lan-ca\   ca.key, ca.crt: SYSTEM and Administrators only. The CA is limited to
                                        this computer's names and private addresses, so even its key is no
                                        use against any other site. Kept on uninstall, so a reinstall keeps
                                        every PC's trust.
    nginx\conf\tls\                     server.crt (with the CA), server.key: also readable by nginx's own
                                        account (NT SERVICE\NginxWebProxy, OP2).
    nginx\trust\                        what the trust page (http://<this computer>/trust) offers: the CA for
                                        Windows (Trust-Vyaptek-HMS.bat), Android (.crt), iPhone/iPad
                                        (.mobileconfig).

  Every run, as SYSTEM: collects this computer's names (its name, its name with the DNS suffix, the names in
  nginx\conf\server-names-extra.conf) and its IPv4 addresses; has BoxLanCertificate issue a new certificate
  when one of them is missing or the certificate is within 30 days of expiry (a new CA only when a name is
  outside the current one); trusts the CA on this computer itself (Local Machine, so the HMS shortcut opens
  without a warning); switches nginx to the HTTPS site (lan-site.conf) once nginx accepts it; and restarts
  nginx when anything changed.

  If anything fails, HMS stays on the site that works: HTTPS when the certificate nginx has is still good,
  plain HTTP otherwise (lan-site-http.conf, as before OP5). The next run tries again.

  (no switch)  The scheduled task "\Vyaptek\Vyaptek HMS HTTPS Certificate": 1 minute after every start,
               every hour, and 30 seconds after the computer joins a network (a new address from DHCP).
  -Install     The installer, on every install and upgrade, after nginx is registered and before it starts:
               also registers that task. Leaves nginx alone (the installer starts it next).

  Writes -LogFile (replaced each run), status=https|http and message= to -ResultFile, and to the Windows
  Application event log (source VyaptekHMS): 821 when the certificate or CA changed, 822 on a failure.
  Exit code 0 when HMS serves HTTPS, 1 otherwise.
#>
param(
  [string]$AppDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [string]$CaDir = (Join-Path $env:ProgramData 'Vyaptek\HMS\lan-ca'),
  [switch]$Install,
  [string]$LogFile = '',
  [string]$ResultFile = ''
)
$ErrorActionPreference = 'Stop'
$taskName = 'Vyaptek HMS HTTPS Certificate'
$computerName = $env:COMPUTERNAME.ToLowerInvariant()
$nginxService = 'NginxWebProxy'
$nginxDir = Join-Path $AppDir 'nginx'
$confDir = Join-Path $nginxDir 'conf'
$certDir = Join-Path $confDir 'tls'
$trustDir = Join-Path $nginxDir 'trust'
$siteFile = Join-Path $confDir 'lan-site.conf'
$serverCert = Join-Path $certDir 'server.crt'
$caCert = Join-Path $CaDir 'ca.crt'
if (-not $LogFile) { $LogFile = Join-Path $AppDir 'backend\logs\lan-tls.log' }

function Log([string]$text) {
  Write-Output $text
  Add-Content -Path $LogFile -Encoding ASCII -Value ((Get-Date -Format s) + ' ' + $text)
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
Set-Content -Path $LogFile -Encoding ASCII -Value @()

function Write-Event([string]$type, [int]$id, [string]$text) {
  & eventcreate /T $type /ID $id /L APPLICATION /SO VyaptekHMS /D $text 2>&1 | Out-Null
}

function Write-Result([string]$status, [string]$message) {
  if ($ResultFile) { Set-Content -Path $ResultFile -Encoding ASCII -Value @("status=$status", "message=$message") }
}

# A native program: its output and exit code. Windows PowerShell 5.1 turns a native program's stderr line
# into a terminating error under 'Stop', so not here.
function Invoke-Native([string]$exe, [string[]]$arguments) {
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
  } finally {
    $ErrorActionPreference = $saved
  }
}

# lan-site.conf names the site nginx serves.
function Get-Site {
  if (Test-Path $siteFile) { return (Get-Content $siteFile -Raw).Trim() }
  return ''
}
function Set-Site([string]$mode) {
  Set-Content -Path $siteFile -Encoding ASCII -Value "include lan-site-$mode.conf;"
}

# nginx -t, run where the service runs it (its working directory is its prefix on Windows).
function Test-Nginx {
  Push-Location $nginxDir
  try { return Invoke-Native (Join-Path $nginxDir 'nginx.exe') @('-t') } finally { Pop-Location }
}

function Restart-Nginx([string]$why) {
  $service = Get-Service -Name $nginxService -ErrorAction SilentlyContinue
  if ($Install -or -not $service -or $service.Status -ne 'Running') { return }
  Restart-Service -Name $nginxService -Force
  Log "Restarted nginx: $why."
}

function Register-Task {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AppDir `"$AppDir`""
  $atStart = New-ScheduledTaskTrigger -AtStartup
  $atStart.Delay = 'PT1M'
  # Without -RepetitionDuration the hourly repetition has no end (Windows 10 and later).
  $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
  # NetworkProfile 10000: connected to a network, which is when DHCP may have given a new address.
  $eventClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
  $onNetwork = New-CimInstance -CimClass $eventClass -ClientOnly
  $onNetwork.Enabled = $true
  $onNetwork.Delay = 'PT30S'
  $onNetwork.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">' +
    '<Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select></Query></QueryList>'
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -TaskPath '\Vyaptek\' -Action $action `
    -Trigger @($atStart, $hourly, $onNetwork) -Settings $settings -Principal $principal -Force | Out-Null
  Log "Scheduled '$taskName': at start, every hour and on a network change."
}

# This computer's names: its own, with its DNS suffix, and the hospital's extra names for nginx.
function Get-LanNames {
  $computer = $computerName
  $names = @($computer)
  $suffix = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
  if ($suffix) { $names += "$computer.$($suffix.ToLowerInvariant())" }
  $extra = Join-Path $confDir 'server-names-extra.conf'
  if (Test-Path $extra) {
    foreach ($line in Get-Content $extra) {
      $text = ($line -replace '#.*', '').Trim()
      if ($text -match '^server_name\s+([^;]+);') {
        # Plain names only: not nginx's regular expressions (~) or wildcards (*).
        $names += @($Matches[1] -split '\s+' | Where-Object { $_ -and $_ -notmatch '[~*"]' })
      }
    }
  }
  return $names
}

function Get-LanAddresses {
  return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.AddressState -eq 'Preferred' } | ForEach-Object { $_.IPAddress })
}

# The CA in Local Machine's trusted roots, so this computer's own browser and HMS shortcut trust it; a
# CA this computer made before (it was renamed) is taken out.
function Set-LocalTrust {
  $ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $caCert
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store -ArgumentList 'Root', 'LocalMachine'
  $store.Open('ReadWrite')
  try {
    $old = @($store.Certificates | Where-Object {
        $_.Subject -like '*O=Vyaptek HMS*' -and $_.Subject -like '*LAN CA*' -and $_.Thumbprint -ne $ca.Thumbprint })
    foreach ($c in $old) { $store.Remove($c); Log "Removed the old $($c.Subject)." }
    if (-not @($store.Certificates | Where-Object { $_.Thumbprint -eq $ca.Thumbprint }).Count) {
      $store.Add($ca)
      Log "This computer now trusts $($ca.Subject)."
    }
  } finally {
    $store.Close()
  }
  return $ca
}

$system = '*S-1-5-18'
$admins = '*S-1-5-32-544'
$siteAtStart = Get-Site
try {
  if ($Install) {
    # Not a reason to leave HTTPS off: the next install registers it again.
    try { Register-Task } catch { Log "Could not schedule '$taskName': $($_.Exception.Message)" }
  }

  foreach ($dir in @($CaDir, $certDir, $trustDir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $r = Invoke-Native 'icacls.exe' @($CaDir, '/inheritance:r', '/grant:r', "${system}:(OI)(CI)F", "${admins}:(OI)(CI)F")
  if ($r.Code -ne 0) { throw "icacls $CaDir failed: $($r.Output -join ' ')" }
  $r = Invoke-Native 'icacls.exe' @($certDir, '/inheritance:r', '/grant:r', "${system}:(OI)(CI)F", "${admins}:(OI)(CI)F")
  if ($r.Code -ne 0) { throw "icacls $certDir failed: $($r.Output -join ' ')" }
  # nginx reads the key as its own account. Without that account (service-accounts.ps1 failed, so nginx
  # still runs as LocalSystem) SYSTEM's entry is enough.
  $r = Invoke-Native 'icacls.exe' @($certDir, '/grant', "NT SERVICE\${nginxService}:(OI)(CI)RX")
  if ($r.Code -ne 0) { Log "nginx's own account could not be given the certificate folder; nginx runs as LocalSystem." }

  $names = Get-LanNames
  $ips = Get-LanAddresses
  $arguments = @('-cp', (Join-Path $AppDir 'backend\hms.jar'),
    '-Dloader.main=com.hospitalerp.common.boxtls.BoxLanCertificate',
    'org.springframework.boot.loader.launch.PropertiesLauncher',
    '--ca-dir', $CaDir, '--cert-dir', $certDir, '--trust-dir', $trustDir)
  foreach ($n in $names) { $arguments += @('--name', $n) }
  foreach ($ip in $ips) { $arguments += @('--ip', $ip) }
  $r = Invoke-Native (Join-Path $AppDir 'jre\bin\java.exe') $arguments
  $r.Output | ForEach-Object { Log $_ }
  $change = (@($r.Output | Where-Object { $_ -like 'result=*' }) | Select-Object -First 1) -replace '^result=', ''
  if ($r.Code -ne 0 -or -not $change -or $change -eq 'error') { throw "The certificate could not be made ($($r.Code))." }

  $ca = Set-LocalTrust

  Set-Site 'https'
  $test = Test-Nginx
  if ($test.Code -ne 0) {
    Set-Site 'http'
    throw "nginx refused the HTTPS settings: $($test.Output -join ' ')"
  }

  if ($change -ne 'unchanged' -or (Get-Site) -ne $siteAtStart) {
    Restart-Nginx "the certificate ($change) or the site changed"
  }
  if ($change -eq 'new-ca') {
    Write-Event 'INFORMATION' 821 "Vyaptek HMS made a new HTTPS certificate authority ($($ca.Subject)). Every PC, phone and tablet must trust it again from http://$computerName/trust ."
  } elseif ($change -eq 'issued') {
    Write-Event 'INFORMATION' 821 "Vyaptek HMS renewed its HTTPS certificate for this computer's names and addresses."
  }
  Write-Result 'https' "HMS uses HTTPS on the hospital network. On each PC, phone and tablet, open http://$computerName/trust once and follow the steps."
  Log 'HTTPS is on.'
  exit 0
} catch {
  $problem = $_.Exception.Message
  Log "HTTPS problem: $problem"
  # Keep HTTPS when nginx still accepts it (a certificate from an earlier run); otherwise plain HTTP.
  $status = 'http'
  try {
    if ((Test-Path $serverCert) -and (Test-Path $caCert)) {
      Set-Site 'https'
      if ((Test-Nginx).Code -eq 0) { $status = 'https' } else { Set-Site 'http' }
    } else {
      Set-Site 'http'
    }
    if ((Get-Site) -ne $siteAtStart) { Restart-Nginx "now serving $status" }
  } catch {
    Log "Could not choose the site: $($_.Exception.Message)"
  }
  Write-Event 'WARNING' 822 "Vyaptek HMS could not set up its HTTPS certificate: $problem It serves $status; the next run (within the hour) tries again. Details: $LogFile"
  if ($status -eq 'https') {
    Write-Result 'https' "HMS uses HTTPS, but its certificate could not be checked ($problem). It tries again within the hour."
  } else {
    Write-Result 'http' "HMS works, but without HTTPS on the hospital network: $problem It tries again within the hour; if this stays, send $LogFile to Vyaptek."
  }
  exit 1
}
