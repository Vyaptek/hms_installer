<#
  Runs a database fix Vyaptek wrote for this one computer (backend plan 24 section 11, OP1). Run through
  Run-HMS-Fix.bat <file.sql>, which asks for administrator rights: the fix runs as the PostgreSQL
  superuser, whose password only Administrators can read (config\pg-superuser.secret).

  It runs a fix only when all of these hold, and otherwise changes nothing:
  - <file.sql>.sig, next to it, is Vyaptek's signature of the file, checked against the public key in
    fix-signing-key.xml (RSA, SHA-256, PKCS#1 v1.5). Its private key is Vyaptek's own, used only for
    fixes, never the license key. backend scripts/sign-box-fix.sh makes the .sig.
  - The file's first line is "-- hms-fix-for: <id>", where <id> is this computer's installation id
    (backend\config\license-activated) or, on a computer without an activated product key, its name.
    So a fix written for one hospital cannot be run at another.
  - This computer has not run this exact file before (fixes-applied.txt keeps their SHA-256).

  The SQL runs in one transaction: all of it, or none. The output goes to support\fix-<time>.log; send
  that file back to Vyaptek.
#>
param(
  [Parameter(Mandatory = $true)][string]$SqlFile,
  [string]$AppDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)
$ErrorActionPreference = 'Stop'

function Fail([string]$why) {
  Write-Host ''
  Write-Host "The fix was NOT run: $why" -ForegroundColor Red
  exit 1
}

$SqlFile = (Resolve-Path $SqlFile).Path
$sigFile = "$SqlFile.sig"
$keyFile = Join-Path $AppDir 'fix-signing-key.xml'
$supportDir = Join-Path $AppDir 'support'
$appliedFile = Join-Path $supportDir 'fixes-applied.txt'
$secretFile = Join-Path $AppDir 'backend\config\pg-superuser.secret'
$psql = Join-Path $AppDir 'pgsql\bin\psql.exe'

if (-not (Test-Path $sigFile)) { Fail "$sigFile is missing. Vyaptek sends it with the fix." }
$keyXml = if (Test-Path $keyFile) { (Get-Content -Raw $keyFile).Trim() } else { '' }
if ($keyXml -notmatch '<Modulus>') { Fail 'this HMS build has no fix signing key.' }

# The signature covers the file's exact bytes, so nothing may be read and re-encoded first.
$bytes = [IO.File]::ReadAllBytes($SqlFile)
try {
  $signature = [Convert]::FromBase64String(((Get-Content -Raw $sigFile) -replace '\s', ''))
} catch {
  Fail "$sigFile is not a signature."
}
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
try {
  $rsa.FromXmlString($keyXml)
  $valid = $rsa.VerifyData($bytes, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
} finally {
  $rsa.Dispose()
}
if (-not $valid) { Fail 'the signature does not match. The file was changed, or it is not from Vyaptek.' }

$text = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
$first = ($text -split "`r?`n", 2)[0].Trim()
if ($first -notmatch '^--\s*hms-fix-for:\s*(\S+)$') { Fail 'its first line does not say which computer it is for.' }
$target = $Matches[1]
$idFile = Join-Path $AppDir 'backend\config\license-activated'
$installId = if (Test-Path $idFile) { (Get-Content -Raw $idFile).Trim() } else { '' }
if ($target -ne $installId -and $target -ne $env:COMPUTERNAME) {
  Fail "it is for $target, and this computer is $(if ($installId) { $installId } else { $env:COMPUTERNAME })."
}

$sha = (Get-FileHash $SqlFile -Algorithm SHA256).Hash.ToLower()
New-Item -ItemType Directory -Force -Path $supportDir | Out-Null
# The logs can hold hospital data (a fix's query output): Administrators and SYSTEM only.
icacls $supportDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "could not protect $supportDir." }
if ((Test-Path $appliedFile) -and (Select-String -Path $appliedFile -SimpleMatch $sha -Quiet)) {
  Fail 'this computer has already run this fix.'
}
if (-not (Test-Path $secretFile)) { Fail "$secretFile is missing. Run the HMS installer again." }

$log = Join-Path $supportDir ('fix-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
"Fix:      $SqlFile`r`nSHA-256:  $sha`r`nComputer: $env:COMPUTERNAME ($installId)`r`nRun by:   $env:USERDOMAIN\$env:USERNAME at $(Get-Date -Format o)`r`n" |
  Set-Content -Path $log -Encoding UTF8
$env:PGPASSWORD = (Get-Content -Raw $secretFile).Trim()
$ErrorActionPreference = 'Continue'
& $psql -h 127.0.0.1 -p 5432 -U postgres -d hospital_erp -w -v ON_ERROR_STOP=1 --single-transaction -f $SqlFile *>> $log
$code = $LASTEXITCODE
Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

if ($code -ne 0) {
  "`r`nFAILED (psql exit code $code). Nothing was changed: the fix runs in one transaction." | Add-Content -Path $log
  & eventcreate /T ERROR /ID 812 /L APPLICATION /SO VyaptekHMS /D "HMS database fix $sha failed; nothing was changed. Log: $log" | Out-Null
  Fail "it stopped with an error, so nothing was changed. Send $log to Vyaptek."
}
"`r`nDONE." | Add-Content -Path $log
Add-Content -Path $appliedFile -Value "$sha $(Get-Date -Format o) $SqlFile"
& eventcreate /T WARNING /ID 811 /L APPLICATION /SO VyaptekHMS /D "HMS database fix $sha was run as the superuser by $env:USERDOMAIN\$env:USERNAME. Log: $log" | Out-Null
Write-Host ''
Write-Host "The fix was run. Send $log to Vyaptek." -ForegroundColor Green
