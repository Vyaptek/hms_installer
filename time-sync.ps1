<#
  Keeps this computer's clock synced (backend docs/ABDM_RELAY_SPEC.md §7.5). ABDM drops a callback
  whose TIMESTAMP is more than about 15 minutes off, so a box whose clock drifts loses ABDM replies.
  Run by the installer on a box connected to ABDM.

  - The Windows Time service is set to start automatically and started.
  - A computer in a Windows domain takes its time from the domain controller; that is left alone.
  - Any other computer syncs from time.windows.com and time.google.com. Flag 0x8 makes Windows poll
    them on its regular schedule (hours at most) instead of the once-a-week default.

  Never fails the install: a problem is printed as a warning.
#>
$ErrorActionPreference = 'Continue'

try {
  Set-Service -Name w32time -StartupType Automatic -ErrorAction Stop
  Start-Service -Name w32time -ErrorAction Stop
} catch {
  Write-Warning "Could not start the Windows Time service: $($_.Exception.Message)"
  exit 0
}

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
  Write-Host 'This computer is in a domain; it keeps taking its time from the domain controller.'
} else {
  & w32tm /config /manualpeerlist:"time.windows.com,0x8 time.google.com,0x8" /syncfromflags:manual /update | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warning 'w32tm could not set the time servers.' }
}
& w32tm /resync /nowait | Out-Null
exit 0
