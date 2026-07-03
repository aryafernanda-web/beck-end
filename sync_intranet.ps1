# Biznet Intranet -> Notion Sync Server
# Parallel processing via RunspacePool (5 threads)

param([switch]$RunSyncJob, [int]$Limit = 0, [string]$Fields = "all")

$port       = 3001
$rootPath   = $PSScriptRoot
$configFile = Join-Path $rootPath "config.json"
$statusFile = Join-Path $rootPath "status.json"

if (Test-Path $configFile) {
    $config = Get-Content $configFile -Raw | ConvertFrom-Json
} else { Write-Error "config.json not found!"; exit }

function Set-Status($cur, $tot, $msg, $type = "info") {
    @{ current=$cur; total=$tot; message=$msg; type=$type; lastUpdate=(Get-Date).ToString("HH:mm:ss") } |
        ConvertTo-Json | Out-File $statusFile -Encoding UTF8
}
Set-Status 0 0 "Server Started" "info"

# -- Paket Cache (Metro & Home terpisah) -------------------------------------
$Global:PaketCacheMetro = $null
$Global:PaketCacheHome  = $null

function Load-SinglePaketCache($dbId, $label) {
    $h = @{ "Authorization"="Bearer $($config.NOTION_API_KEY)"; "Notion-Version"="2022-06-28"; "Content-Type"="application/json" }
    $cache = @{}
    try {
        $hasMore = $true; $cursor = $null
        while ($hasMore) {
            $b = @{}; if ($cursor) { $b.start_cursor = $cursor }
            $d = (Invoke-WebRequest -Uri "https://api.notion.com/v1/databases/$dbId/query" -Method Post -Headers $h -Body ($b|ConvertTo-Json) -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
            foreach ($p in $d.results) {
                $t = ""
                $p.properties.PSObject.Properties | Where-Object { $_.Value.type -eq 'title' } | ForEach-Object {
                    $t = ($_.Value.title | ForEach-Object { $_.plain_text }) -join ""
                }
                $paketId = $p.id.ToString()
                # Pattern 1: "100 Mbps" / "100Mbps" / "100 MBPS"
                if ($t -match '(\d+)\s*[Mm][Bb][Pp][Ss]') { $cache["mbps_$($Matches[1])"] = $paketId }
                # Pattern 1b: "1 Gbps" / "1Gbps" / "1 GBPS"
                elseif ($t -match '(\d+)\s*[Gg][Bb][Pp][Ss]') {
                    $mbpsValue = [int]$Matches[1] * 1000
                    $cache["mbps_$mbpsValue"] = $paketId
                }
                # Pattern 2: "100M" shorthand (tanpa "bps") - tambahan untuk format singkat
                elseif ($t -match '(\d+)\s*[Mm]\b') { $k="mbps_$($Matches[1])"; if(!$cache.ContainsKey($k)){$cache[$k]=$paketId} }
                # Pattern 2b: "1G" shorthand
                elseif ($t -match '(\d+)\s*[Gg]\b') {
                    $mbpsValue = [int]$Matches[1] * 1000
                    $k="mbps_$mbpsValue"
                    if(!$cache.ContainsKey($k)){$cache[$k]=$paketId}
                }
                # Pattern 3: code seperti "10D", "100D"
                if ($t -match '\b([0-9]+D)\b') { $cache["code_$($Matches[1].ToUpper())"] = $paketId }
                # TAMBAHAN: simpan nama normalized agar produk tanpa kecepatan bisa di-match
                # Key: 'name_<NAMA_UPPERCASE_TANPA_SPASI>' -> ID
                if ($t) {
                    $normKey = "name_$($t.ToUpper() -replace '[^A-Z0-9]', '')"
                    if (!$cache.ContainsKey($normKey)) { $cache[$normKey] = $paketId }
                    # Juga simpan kata kunci utama (tiap kata >= 3 huruf)
                    $t.ToUpper() -split '[\s\-_/]+' | Where-Object { $_.Length -ge 3 } | ForEach-Object {
                        $wk = "word_$_"
                        if (!$cache.ContainsKey($wk)) { $cache[$wk] = $paketId }
                        # Juga simpan key 2-char untuk kata pendek (MO, DL, DI, dll)
                        if ($_.Length -ge 2) { $wk2 = "w2_$_"; if (!$cache.ContainsKey($wk2)) { $cache[$wk2] = $paketId } }
                    }
                }
                Write-Host "  [$label] Paket: '$t' -> $paketId" -ForegroundColor DarkGray
            }
            $hasMore = $d.has_more; $cursor = $d.next_cursor
        }
        Write-Host "[$label] Paket cache loaded: $($cache.Count) keys" -ForegroundColor Green
    } catch {
        Write-Host "[$label] Paket cache GAGAL: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $cache
}

function Load-PaketCache {
    if ($Global:PaketCacheMetro -and $Global:PaketCacheHome) { return }
    $metroDbId = if ($config.PAKET_METRO_DB_ID) { $config.PAKET_METRO_DB_ID } else { "2dcdcd14-e2c8-8065-8020-c505daeffd68" }
    $homeDbId  = if ($config.PAKET_HOME_DB_ID)  { $config.PAKET_HOME_DB_ID  } else { "2dcdcd14-e2c8-8065-8020-c505daeffd68" }
    Write-Host "[Cache] Metro DB: $metroDbId" -ForegroundColor Cyan
    Write-Host "[Cache] Home  DB: $homeDbId" -ForegroundColor Cyan
    $Global:PaketCacheMetro = Load-SinglePaketCache $metroDbId "Metro"
    $Global:PaketCacheHome  = Load-SinglePaketCache $homeDbId  "Home"
    # PERINGATAN: Jika kedua DB ID sama, cache Metro == cache Home -> paket Metro TIDAK AKAN bisa di-match dengan benar
    if ($metroDbId -eq $homeDbId) {
        Write-Host "" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "[PERINGATAN KRITIS] PAKET_METRO_DB_ID = PAKET_HOME_DB_ID !" -ForegroundColor Red
        Write-Host "Paket Metro tidak akan bisa di-update ke Notion!" -ForegroundColor Red
        Write-Host "Silakan update config.json dengan ID database Metro yang benar." -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        $warnLine = "[$(Get-Date -f 'HH:mm:ss')] [PERINGATAN] Metro DB ID = Home DB ID ($metroDbId). Cache Metro berisi paket Home. Paket Metro TIDAK akan di-update! Perbaiki PAKET_METRO_DB_ID di config.json."
        Add-Content -Path (Join-Path $rootPath 'sync_errors.log') -Value $warnLine -Encoding UTF8
    }
    # Log sample keys dari masing-masing cache untuk diagnostik
    $metroSample = ($Global:PaketCacheMetro.Keys | Select-Object -First 5) -join ', '
    $homeSample  = ($Global:PaketCacheHome.Keys  | Select-Object -First 5) -join ', '
    Write-Host "[Cache] Metro keys=$($Global:PaketCacheMetro.Count) sample=[$metroSample]" -ForegroundColor DarkCyan
    Write-Host "[Cache]  Home keys=$($Global:PaketCacheHome.Count)  sample=[$homeSample]" -ForegroundColor DarkCyan
}

# -- Worker (runs in each Runspace) -------------------------------------------
$WorkerScript = {
    param($Batch, $ConfigJson, $PaketCacheMetroJson, $PaketCacheHomeJson, $StatusFile, $MutexName, $TotalRecords, $CounterFile, $Fields)

    $cfg   = $ConfigJson | ConvertFrom-Json
    $sFile = $StatusFile
    $mName = $MutexName
    # CATATAN: "phone", "address", dan "name" dihapus dari sync - kolom ini tidak di-update
    $fList = if ($Fields -eq "all") { @("dates","contract_num","billing_num","modem","paket","rx_power","tx_power","suhu","tegangan","arus","device_info","downtime","sales_code","username","password","email","serial_no","status") } else { $Fields.Split(",") }
    # Rebuild pkCacheMetro & pkCacheHome dari JSON string
    $pkCacheMetro = @{}
    $pkCacheHome  = @{}
    try {
        $parsedMetro = $PaketCacheMetroJson | ConvertFrom-Json
        $parsedMetro.PSObject.Properties | ForEach-Object { $pkCacheMetro[$_.Name] = [string]$_.Value }
    } catch {}
    try {
        $parsedHome = $PaketCacheHomeJson | ConvertFrom-Json
        $parsedHome.PSObject.Properties | ForEach-Object { $pkCacheHome[$_.Name] = [string]$_.Value }
    } catch {}

    function StripZ($s) { if (!$s){return $s}; $r=$s.TrimStart('0'); if($r-eq''){'0'}else{$r} }
    function FmtDate($d) {
        if (!$d){return $null}
        try{return([datetime]::Parse($d.Trim())).ToString('yyyy-MM-dd')}catch{}
        try{return([datetime]::ParseExact($d.Trim(),'dd-MMM-yyyy',[cultureinfo]::InvariantCulture)).ToString('yyyy-MM-dd')}catch{}
        try{return([datetime]::ParseExact($d.Trim(),'yyyy-MM-dd',[cultureinfo]::InvariantCulture)).ToString('yyyy-MM-dd')}catch{}
        return $null
    }
    function BuildAlamat($addr) {
        if ($addr.address3 -and $addr.address3.Trim()) { return $addr.address3.Trim() }
        return $null
    }
    function Map-NotionSelect($value, $allowed) {
        if (!$value) { return $null }
        $v = $value.ToString().Trim()
        if ($v -eq '-' -or !$v) { return $null }
        foreach ($opt in $allowed) {
            if ($v -ieq $opt) { return $opt }
        }
        return $null
    }
    function ConvertTo-NotionNumber($val) {
        if (!$val) { return $null }
        $clean = $val.ToString().Trim()
        if ($clean -match '^\d+$') {
            try { return [long]$clean } catch { return $null }
        }
        if ($clean -match '^[-+]?\d*\.?\d+$') {
            try { return [double]$clean } catch { return $null }
        }
        return $null
    }
    # Deteksi apakah produk adalah Metro atau Home berdasarkan nama/kode
    function Detect-PaketType($n) {
        if (!$n) { return 'unknown' }
        $u = $n.ToUpper()
        # Kata kunci metro
        if ($u -match 'METRO|MET|B-ME|MBE|DEDICATED|TRANSIT|LEASED|VPN|IPL|DIA|CORPORATE|CORP|ENTERPRISE') { return 'metro' }
        # Kata kunci home
        if ($u -match 'HOME|HOM|B-HO|HOT|SOHO|PLAY|LITE|GAMER|GAME') { return 'home' }
        return 'unknown'
    }

    function FindPaketInCache($n, $cache) {
        if (!$n -or !$cache -or $cache.Count -eq 0) { return $null }
        $u = $n.ToUpper()
        $matched = $null
        # 1. "100 Mbps" / "100Mbps" / "100 MBPS"
        if ($u -match '(\d+)\s*[Mm][Bb][Pp][Ss]') { $k="mbps_$($Matches[1])"; if($cache.ContainsKey($k)){$matched=$cache[$k]} }
        # 1b. "1 Gbps" / "1Gbps" / "1 GBPS"
        if (!$matched -and $u -match '(\d+)\s*[Gg][Bb][Pp][Ss]') {
            $mbpsValue = [int]$Matches[1] * 1000
            $k="mbps_$mbpsValue"
            if($cache.ContainsKey($k)){$matched=$cache[$k]}
        }
        # 2. "100M" shorthand (tanpa bps)
        if (!$matched -and $u -match '(\d+)\s*M\b') { $k="mbps_$($Matches[1])"; if($cache.ContainsKey($k)){$matched=$cache[$k]} }
        # 2b. "1G" shorthand
        if (!$matched -and $u -match '(\d+)\s*G\b') {
            $mbpsValue = [int]$Matches[1] * 1000
            $k="mbps_$mbpsValue"
            if($cache.ContainsKey($k)){$matched=$cache[$k]}
        }
        # 3. Code "10D"
        if (!$matched -and $u -match '\b([0-9]+D)\b') { $k="code_$($Matches[1])"; if($cache.ContainsKey($k)){$matched=$cache[$k]} }
        if (!$matched -and $u -match '([0-9]+)D\b')   { $k="code_$($Matches[1])D"; if($cache.ContainsKey($k)){$matched=$cache[$k]} }
        # 4. Fallback: cari angka 2-4 digit dan coba sebagai mbps
        if (!$matched -and $u -match '(\d{2,4})') {
            $k="mbps_$($Matches[1])"; if($cache.ContainsKey($k)){$matched=$cache[$k]}
        }
        # 5. TAMBAHAN: Fallback berdasarkan kata kunci nama (4+ karakter)
        if (!$matched) {
            $words = $u -split '[\s\-_/]+' | Where-Object { $_.Length -ge 4 }
            foreach ($w in $words) {
                $wk = "word_$w"
                if ($cache.ContainsKey($wk)) { $matched = $cache[$wk]; break }
            }
        }
        # 6. Fallback lanjutan: kata kunci 3 karakter (cakup produk singkat / Metro tanpa speed)
        if (!$matched) {
            $words3 = $u -split '[\s\-_/]+' | Where-Object { $_.Length -ge 3 }
            foreach ($w in $words3) {
                $wk = "word_$w"
                if ($cache.ContainsKey($wk)) { $matched = $cache[$wk]; break }
            }
        }
        # 7. Last resort: cek seluruh nama produk (normalized) terhadap semua key 'name_' di cache
        if (!$matched) {
            $normFull = "name_$($u -replace '[^A-Z0-9]', '')"
            if ($cache.ContainsKey($normFull)) { $matched = $cache[$normFull] }
        }
        if ($matched) { return $matched.ToString() } else { return $null }
    }

    # FindPaket: return @{ id=UUID; type='metro'|'home' } atau $null
    function FindPaket($n) {
        if (!$n) { return $null }
        $type = Detect-PaketType $n
        # Coba cache sesuai tipe dulu, fallback ke yang lain
        $paketId = $null
        if ($type -eq 'metro') {
            $paketId = FindPaketInCache $n $pkCacheMetro
            if (!$paketId) { $paketId = FindPaketInCache $n $pkCacheHome }
        } elseif ($type -eq 'home') {
            $paketId = FindPaketInCache $n $pkCacheHome
            if (!$paketId) { $paketId = FindPaketInCache $n $pkCacheMetro }
        } else {
            # Tidak diketahui: coba keduanya
            $paketId = FindPaketInCache $n $pkCacheMetro
            if (!$paketId) { $paketId = FindPaketInCache $n $pkCacheHome }
            if ($paketId) {
                # Tentukan tipe dari cache mana yang cocok
                if (FindPaketInCache $n $pkCacheMetro) { $type = 'metro' } else { $type = 'home' }
            }
        }
        if ($paketId -and [string]$paketId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            return @{ id = [string]$paketId; type = $type }
        }
        return $null
    }

    $sess = $null
    try {
        $r1 = Invoke-WebRequest -Uri 'https://intranet2023.biznetnetworks.com/login' -SessionVariable 's' -UseBasicParsing -ErrorAction Stop -TimeoutSec 15
        if ($r1.Content -notmatch 'name="_token" value="([^"]+)"') { throw "No CSRF token" }
        $tok = $Matches[1]
        $lr  = Invoke-WebRequest -Uri 'https://intranet2023.biznetnetworks.com/login-portal' -Method Post `
               -Body @{_token=$tok;username=$cfg.BIZNET_USERNAME;password=$cfg.BIZNET_PASSWORD} `
               -Headers @{'X-Requested-With'='XMLHttpRequest';'Accept'='application/json,text/html,*/*'} `
               -WebSession $s -UseBasicParsing -ErrorAction Stop -TimeoutSec 20
        $loginFailed = $false
        try { $lj=$lr.Content|ConvertFrom-Json; if($lj.success -eq $false -or $lj.status -eq 'error'){ $loginFailed=$true } } catch {}
        if ($loginFailed) { return }
        $sess = $s
    } catch { return }

    foreach ($cust in $Batch) {
        $finalId = if ($cust.id) { $cust.id.ToString().Trim() } else { $null }
        if (!$finalId) { continue }
        $page    = $cust.pageJson | ConvertFrom-Json
        $det     = @{ Contracts=@() }
        
        try {
            $html = (Invoke-WebRequest -Uri "https://intranet2023.biznetnetworks.com/2023/crm/customer-detail/$finalId" -WebSession $sess -UseBasicParsing -ErrorAction Stop -TimeoutSec 20).Content
            if ($html -match '<meta name="csrf-token" content="([^"]+)"') { $det.CSRFToken = $Matches[1] }
            
            # NOTE: phone/address/name TIDAK di-sync (dihapus dari update)
            if ($fList -contains "dates" -and $html -match 'data-expiry-date="([^"]+)"') { $det.ContractEnd = $Matches[1].Trim() }
            if ($fList -contains "dates" -and $html -match 'data-start-date="([^"]+)"')  { $det.ContractStart = $Matches[1].Trim() }
            # Fallback: parse tanggal terminate dari atribut HTML lain
            if ($fList -contains "dates" -and !$det.ContractEnd) {
                if ($html -match 'data-terminate-date="([^"]+)"')   { $det.ContractEnd = $Matches[1].Trim() }
                elseif ($html -match 'data-termination-date="([^"]+)"') { $det.ContractEnd = $Matches[1].Trim() }
                elseif ($html -match 'data-end-date="([^"]+)"')     { $det.ContractEnd = $Matches[1].Trim() }
                elseif ($html -match 'data-contract-end="([^"]+)"') { $det.ContractEnd = $Matches[1].Trim() }
            }

            # Deteksi status Terminate dari HTML intranet
            if ($fList -contains "status") {
                # Cari text/class yang menunjukkan status terminate di halaman customer
                if ($html -match '(?i)(status[^<]{0,80}terminate|terminate[^<]{0,80}status|class="[^"]*terminate[^"]*"|data-status="terminate"|>\s*Terminate\s*<)') {
                    $det.IsTerminate = $true
                }
            }

            # === CONTRACT SELECTION via API (akurat untuk billing number matching) ===
            # PERBAIKAN: Tidak lagi parse HTML tabel (rawan salah). Selalu gunakan API per contract
            # agar billing number yang didapat pasti akurat dan matching ke Notion bisa benar.
            $parsedContracts = @()
            $contractNums = @()
            # Ambil semua contract number unik dari HTML (pattern sederhana, lebih reliable)
            $cmAll = [regex]::Matches($html, 'data-contract-number="([^"]+)"')
            foreach ($m in $cmAll) {
                $cn = $m.Groups[1].Value.Trim()
                if ($cn -and $contractNums -notcontains $cn) { $contractNums += $cn }
            }

            # Untuk setiap contract, ambil detail via API (sumber billing number yang akurat)
            if ($contractNums.Count -gt 0) {
                $aHc = @{'X-CSRF-TOKEN'=$det.CSRFToken;'X-Requested-With'='XMLHttpRequest';'Accept'='application/json';'Content-Type'='application/json'}
                foreach ($contractNum in $contractNums) {
                    $billingNum = $null; $productName = $null; $salesCode = $null; $startDate = $null; $endDate = $null; $contractEmail = $null
                    try {
                        $arc = Invoke-WebRequest -Uri "https://intranet2023.biznetnetworks.com/2023/crm/api/customer/contract-number/$contractNum/details" -Method Post -Headers $aHc -WebSession $sess -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 15
                        if ($arc -and $arc.StatusCode -eq 200) {
                            $dc = ($arc.Content | ConvertFrom-Json).data
                            # Coba berbagai field nama billing number dari API response
                            $bnc = if($dc.billigAcctNumber){$dc.billigAcctNumber}
                                   elseif($dc.billingAcctNum){$dc.billingAcctNum}
                                   elseif($dc.productDetails -and $dc.productDetails.billingAcctNum){$dc.productDetails.billingAcctNum}
                                   elseif($dc.accountNumber){$dc.accountNumber}
                                   else{$null}
                            $billingNum = if($bnc){ $bnc.ToString().Trim() } else { $null }
                            $pd = $dc.productDetails
                            $productName = if($pd -and $pd.productName){$pd.productName.Trim()}
                                           elseif($pd -and $pd.name){$pd.name.Trim()}
                                           elseif($dc.productName){$dc.productName.Trim()}
                                           else{$null}
                            $salesCode = if($dc.salesCode){$dc.salesCode.Trim()}
                                         elseif($dc.sales_code){$dc.sales_code.Trim()}
                                         else{$null}
                            $startDate = if($dc.contractStart){$dc.contractStart}
                                         elseif($dc.contract_start){$dc.contract_start}
                                         elseif($dc.startDate){$dc.startDate}
                                         else{$null}
                            # Coba berbagai field tanggal akhir kontrak (termasuk terminate)
                            $endDate   = if($dc.expiry_date -and $dc.expiry_date -ne '-' -and $dc.expiry_date -ne ''){$dc.expiry_date}
                                         elseif($dc.terminationDate -and $dc.terminationDate -ne '-' -and $dc.terminationDate -ne ''){$dc.terminationDate}
                                         elseif($dc.termination_date -and $dc.termination_date -ne '-' -and $dc.termination_date -ne ''){$dc.termination_date}
                                         elseif($dc.contract_end_date -and $dc.contract_end_date -ne '-' -and $dc.contract_end_date -ne ''){$dc.contract_end_date}
                                         elseif($dc.contractEndDate -and $dc.contractEndDate -ne '-' -and $dc.contractEndDate -ne ''){$dc.contractEndDate}
                                         elseif($dc.end_date -and $dc.end_date -ne '-' -and $dc.end_date -ne ''){$dc.end_date}
                                         elseif($dc.contractEnd -and $dc.contractEnd -ne '-' -and $dc.contractEnd -ne ''){$dc.contractEnd}
                                         else{$null}
                            # Ambil email dari contract API
                            if ($dc.email -and $dc.email.ToString().Trim()) { $contractEmail = $dc.email.ToString().Trim() }
                        }
                    } catch {}
                    $parsedContracts += @{
                        ContractNumber = $contractNum; BillingNumber = $billingNum
                        ProductName    = $productName; SalesCode     = $salesCode
                        StartDate      = $startDate;   EndDate       = $endDate
                        Email          = $contractEmail
                    }
                }
            }

            # Map the parsed contracts to $det.Contracts array for outer scope compatibility if needed
            foreach ($c in $parsedContracts) {
                if ($c.ContractNumber -and $det.Contracts -notcontains $c.ContractNumber) {
                    $det.Contracts += $c.ContractNumber
                }
            }

            if ($parsedContracts.Count -gt 0) {
                # Ambil billing number dari Notion untuk matching
                $notionBillingNum = $null
                try {
                    $bp = $page.properties.'Billing Number'
                    if ($bp -and $bp.rich_text -and $bp.rich_text.Count -gt 0) {
                        $rawNBN = (($bp.rich_text | ForEach-Object { $_.plain_text }) -join '').Trim()
                        if ($rawNBN) { $notionBillingNum = StripZ $rawNBN }
                    }
                } catch {}

                # Match by billing number
                $selectedContract = $null
                if ($notionBillingNum) {
                    foreach ($c in $parsedContracts) {
                        $cleanBnc = if($c.BillingNumber){ StripZ $c.BillingNumber.ToString().Trim() } else { $null }
                        if ($cleanBnc -and $cleanBnc -eq $notionBillingNum) {
                            $selectedContract = $c
                            break
                        }
                    }
                }
                
                # Default: contract pertama
                if (!$selectedContract) {
                    $selectedContract = $parsedContracts[0]
                }
                
                # Populate $det and key variable $pc from selected contract
                $pc = $selectedContract.ContractNumber
                $det.ContractNumber = $selectedContract.ContractNumber
                if ($selectedContract.BillingNumber) { $det.BillingNumber = StripZ $selectedContract.BillingNumber.ToString().Trim() }
                if ($selectedContract.ProductName)   { $det.Paket = $selectedContract.ProductName.Trim() }
                if ($selectedContract.SalesCode)     { $det.SalesCode = $selectedContract.SalesCode.Trim() }
                # StartDate: overwrite hanya jika API punya nilai
                if ($selectedContract.StartDate -and $selectedContract.StartDate.Trim()) { $det.ContractStart = $selectedContract.StartDate.Trim() }
                # EndDate: overwrite hanya jika API punya nilai (jangan hapus nilai HTML yg sudah ada)
                if ($selectedContract.EndDate -and $selectedContract.EndDate.Trim())     { $det.ContractEnd = $selectedContract.EndDate.Trim() }
                # Email customer dari contract API
                if ($fList -contains "email" -and $selectedContract.Email -and $selectedContract.Email.Trim()) { $det.Email = $selectedContract.Email.Trim() }
            # === END SINGLE-PASS CONTRACT SELECTION ===
                # Modem status + NCE device data (RX Power, Device Run Info, Last Downtime)
                # Username, Password, Serial No juga dari modem API
                $needModem  = $fList -contains "modem"
                $needDevice = ($fList -contains "rx_power") -or ($fList -contains "tx_power") -or ($fList -contains "suhu") -or ($fList -contains "tegangan") -or ($fList -contains "arus") -or ($fList -contains "device_info") -or ($fList -contains "downtime")
                $needModemApi = $needModem -or $needDevice -or ($fList -contains "username") -or ($fList -contains "password") -or ($fList -contains "serial_no")
                if ($needModemApi) {
                    try {
                        $mHdr = @{'X-Requested-With'='XMLHttpRequest';'Accept'='application/json'}
                        $mr = Invoke-WebRequest -Uri "https://intranet2023.biznetnetworks.com/2023/crm/api/customer/modem/$pc/simple" -Headers $mHdr -WebSession $sess -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 15
                        if ($mr -and $mr.StatusCode -eq 200) {
                            $mj = $mr.Content | ConvertFrom-Json
                            # Modem status (RENT/BUY)
                            if ($needModem) {
                                $raw = if($mj.status_modem){$mj.status_modem}elseif($mj.modem_status){$mj.modem_status}else{$null}
                                if ($raw) { $ru=$raw.Trim().ToUpper(); $det.ModemStatus=if($ru-eq'RENT'){'RENT'}elseif($ru-eq'BUY'){'BUY'}else{$raw.Trim()} }
                            }
                            # ONT Serial Number (used as NCE payload and saved to Notion)
                            $ontSerial = if($mj.data){$mj.data.ToString().Trim()}else{$null}
                            # Store Serial No to det
                            if ($fList -contains "serial_no" -and $ontSerial) { $det.SerialNo = $ontSerial }
                            # Username & Password dari modem API (bukan HTML - Vue :value binding)
                            if ($fList -contains "username" -and !$det.Username) {
                                $rawUser = if($mj.user){$mj.user}elseif($mj.username){$mj.username}else{$null}
                                if ($rawUser) { $det.Username = ($rawUser -replace '^[^\w\s]+|[^\w\s]+$','').Trim() }
                            }
                            if ($fList -contains "password" -and !$det.Password) {
                                $rawPass = if($mj.password){$mj.password}elseif($mj.pass){$mj.pass}else{$null}
                                if ($rawPass) { $det.Password = $rawPass.Trim() }
                            }
                            # Try NCE info endpoint to get RX Power / Device Run Info / Last Downtime
                            if ($needDevice -and $ontSerial) {
                                try {
                                    $nceH   = @{'Content-Type'='application/json';'X-Requested-With'='XMLHttpRequest';'Accept'='application/json'}
                                    $nceUrl = "https://intranet2023.biznetnetworks.com/2023/crm/api/customer/device/nce/detail/get/$ontSerial"
                                    $nceR   = Invoke-WebRequest -Uri $nceUrl -Method Get -Headers $nceH -WebSession $sess -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 15
                                    if ($nceR -and $nceR.StatusCode -eq 200) {
                                        $nceJ = $nceR.Content | ConvertFrom-Json
                                        $stats = if ($nceJ.data -and $nceJ.data.onus -and $nceJ.data.onus.stats) { $nceJ.data.onus.stats } else { $null }
                                        if ($stats) {
                                            if ($fList -contains "device_info" -and !$det.DeviceInfo) {
                                                $rawDi = if($stats.runstat){$stats.runstat}else{$null}
                                                $det.DeviceInfo = Map-NotionSelect $rawDi @('Up','Down')
                                            }
                                            if ($fList -contains "downtime" -and !$det.DowntimeCause -and $stats.lstdowncause) {
                                                $det.DowntimeCause = Map-NotionSelect $stats.lstdowncause @('Dying-gasp','Software Reset','Reset','Cmd Reboot','ONTDISCONNECT','LOFI','LOSI','--')
                                            }

                                            # === Coba baca Suhu/Tegangan/Arus dari $stats (NCE detail) dulu ===
                                            # Beberapa versi Biznet NCE mengembalikan stats ini di detail endpoint
                                            if ($fList -contains "suhu" -and !$det.Suhu) {
                                                $tempRawD = if($stats.temperature){$stats.temperature}elseif($stats.temp){$stats.temp}elseif($stats.opticstemperature){$stats.opticstemperature}elseif($stats.ont_temperature){$stats.ont_temperature}else{$null}
                                                if ($tempRawD -and $tempRawD.ToString() -ne '-' -and $tempRawD.ToString() -ne '0') {
                                                    try {
                                                        $tv = [double]$tempRawD
                                                        if ([math]::Abs($tv) -ge 1000) { $tv = [math]::Round($tv / 10, 1) } elseif ([math]::Abs($tv) -ge 100) { $tv = [math]::Round($tv / 10, 1) }
                                                        $det.Suhu = "${tv}$([char]0x00B0)C"
                                                    } catch {}
                                                }
                                            }
                                            if ($fList -contains "tegangan" -and !$det.Tegangan) {
                                                $voltRawD = if($stats.voltage){$stats.voltage}elseif($stats.volt){$stats.volt}elseif($stats.supplyvoltage){$stats.supplyvoltage}elseif($stats.supply_voltage){$stats.supply_voltage}else{$null}
                                                if ($voltRawD -and $voltRawD.ToString() -ne '-' -and $voltRawD.ToString() -ne '0') {
                                                    try {
                                                        $vv = [double]$voltRawD
                                                        if ($vv -ge 10000) { $vv = [math]::Round($vv / 10000, 2) } elseif ($vv -ge 100) { $vv = [math]::Round($vv / 100, 2) }
                                                        $det.Tegangan = "${vv} V"
                                                    } catch {}
                                                }
                                            }
                                            if ($fList -contains "arus" -and !$det.Arus) {
                                                $biasRawD = if($stats.bias){$stats.bias}elseif($stats.laserbiascurrent){$stats.laserbiascurrent}elseif($stats.biasCurrent){$stats.biasCurrent}elseif($stats.bias_current){$stats.bias_current}elseif($stats.current){$stats.current}else{$null}
                                                if ($biasRawD -and $biasRawD.ToString() -ne '-' -and $biasRawD.ToString() -ne '0') {
                                                    try {
                                                        $bv = [double]$biasRawD
                                                        # bias current biasanya dalam unit uA dari NCE, dibagi 1000 untuk dapat mA
                                                        if ($bv -ge 10000) { $bv = [math]::Round($bv / 1000, 2) } elseif ($bv -ge 1000) { $bv = [math]::Round($bv / 100, 2) } elseif ($bv -ge 100) { $bv = [math]::Round($bv / 100, 2) }
                                                        $det.Arus = "${bv} mA"
                                                    } catch {}
                                                }
                                            }

                                            $needPowerEndpoint = ($fList -contains "rx_power" -and !$det.RxPower) -or
                                                                 ($fList -contains "tx_power" -and !$det.TxPower) -or
                                                                 ($fList -contains "suhu"     -and !$det.Suhu) -or
                                                                 ($fList -contains "tegangan" -and !$det.Tegangan) -or
                                                                 ($fList -contains "arus"     -and !$det.Arus)
                                            # Fallback: gunakan nama dari onu[0].name jika stats.name kosong/null
                                            $statsNameFallback = $null
                                            if ($stats -and $stats.name) { $statsNameFallback = $stats.name }
                                            elseif ($nceJ -and $nceJ.data -and $nceJ.data.onus -and $nceJ.data.onus.onu -and $nceJ.data.onus.onu.Count -gt 0 -and $nceJ.data.onus.onu[0].name) {
                                                $statsNameFallback = $nceJ.data.onus.onu[0].name
                                            }
                                            if ($needPowerEndpoint -and $statsNameFallback) {
                                                try {
                                                    $nameParts = $statsNameFallback -split '/'
                                                    if ($nameParts.Count -ge 5) {
                                                        $u = @{ index = @{ dev = $nameParts[0]; fn = $nameParts[1] -replace '(?i)Frame', ''; sn = $nameParts[2] -replace '(?i)Slot', ''; pn = $nameParts[3] -replace '(?i)Port', ''; ontid = $nameParts[4] -replace '(?i)OnuID', '' } }
                                                        $payloadEncoded = [System.Web.HttpUtility]::UrlEncode(($u | ConvertTo-Json -Compress))
                                                        $rPower = Invoke-WebRequest -Uri "https://intranet2023.biznetnetworks.com/2023/crm/api/customer/device/nce/power/get?payload=$payloadEncoded" -Headers $nceH -WebSession $sess -UseBasicParsing -ErrorAction SilentlyContinue -TimeoutSec 15
                                                        if ($rPower -and $rPower.StatusCode -eq 200) {
                                                            $powerJson = $rPower.Content | ConvertFrom-Json
                                                            if ($powerJson.data -and $powerJson.data.data -and $powerJson.data.data.Count -gt 0) {
                                                                $pd0 = $powerJson.data.data[0]

                                                                # -- RX Power --
                                                                if ($fList -contains "rx_power" -and !$det.RxPower) {
                                                                    $rxRaw = if($pd0.opticsrxpower){$pd0.opticsrxpower}elseif($pd0.rxpower){$pd0.rxpower}elseif($pd0.rx_power){$pd0.rx_power}else{$null}
                                                                    if ($rxRaw -and $rxRaw.ToString() -ne '-') {
                                                                        try { $det.RxPower = "$([math]::Round([double]$rxRaw / 100, 2)) dBm" } catch {}
                                                                    }
                                                                }

                                                                # -- TX Power --
                                                                if ($fList -contains "tx_power" -and !$det.TxPower) {
                                                                    $txRaw = if($null -ne $pd0.opticstxpower){$pd0.opticstxpower}else{$null}
                                                                    if ($null -ne $txRaw -and $txRaw.ToString() -ne '-') {
                                                                        try { $det.TxPower = "$([math]::Round([double]$txRaw / 100, 2)) dBm" } catch {}
                                                                    }
                                                                }

                                                                # -- Suhu (Temperature) --
                                                                if ($fList -contains "suhu" -and !$det.Suhu) {
                                                                    $tempRaw = if($null -ne $pd0.opticstxtemp){$pd0.opticstxtemp}else{$null}
                                                                    if ($null -ne $tempRaw -and $tempRaw.ToString() -ne '-') {
                                                                        try {
                                                                            $tv2 = [double]$tempRaw
                                                                            # opticstxtemp biasanya dalam 1/256 derajat C dari NCE: perlu dibagi 256
                                                                            # Tapi beberapa device mengembalikan langsung dalam C (nilai <= 100)
                                                                            if ($tv2 -ge 1000) { $tv2 = [math]::Round($tv2 / 256, 1) } elseif ($tv2 -ge 100) { $tv2 = [math]::Round($tv2 / 10, 1) }
                                                                            $det.Suhu = "${tv2}$([char]0x00B0)C"
                                                                        } catch {}
                                                                    }
                                                                }

                                                                # -- Tegangan (Voltage) --
                                                                if ($fList -contains "tegangan" -and !$det.Tegangan) {
                                                                    $voltRaw = if($null -ne $pd0.opticstxvol){$pd0.opticstxvol}else{$null}
                                                                    if ($null -ne $voltRaw -and $voltRaw.ToString() -ne '-') {
                                                                        try { $det.Tegangan = "$([math]::Round([double]$voltRaw / 1000, 2)) V" } catch {}
                                                                    }
                                                                }

                                                                # -- Arus (Bias Current) --
                                                                if ($fList -contains "arus" -and !$det.Arus) {
                                                                    $biasRaw = if($null -ne $pd0.opticstxbiascurr){$pd0.opticstxbiascurr}else{$null}
                                                                    if ($null -ne $biasRaw -and $biasRaw.ToString() -ne '-') {
                                                                        try {
                                                                            $bv2 = [double]$biasRaw
                                                                            # opticstxbiascurr biasanya dalam 2uA, dibagi 1000 untuk mA
                                                                            if ($bv2 -ge 10000) { $bv2 = [math]::Round($bv2 / 1000, 2) } elseif ($bv2 -ge 1000) { $bv2 = [math]::Round($bv2 / 100, 2) }
                                                                            $det.Arus = "$bv2 mA"
                                                                        } catch {}
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                } catch {}
                                            }
                                        }
                                    }
                                } catch {}
                            }
                        }
                    } catch {}
                }
            }
            # HTML fallback untuk billing_num, paket, dan email (BUKAN address - tidak di-sync)
            if($fList -contains "billing_num" -and !$det.BillingNumber -and $html -match 'name="contract-account-number\[\]"[^>]*value="([^"]+)"'){$det.BillingNumber=StripZ $Matches[1].Trim()}
            if($fList -contains "paket" -and !$det.Paket -and $html -match 'name="contract-number-product-name\[\]"[^>]*value="([^"]+)"'){$det.Paket=$Matches[1].Trim()}
            if ($fList -contains "email" -and !$det.Email -and $html -match 'id="customer-email-input"[^>]*value="([^"]+)"') { $det.Email = $Matches[1].Trim() }
        } catch {}

        $nH   = @{'Authorization'="Bearer $($cfg.NOTION_API_KEY)";"Notion-Version"='2022-06-28';'Content-Type'='application/json'}
        $upd  = @{}
        
        # Cek dan cocokkan nama properti di database Notion secara case-insensitive & space-trimmed
        $notionProps = $page.properties.PSObject.Properties.Name
        function Find-NotionPropName {
            param([string]$target)
            foreach ($prop in $notionProps) {
                if ($prop.Trim().ToLower() -eq $target.Trim().ToLower()) {
                    return $prop
                }
            }
            return $null
        }

        $contractStartDateProp = Find-NotionPropName "Contract Strat Date"
        $contractEndDateProp   = Find-NotionPropName "Contract End Date"
        if($fList -contains "dates") {
            $sd=FmtDate $det.ContractStart; $ed=FmtDate $det.ContractEnd
            if($sd -and $contractStartDateProp){$upd[$contractStartDateProp]=@{date=@{start=$sd}}}
            if($ed -and $contractEndDateProp)  {$upd[$contractEndDateProp]  =@{date=@{start=$ed}}}
        }
        
        $contractNumberProp = Find-NotionPropName "Contract Number"
        if($fList -contains "contract_num" -and $det.ContractNumber -and $contractNumberProp){$upd[$contractNumberProp]=@{rich_text=@(@{text=@{content=$det.ContractNumber}})}}
        
        $billingNumberProp = Find-NotionPropName "Billing Number"
        if($fList -contains "billing_num"  -and $det.BillingNumber  -and $billingNumberProp) {$upd[$billingNumberProp] =@{rich_text=@(@{text=@{content=$det.BillingNumber}})}}
        
        # CATATAN: phone (Nomor Telepon) dan address (Alamat) TIDAK di-update - dihapus dari sync
        # CATATAN: Nama Customer TIDAK di-update
        
        $modemProp = Find-NotionPropName "MODEM"
        if($fList -contains "modem" -and $det.ModemStatus -and $modemProp){$upd[$modemProp]=@{select=@{name=$det.ModemStatus}}}
        
        $paketMetroProp = Find-NotionPropName "Paket Metro"
        $paketHomeProp  = Find-NotionPropName "Paket Home"
        if ($fList -contains "paket") {
            $paketResult = $null
            if ($det.Paket)       { $paketResult = FindPaket $det.Paket }
            if (!$paketResult -and $det.ProductCode) { $paketResult = FindPaket $det.ProductCode }
            if ($paketResult) {
                # Metro HANYA update Paket Metro, Home HANYA update Paket Home (dan clear yang sebaliknya)
                if ($paketResult.type -eq 'metro') {
                    if ($paketMetroProp) { $upd[$paketMetroProp] = @{relation=@(@{id=$paketResult.id})} }
                    if ($paketHomeProp)  { $upd[$paketHomeProp]  = @{relation=@()} }
                } elseif ($paketResult.type -eq 'home') {
                    if ($paketHomeProp)  { $upd[$paketHomeProp]  = @{relation=@(@{id=$paketResult.id})} }
                    if ($paketMetroProp) { $upd[$paketMetroProp] = @{relation=@()} }
                } else {
                    # Tipe 'unknown': coba langsung ke cache
                    $unknownPaketName = if ($det.Paket) { $det.Paket } elseif ($det.ProductCode) { $det.ProductCode } else { '' }
                    $tryMetroId = FindPaketInCache $unknownPaketName $pkCacheMetro
                    $tryHomeId  = FindPaketInCache $unknownPaketName $pkCacheHome
                    if ($tryMetroId -and $paketMetroProp) {
                        $upd[$paketMetroProp] = @{relation=@(@{id=$tryMetroId})}
                        if ($paketHomeProp) { $upd[$paketHomeProp] = @{relation=@()} }
                    } elseif ($tryHomeId -and $paketHomeProp) {
                        $upd[$paketHomeProp] = @{relation=@(@{id=$tryHomeId})}
                        if ($paketMetroProp) { $upd[$paketMetroProp] = @{relation=@()} }
                    } else {
                        # Debug: log paket yang tidak bisa di-match ke cache
                        $logDir2 = [System.IO.Path]::GetDirectoryName($sFile)
                        $sampleKeys = ($pkCacheMetro.Keys | Select-Object -First 10) -join ', '
                        $dbgLine = "[$(Get-Date -f 'HH:mm:ss')] PAKET_NOMATCH id=$finalId paket='$($det.Paket)' code='$($det.ProductCode)' type='$($paketResult.type)' cacheKeys=$($pkCacheMetro.Count) sampleKeys=[$sampleKeys]"
                        Add-Content -Path (Join-Path $logDir2 'sync_errors.log') -Value $dbgLine -Encoding UTF8
                    }
                }
            } elseif ($det.Paket -or $det.ProductCode) {
                # FindPaket gagal total - log untuk debug dengan sample key Metro & Home
                $logDir3 = [System.IO.Path]::GetDirectoryName($sFile)
                $sampleMetro = ($pkCacheMetro.Keys | Select-Object -First 8) -join ', '
                $sampleHome  = ($pkCacheHome.Keys  | Select-Object -First 8) -join ', '
                $dbgLine2 = "[$(Get-Date -f 'HH:mm:ss')] PAKET_NOTFOUND id=$finalId paket='$($det.Paket)' code='$($det.ProductCode)' metroCacheKeys=$($pkCacheMetro.Count) homeCacheKeys=$($pkCacheHome.Count) metroSample=[$sampleMetro] homeSample=[$sampleHome]"
                Add-Content -Path (Join-Path $logDir3 'sync_errors.log') -Value $dbgLine2 -Encoding UTF8
            }
        }
        
        # Update Status: HANYA jika status di intranet adalah Terminate
        $statusProp = Find-NotionPropName "Status"
        if ($fList -contains "status" -and $det.IsTerminate -eq $true -and $statusProp) {
            # Cek tipe kolom Status di Notion: bisa 'status' (tipe khusus Notion) atau 'select'
            $statusPropType = ''
            try { $statusPropType = $page.properties.$statusProp.type } catch {}
            # Cari nama opsi Terminate yang valid di Notion (bisa beda: 'Terminate', 'Terminated', dll)
            $terminateNames = @('Terminate', 'Terminated', 'TERMINATE', 'terminate', 'terminated')
            $foundTerminateName = $null
            try {
                $existingOptions = @()
                if ($statusPropType -eq 'status') {
                    # Tipe 'status' Notion: options ada di $page.properties.$statusProp.status.options
                    # atau di groups[].option_ids. Coba kedua cara.
                    $statusObj = $page.properties.$statusProp.status
                    if ($statusObj -and $statusObj.groups) {
                        $statusObj.groups | ForEach-Object {
                            if ($_.options) {
                                $_.options | ForEach-Object { if ($_.name) { $existingOptions += $_.name } }
                            }
                        }
                    }
                    # Fallback: jika options ada di level database config (bukan page)
                    # Jika tidak ada options sama sekali, gunakan nama default tanpa verifikasi
                } elseif ($statusPropType -eq 'select') {
                    # Untuk tipe 'select', opsi available ada di database schema,
                    # bukan di page response. Di page response hanya ada nilai terpilih saat ini.
                    # Kita tidak bisa enumerate options dari page saja - skip verifikasi.
                    $existingOptions = $terminateNames  # anggap semua valid
                }
                foreach ($tn in $terminateNames) {
                    if ($existingOptions -icontains $tn) { $foundTerminateName = $tn; break }
                }
            } catch {}
            # Jika tidak ketemu dari Notion page, gunakan nilai yang ada di properti saat ini sebagai referensi nama
            if (!$foundTerminateName) {
                # Coba ambil nama value saat ini dari properti status/select
                try {
                    if ($statusPropType -eq 'status' -and $page.properties.$statusProp.status.name) {
                        # Ada nilai saat ini - berarti database punya kolom status yang valid, gunakan 'Terminate'
                        $foundTerminateName = 'Terminate'
                    } elseif ($statusPropType -eq 'select' -and $page.properties.$statusProp.select) {
                        $foundTerminateName = 'Terminate'
                    } else {
                        # Kolom ada tapi tidak bisa verifikasi - skip update Status untuk menghindari 400 error
                        $foundTerminateName = $null
                    }
                } catch { $foundTerminateName = $null }
            }
            if ($foundTerminateName) {
                if ($statusPropType -eq 'status') {
                    $upd[$statusProp] = @{status=@{name=$foundTerminateName}}
                } else {
                    $upd[$statusProp] = @{select=@{name=$foundTerminateName}}
                }
            }
        }
        
        # Sales Code
        $salesCodeProp = Find-NotionPropName "Sales Code"
        if ($fList -contains "sales_code" -and $det.SalesCode -and $salesCodeProp) {
            $upd[$salesCodeProp] = @{rich_text=@(@{text=@{content=$det.SalesCode}})}
        }
        
        # Username customer - deteksi tipe properti Notion (number atau rich_text) otomatis
        $usernameProp = Find-NotionPropName "Username"
        if ($fList -contains "username" -and $det.Username -and $usernameProp) {
            $userPropType = if ($page.properties.$usernameProp) { $page.properties.$usernameProp.type } else { 'number' }
            if ($userPropType -eq 'number') {
                $numUser = ConvertTo-NotionNumber $det.Username
                if ($null -ne $numUser) { $upd[$usernameProp] = @{number=$numUser} }
            } else {
                $upd[$usernameProp] = @{rich_text=@(@{text=@{content=$det.Username.ToString()}})}
            }
        }
        
        # Password customer - deteksi tipe properti Notion (number atau rich_text) otomatis
        $passwordProp = Find-NotionPropName "Pasword"
        if (!$passwordProp) { $passwordProp = Find-NotionPropName "Password" }
        if ($fList -contains "password" -and $det.Password -and $passwordProp) {
            $passPropType = if ($page.properties.$passwordProp) { $page.properties.$passwordProp.type } else { 'number' }
            if ($passPropType -eq 'number') {
                $numPass = ConvertTo-NotionNumber $det.Password
                if ($null -ne $numPass) { $upd[$passwordProp] = @{number=$numPass} }
            } else {
                $upd[$passwordProp] = @{rich_text=@(@{text=@{content=$det.Password.ToString()}})}
            }
        }
        
        $rxPowerProp = Find-NotionPropName "RX Power"
        if($fList -contains "rx_power"  -and $det.RxPower   -and $rxPowerProp)  {$upd[$rxPowerProp]  =@{rich_text=@(@{text=@{content=$det.RxPower}})}}
        
        $txPowerProp = Find-NotionPropName "TX Power"
        if($fList -contains "tx_power"  -and $det.TxPower   -and $txPowerProp)  {$upd[$txPowerProp]  =@{rich_text=@(@{text=@{content=$det.TxPower}})}}
        
        $suhuProp = Find-NotionPropName "Suhu"
        if($fList -contains "suhu"      -and $det.Suhu      -and $suhuProp)      {$upd[$suhuProp]      =@{rich_text=@(@{text=@{content=$det.Suhu}})}}
        
        $teganganProp = Find-NotionPropName "Tegangan"
        if($fList -contains "tegangan"  -and $det.Tegangan  -and $teganganProp)  {$upd[$teganganProp]  =@{rich_text=@(@{text=@{content=$det.Tegangan}})}}
        
        $arusProp = Find-NotionPropName "Arus"
        if($fList -contains "arus"      -and $det.Arus      -and $arusProp)      {$upd[$arusProp]      =@{rich_text=@(@{text=@{content=$det.Arus}})}}
        
        $deviceInfoProp = Find-NotionPropName "Device Run Info"
        if($fList -contains "device_info" -and $det.DeviceInfo   -and $deviceInfoProp)    {$upd[$deviceInfoProp]    =@{select=@{name=$det.DeviceInfo}}}
        
        $downtimeProp = Find-NotionPropName "Last Downtime Cause"
        if($fList -contains "downtime"    -and $det.DowntimeCause -and $downtimeProp){$upd[$downtimeProp]=@{select=@{name=$det.DowntimeCause}}}
        
        # Serial No. (ONT Serial Number from modem API)
        $serialNoProp = Find-NotionPropName "Serial No."
        if($fList -contains "serial_no"   -and $det.SerialNo      -and $serialNoProp)        {$upd[$serialNoProp]         =@{rich_text=@(@{text=@{content=$det.SerialNo}})}}

        # Email customer
        $emailNotionProp = Find-NotionPropName "Email"
        if ($fList -contains "email" -and $det.Email -and $emailNotionProp) {
            $upd[$emailNotionProp] = @{rich_text=@(@{text=@{content=$det.Email}})}
        }

        $result = 'skipped'
        if ($upd.Count -gt 0) {
            $patchBody = @{properties=$upd} | ConvertTo-Json -Depth 20
            $pageUri   = "https://api.notion.com/v1/pages/$($page.id)"
            $maxRetry  = 3
            $retryOk   = $false
            for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
                try {
                    Invoke-WebRequest -Uri $pageUri -Method Patch -Headers $nH -Body $patchBody -UseBasicParsing -ErrorAction Stop -TimeoutSec 30 | Out-Null
                    $result   = 'updated'
                    $retryOk  = $true
                    break
                } catch {
                    $errMsg  = $_.Exception.Message
                    $errCode = ''
                    try { $errCode = [int]$_.Exception.Response.StatusCode } catch {}
                    # Retry hanya untuk 429 (Rate Limit) dan 5xx (Server Error)
                    if ($attempt -lt $maxRetry -and ($errCode -eq 429 -or $errCode -ge 500 -or $errMsg -match '(429|5\d{2}|timeout|timed out|Gateway)')) {
                        $wait = $attempt * 3   # 3s, 6s
                        Start-Sleep -Seconds $wait
                        continue
                    }
                    # Semua retry gagal atau error non-retriable
                    $result  = 'error'
                    $errBody = ''
                    try {
                        # Metode 1: baca via WebException.Response stream
                        if ($_.Exception.Response) {
                            $stream  = $_.Exception.Response.GetResponseStream()
                            $reader  = New-Object System.IO.StreamReader($stream)
                            $errBody = $reader.ReadToEnd()
                            $reader.Close(); $stream.Dispose()
                        }
                    } catch {}
                    if (!$errBody) {
                        try {
                            # Metode 2: baca via ErrorDetails jika ada
                            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errBody = $_.ErrorDetails.Message }
                        } catch {}
                    }
                    if (!$errBody) { $errBody = "(body kosong/tidak terbaca - err: $($_.Exception.GetType().Name))" }
                    $logDir  = [System.IO.Path]::GetDirectoryName($sFile)
                    $logLine = "[$(Get-Date -f 'HH:mm:ss')] ERROR id=$finalId page=$($page.id) attempt=$attempt`nerr=$errMsg`nbody=$errBody`nupd=$($patchBody | Out-String)"
                    Add-Content -Path (Join-Path $logDir 'sync_errors.log') -Value $logLine -Encoding UTF8

                    # Fallback: coba update satu field sekaligus untuk isolasi field yang bermasalah
                    $fallbackUpdated = 0
                    foreach ($fieldKey in @($upd.Keys)) {
                        $fbSuccess = $false
                        for ($fa = 1; $fa -le 2; $fa++) {
                            try {
                                $singleBody = @{properties=@{$fieldKey=$upd[$fieldKey]}} | ConvertTo-Json -Depth 20
                                Invoke-WebRequest -Uri $pageUri -Method Patch -Headers $nH -Body $singleBody -UseBasicParsing -ErrorAction Stop -TimeoutSec 25 | Out-Null
                                $fallbackUpdated++; $fbSuccess = $true; break
                            } catch {
                                $fbErr  = $_.Exception.Message
                                $fbCode = ''
                                try { $fbCode = [int]$_.Exception.Response.StatusCode } catch {}
                                if ($fa -lt 2 -and ($fbCode -eq 429 -or $fbCode -ge 500 -or $fbErr -match '(429|5\d{2}|timeout|timed out|Gateway)')) {
                                    Start-Sleep -Seconds 3; continue
                                }
                                $fbBody = ''
                                try {
                                    if ($_.Exception.Response) {
                                        $fbStream = $_.Exception.Response.GetResponseStream()
                                        $fbReader = New-Object System.IO.StreamReader($fbStream)
                                        $fbBody   = $fbReader.ReadToEnd()
                                        $fbReader.Close(); $fbStream.Dispose()
                                    }
                                } catch {}
                                if (!$fbBody) { try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $fbBody = $_.ErrorDetails.Message } } catch {} }
                                if (!$fbBody) { $fbBody = "(tidak terbaca)" }
                                $fbLine = "[$(Get-Date -f 'HH:mm:ss')] FIELD_ERROR id=$finalId field='$fieldKey' err=$fbErr body=$fbBody"
                                Add-Content -Path (Join-Path $logDir 'sync_errors.log') -Value $fbLine -Encoding UTF8
                            }
                        }
                    }
                    if ($fallbackUpdated -gt 0) { $result = 'updated' }
                    break
                }
            }
        }

        $mtx = [System.Threading.Mutex]::OpenExisting($mName)
        try {
            $mtx.WaitOne() | Out-Null
            # Baca counter saat ini dari file
            $ctr = @{ Completed=0; Updated=0; Skipped=0; Errors=0 }
            try { if (Test-Path $CounterFile) { $fc = Get-Content $CounterFile -Raw | ConvertFrom-Json; $ctr = @{ Completed=[int]$fc.Completed; Updated=[int]$fc.Updated; Skipped=[int]$fc.Skipped; Errors=[int]$fc.Errors } } } catch {}
            $ctr.Completed++
            if ($result -eq 'updated') { $ctr.Updated++ }
            elseif ($result -eq 'error') { $ctr.Errors++ }
            else { $ctr.Skipped++ }
            $ctr | ConvertTo-Json -Compress | Out-File $CounterFile -Encoding UTF8
            @{ current=$ctr.Completed; total=$TotalRecords; message="Syncing... ($($ctr.Completed) / $TotalRecords)"; type="warning"; lastUpdate=(Get-Date).ToString("HH:mm:ss") } | ConvertTo-Json | Out-File $sFile -Encoding UTF8
        } finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
    }
}

# -- Main Sync ----------------------------------------------------------------
$MaxThreads = 10
function Start-Sync($Limit = 0, $Fields = "all") {
    Set-Status 0 0 "Fetching Notion data..." "warning"
    Load-PaketCache
    try {
        $h = @{"Authorization"="Bearer $($config.NOTION_API_KEY)";"Notion-Version"="2022-06-28";"Content-Type"="application/json"}
        $results=@(); $hasMore=$true; $cursor=$null
        while ($hasMore) {
            $b=@{ filter = @{ property = "ID Costumer"; url = @{ is_not_empty = $true } } }
            if($cursor){$b.start_cursor=$cursor}
            $data=(Invoke-WebRequest -Uri "https://api.notion.com/v1/databases/$($config.NOTION_DATABASE_ID)/query" -Method Post -Headers $h -Body ($b|ConvertTo-Json -Depth 5) -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content|ConvertFrom-Json
            if($data.results){$results+=$data.results}
            $hasMore=$data.has_more; $cursor=$data.next_cursor
        }
        $customers=@($results)
        if($Limit -gt 0 -and $customers.Count -gt $Limit){$customers=$customers[0..($Limit-1)]}
        $N=$customers.Count
        if ($N -eq 0){Set-Status 0 0 "No records found." "warning";return}
        Set-Status 0 $N "Starting parallel sync: $N records..."

        $mName = "BiznetSync_$(Get-Random)"
        $mutex = New-Object System.Threading.Mutex($false, $mName)
        $pkMetroJson = if($Global:PaketCacheMetro -and $Global:PaketCacheMetro.Count -gt 0){$Global:PaketCacheMetro|ConvertTo-Json -Compress}else{'{}'}
        $pkHomeJson  = if($Global:PaketCacheHome  -and $Global:PaketCacheHome.Count  -gt 0){$Global:PaketCacheHome |ConvertTo-Json -Compress}else{'{}'}
        $cfgJson     = $config | ConvertTo-Json -Compress
        # Counter file - hanya berisi int primitives, diupdate worker via mutex
        $counterFile = Join-Path $rootPath "sync_counter_$($mName -replace 'BiznetSync_','').json"
        '{"Completed":0,"Updated":0,"Skipped":0,"Errors":0}' | Out-File $counterFile -Encoding UTF8

        $batchSize = [Math]::Ceiling($N / $MaxThreads); $batches = New-Object 'System.Collections.Generic.List[Object]'
        for ($i = 0; $i -lt $N; $i += $batchSize) {
            $end = [Math]::Min($i + $batchSize - 1, $N - 1); $slice = $customers[$i..$end]; $batchData = New-Object 'System.Collections.Generic.List[Object]'
            foreach ($page in $slice) {
                $cid = if ($page.properties.'ID Costumer'.url) { $page.properties.'ID Costumer'.url.ToString().Trim() } else { $null }
                if ($cid) {
                    $fid = if($cid -match '/(\d+)$'){$Matches[1]}else{$cid}
                    $batchData.Add(@{ id=$fid; pageJson=($page | ConvertTo-Json -Depth 10 -Compress) })
                }
            }
            $batches.Add($batchData)
        }

        $pool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads); $pool.Open()
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($batch in $batches) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            # Pass ONLY plain serializable types (string, int, List[Object] of hashtables with strings)
            $ps.AddScript($WorkerScript)          | Out-Null
            $ps.AddArgument($batch)               | Out-Null  # List - contains @{id=string;pageJson=string}
            $ps.AddArgument([string]$cfgJson)     | Out-Null
            $ps.AddArgument([string]$pkMetroJson) | Out-Null
            $ps.AddArgument([string]$pkHomeJson)  | Out-Null
            $ps.AddArgument([string]$statusFile)  | Out-Null
            $ps.AddArgument([string]$mName)       | Out-Null
            $ps.AddArgument([int]$N)              | Out-Null
            $ps.AddArgument([string]$counterFile) | Out-Null
            $ps.AddArgument([string]$Fields)      | Out-Null
            $jobs.Add(@{PS=$ps;Handle=$ps.BeginInvoke()})
        }
        while ($jobs|Where-Object{-not $_.Handle.IsCompleted}) { Start-Sleep -Milliseconds 800 }
        foreach($j in $jobs){
            try {
                $j.PS.EndInvoke($j.Handle) | Out-Null
            } catch {
                Write-Host "Worker Job Error: $($_.Exception.Message)" -ForegroundColor Red
                Add-Content -Path (Join-Path $rootPath 'sync_errors.log') -Value "[$(Get-Date -f 'HH:mm:ss')] WORKER_JOB_ERROR: $($_.Exception.Message)" -Encoding UTF8
            }
            if ($j.PS.Streams.Error.Count -gt 0) {
                foreach ($err in $j.PS.Streams.Error) {
                    Write-Host "Worker Stream Error: $($err.Exception.Message)" -ForegroundColor Red
                    Add-Content -Path (Join-Path $rootPath 'sync_errors.log') -Value "[$(Get-Date -f 'HH:mm:ss')] WORKER_STREAM_ERROR: $($err.Exception.Message)" -Encoding UTF8
                }
            }
            $j.PS.Dispose()
        }
        $pool.Close(); $pool.Dispose(); $mutex.Close()

        # Baca final counter dari file
        $finalCtr = @{ Updated=0; Skipped=0; Errors=0 }
        try { if (Test-Path $counterFile) { $fc = Get-Content $counterFile -Raw | ConvertFrom-Json; $finalCtr = @{ Updated=[int]$fc.Updated; Skipped=[int]$fc.Skipped; Errors=[int]$fc.Errors } } } catch {}
        try { Remove-Item $counterFile -Force -ErrorAction SilentlyContinue } catch {}
        $msg = "Sync Complete: Updated=$($finalCtr.Updated) Skipped=$($finalCtr.Skipped) Errors=$($finalCtr.Errors)"
        Set-Status $N $N $msg "success"
    } catch { Set-Status 0 0 "Sync Error: $($_.Exception.Message)" "error" }
}

if ($RunSyncJob) { Start-Sync -Limit $Limit -Fields $Fields; exit }

# -- HTTP Server --------------------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "--- BIZNET SYNC SERVER ON PORT $port ---" -ForegroundColor Yellow

try {
    while ($listener.IsListening) {
        $ctx = $null; try { $ctx = $listener.GetContext() } catch { continue }
        $req = $ctx.Request; $res = $ctx.Response
        try {
            $res.AddHeader("Access-Control-Allow-Origin", "*"); $res.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS"); $res.AddHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
            if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode = 200; $res.OutputStream.Close(); continue }
            $path = $req.Url.LocalPath; $exp = $config.SECRET_TOKEN; $ah = $req.Headers["Authorization"]
            $tokenOk = (-not $exp) -or ($ah -and ($ah -replace "^Bearer\s+","") -eq $exp)

            function Write-Json($obj, $code=200) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
                $res.StatusCode = $code; $res.ContentType = "application/json"; $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            }

            if ($path -eq "/" -or $path -notlike "/api/*") {
                $f = if ($path -eq "/") { "index.html" } else { $path.TrimStart("/") }; $fp = Join-Path $rootPath $f
                if (Test-Path $fp) {
                    $bytes = [System.IO.File]::ReadAllBytes($fp); $ext = [System.IO.Path]::GetExtension($fp).ToLower()
                    $res.ContentType = switch ($ext) { ".html" { "text/html" } ".css" { "text/css" } ".js" { "application/javascript" } default { "application/octet-stream" } }
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else { $res.StatusCode = 404 }
            } elseif ($path -eq "/api/ping") { Write-Json @{ alive = $true }
            } elseif ($path -eq "/api/status") {
                if (-not $tokenOk) { Write-Json @{ error = "Unauthorized" } 401 }
                else {
                    $raw = if (Test-Path $statusFile) { Get-Content $statusFile -Raw -Encoding UTF8 } else { '{"message":"Ready"}' }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
                    $res.ContentType = "application/json"; $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } elseif ($path -eq "/api/sync") {
                if (-not $tokenOk) { Write-Json @{ error = "Unauthorized" } 401 }
                else {
                    $rawBody = (New-Object System.IO.StreamReader($req.InputStream)).ReadToEnd(); $nc = $null
                    if ($rawBody.Trim()) { try { $nc = $rawBody | ConvertFrom-Json } catch {} }
                    $fArg = if ($nc -and $nc.fields) { $nc.fields -join "," } else { "all" }
                    Start-Process powershell -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -File `"$rootPath\sync_intranet.ps1`" -RunSyncJob -Fields `"$fArg`""
                    Write-Json @{ status = "Sync Started" }
                }
            } elseif ($path -eq "/api/cache-info") {
                if (-not $tokenOk) { Write-Json @{ error = "Unauthorized" } 401 }
                else {
                    $metroDbId = if ($config.PAKET_METRO_DB_ID) { $config.PAKET_METRO_DB_ID } else { "(not set)" }
                    $homeDbId  = if ($config.PAKET_HOME_DB_ID)  { $config.PAKET_HOME_DB_ID  } else { "(not set)" }
                    $metroKeys = if ($Global:PaketCacheMetro) { $Global:PaketCacheMetro.Count } else { 0 }
                    $homeKeys  = if ($Global:PaketCacheHome)  { $Global:PaketCacheHome.Count  } else { 0 }
                    $metroSample = if ($Global:PaketCacheMetro) { ($Global:PaketCacheMetro.Keys | Select-Object -First 10) -join ', ' } else { '(cache kosong)' }
                    $homeSample  = if ($Global:PaketCacheHome)  { ($Global:PaketCacheHome.Keys  | Select-Object -First 10) -join ', ' } else { '(cache kosong)' }
                    $sameDb = ($metroDbId -eq $homeDbId)
                    Write-Json @{
                        warning         = if ($sameDb) { 'Metro DB ID = Home DB ID! Paket Metro tidak bisa di-match. Update PAKET_METRO_DB_ID di config.json.' } else { $null }
                        metro_db_id     = $metroDbId
                        home_db_id      = $homeDbId
                        same_db         = $sameDb
                        metro_cache_keys = $metroKeys
                        home_cache_keys  = $homeKeys
                        metro_sample    = $metroSample
                        home_sample     = $homeSample
                    }
                }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" } finally { try { $res.OutputStream.Close() } catch {} }
    }
} finally { $listener.Stop() }
