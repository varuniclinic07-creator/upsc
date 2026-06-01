# ===========================================================
#  Kiro Gateway - Auto Fix  (IAM Identity Center, us-east-1)
#  Non-technical friendly. PowerShell mein ek baar chalao.
# ===========================================================
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)   # BOM ke bina (Python ke liye zaroori)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---- Gateway folder ----
$gatewayDir = 'C:\Users\DR-VARUNI\Documents\kiro-gateway'
if (Test-Path (Join-Path (Get-Location) 'main.py')) { $gatewayDir = (Get-Location).Path }
if (-not (Test-Path (Join-Path $gatewayDir 'main.py'))) {
    Write-Host "[X] kiro-gateway folder nahi mila: $gatewayDir" -ForegroundColor Red
    Write-Host '    Pehle ye chalao, phir script dobara: cd "C:\Users\DR-VARUNI\Documents\kiro-gateway"' -ForegroundColor Yellow
    return
}
Write-Host "[*] Gateway: $gatewayDir" -ForegroundColor Cyan

# ---- 1) AWS SSO cache se credentials dhoondho ----
$cacheDir = Join-Path $env:USERPROFILE '.aws\sso\cache'
$token = $null; $reg = $null; $combo = $null
if (Test-Path $cacheDir) {
    foreach ($f in Get-ChildItem "$cacheDir\*.json" -ErrorAction SilentlyContinue) {
        try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($j.refreshToken -and $j.clientId -and $j.clientSecret) { $combo = $j }
        if ($j.refreshToken -and -not $token) { $token = $j }
        if ($j.clientId -and $j.clientSecret -and -not $reg) { $reg = $j }
    }
}
if ($combo) { $token = $combo; $reg = $combo }
$haveSso = ($token.refreshToken -and $reg.clientId -and $reg.clientSecret)

$newKey = $null

# ---- 2) Route choose karo ----
if ($haveSso) {
    Write-Host "[*] SSO cache mein creds mil gaye (clientId + clientSecret + refreshToken)." -ForegroundColor Green
    $credsOut = Join-Path $gatewayDir 'kiro-creds.json'
    $obj = [ordered]@{
        accessToken  = [string]$token.accessToken
        refreshToken = [string]$token.refreshToken
        expiresAt    = [string]$token.expiresAt
        region       = 'us-east-1'
        clientId     = [string]$reg.clientId
        clientSecret = [string]$reg.clientSecret
    }
    Write-Utf8NoBom $credsOut ($obj | ConvertTo-Json)
    Write-Host "[*] kiro-creds.json bana diya." -ForegroundColor Green
    $envSet = [ordered]@{ 'KIRO_CREDS_FILE' = $credsOut; 'KIRO_REGION' = 'us-east-1' }
    $envRemove = @('REFRESH_TOKEN','KIRO_CLI_DB_FILE','KIRO_CREDS_FILE','KIRO_REGION')
}
else {
    # kiro-cli SQLite DB fallback (IAM Identity Center ka native source)
    $dbCandidates = @(
        (Join-Path $env:USERPROFILE '.local\share\kiro-cli\data.sqlite3'),
        (Join-Path $env:APPDATA   'kiro-cli\data.sqlite3'),
        (Join-Path $env:LOCALAPPDATA 'kiro-cli\data.sqlite3')
    )
    $db = $dbCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($db) {
        Write-Host "[*] kiro-cli DB mila: $db" -ForegroundColor Green
        $envSet = [ordered]@{ 'KIRO_CLI_DB_FILE' = $db; 'KIRO_REGION' = 'us-east-1' }
        $envRemove = @('REFRESH_TOKEN','KIRO_CREDS_FILE','KIRO_CLI_DB_FILE','KIRO_REGION')
    }
    else {
        Write-Host "[X] clientId/clientSecret kahin nahi mile (IAM Identity Center ke liye ye zaroori hain)." -ForegroundColor Red
        Write-Host "    SSO cache files ke field-NAAM (values/secrets NAHI):" -ForegroundColor Yellow
        if (Test-Path $cacheDir) {
            foreach ($f in Get-ChildItem "$cacheDir\*.json" -ErrorAction SilentlyContinue) {
                try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
                Write-Host ("    - {0}: {1}" -f $f.Name, (($j.PSObject.Properties.Name) -join ', '))
            }
        } else { Write-Host "    ($cacheDir maujood hi nahi -> Kiro mein dobara login karo)" -ForegroundColor Yellow }
        Write-Host "    Upar wali list (sirf naam, koi secret nahi) mujhe bhej do." -ForegroundColor Yellow
        return
    }
}

# ---- 3) .env update (BOM ke bina, backup ke saath) ----
$envFile = Join-Path $gatewayDir '.env'
$lines = @()
if (Test-Path $envFile) {
    Copy-Item $envFile "$envFile.bak" -Force
    foreach ($ln in Get-Content $envFile) {
        $skip = $false
        foreach ($k in $envRemove) { if ($ln -match ("^\s*{0}\s*=" -f $k)) { $skip = $true; break } }
        if (-not $skip) { $lines += $ln }
    }
}
if (-not ($lines | Where-Object { $_ -match '^\s*PROXY_API_KEY\s*=\s*\S' })) {
    $newKey = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | ForEach-Object {[char]$_})
    $lines += "PROXY_API_KEY=$newKey"
}
foreach ($k in $envSet.Keys) { $lines += ("{0}={1}" -f $k, $envSet[$k]) }
Write-Utf8NoBom $envFile (($lines -join "`r`n") + "`r`n")
Write-Host "[*] .env update ho gaya. (Backup: .env.bak)" -ForegroundColor Green
if ($newKey) { Write-Host "[*] Naya PROXY_API_KEY: $newKey   <-- apne client/app mein yahi daalna" -ForegroundColor Magenta }

# ---- 4) Purani cached state hatao (backup ke saath) ----
foreach ($p in @('state.json','credentials.json')) {
    $sp = Join-Path $gatewayDir $p
    if (Test-Path $sp) { Move-Item $sp "$sp.old" -Force; Write-Host "[*] $p -> $p.old (purani state hata di)" -ForegroundColor Green }
}

# ---- 5) Server start ----
Write-Host "`n=== Sab set! Server start ho raha hai... Log mein 'AWS SSO OIDC' dikhna chahiye, 401 nahi. ===`n" -ForegroundColor Cyan
Start-Sleep -Seconds 2
Set-Location $gatewayDir
python main.py
