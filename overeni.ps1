# Overeni Modulu 0 - SRV1-DC, SRV2-FS, PC1-WIN (podle _vysledek.md)
# Spusteni (jako Administrator):  powershell -ExecutionPolicy Bypass -File C:\overeni.ps1
# Stroj se pozna podle hostname. Pokud jeste neni prejmenovany,
# prepis radek nize rucne, napr.  $Stroj = 'PC1-WIN'

$Stroj = $env:COMPUTERNAME.ToUpper()

$Ocekavano = @{
    'SRV1-DC' = @{ Typ = 'Server'; Edice = 'ServerDatacenter'; Disk = 100; Extra = 0; IP = '192.168.200.10'; DNS = '192.168.200.10' }
    'SRV2-FS' = @{ Typ = 'Server'; Edice = 'ServerDatacenter'; Disk = 100; Extra = 5; IP = '192.168.200.20'; DNS = '192.168.200.10' }
    'PC1-WIN' = @{ Typ = 'Client'; Edice = 'EducationN';       Disk = 60;  Extra = 0; IP = $null;            DNS = $null }
}
$Brana = '192.168.200.1'

# ---------- pomocne funkce ----------
$script:Vysledky = @()
function Zapis($Bod, $Stav, $Text) {
    $script:Vysledky += [pscustomobject]@{ Bod = $Bod; Stav = $Stav; Detail = $Text }
    $barva = @{ OK = 'Green'; CHYBA = 'Red'; POZOR = 'Yellow' }[$Stav]
    Write-Host ("[{0,-5}] {1,-30} {2}" -f $Stav, $Bod, $Text) -ForegroundColor $barva
}
function Over($Bod, $Podminka, $Text, [switch]$JenPozor) {
    if ($Podminka)     { Zapis $Bod 'OK' $Text }
    elseif ($JenPozor) { Zapis $Bod 'POZOR' $Text }
    else               { Zapis $Bod 'CHYBA' $Text }
}
function Reg($Cesta, $Nazev) {
    (Get-ItemProperty -Path $Cesta -Name $Nazev -ErrorAction SilentlyContinue).$Nazev
}

# ---------- kontrola spusteni ----------
$jeAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $jeAdmin) { Write-Host 'Spust PowerShell jako Administrator (Run as administrator)!' -ForegroundColor Red; return }

if (-not $Ocekavano.ContainsKey($Stroj)) {
    Write-Host "Hostname je '$Stroj' - to neni SRV1-DC, SRV2-FS ani PC1-WIN." -ForegroundColor Red
    Write-Host "Prejmenuj stroj, nebo na zacatku skriptu nastav `$Stroj rucne." -ForegroundColor Red
    return
}
$E = $Ocekavano[$Stroj]
Write-Host "`n===== Overeni stroje $Stroj =====`n" -ForegroundColor Cyan

# ---------- 1. Parametry VM ----------
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = $cs.NumberOfLogicalProcessors
$ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
Over '1 vCPU' ($cpu -eq 2) "$cpu (ocekavano 2)"
Over '1 RAM' ($ram -ge 7.5 -and $ram -le 8.5) "$ram GB (ocekavano 8)"

$disky = Get-Disk
$sys   = $disky | Where-Object IsBoot | Select-Object -First 1
$sysGB = [math]::Round($sys.Size / 1GB)
Over '1 Systemovy disk' ([math]::Abs($sysGB - $E.Disk) -le 2) "$sysGB GB (ocekavano $($E.Disk))"
$male = @($disky | Where-Object { -not $_.IsBoot -and $_.Size -gt 9GB -and $_.Size -lt 11GB })
Over '1 Dalsi disky 10 GB' ($male.Count -eq $E.Extra) "$($male.Count) (ocekavano $($E.Extra))"
if ($E.Extra -gt 0) {
    $raw = @($male | Where-Object PartitionStyle -eq 'RAW').Count
    Over '1 Disky neinicializovane' ($raw -eq $E.Extra) "$raw z $($male.Count) ve stavu RAW"
}

# ---------- 2. Edice ----------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$os = Get-CimInstance Win32_OperatingSystem
Over '2 Edice' ($cv.EditionID -eq $E.Edice) "$($os.Caption) (EditionID = $($cv.EditionID))"
if ($E.Typ -eq 'Server') {
    Over '2 Desktop Experience' ($cv.InstallationType -eq 'Server') "InstallationType = $($cv.InstallationType) (Server = s GUI)"
}

# ---------- 3. Hostname ----------
Over '3 Hostname' ($env:COMPUTERNAME -eq $Stroj) "hostname = $env:COMPUTERNAME"

# ---------- 4. Sit ----------
$ipv4 = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'Loopback*' }
if ($E.IP) {
    $lan = $ipv4 | Where-Object IPAddress -eq $E.IP | Select-Object -First 1
    if (-not $lan) {
        Zapis '4 IP adresa' 'CHYBA' "adresa $($E.IP) neni nastavena na zadnem adapteru"
    } else {
        Over '4 IP adresa' $true "$($E.IP) na adapteru '$($lan.InterfaceAlias)'"
        Over '4 Maska' ($lan.PrefixLength -eq 24) "/$($lan.PrefixLength) (ocekavano /24 = 255.255.255.0)"
        Over '4 Staticka adresa' ($lan.PrefixOrigin -eq 'Manual') "PrefixOrigin = $($lan.PrefixOrigin)"
        $gw = @((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $lan.InterfaceIndex -ErrorAction SilentlyContinue).NextHop)
        $gwText = if ($gw) { $gw -join ', ' } else { '(zadna)' }
        Over '4 Vychozi brana' ($gw -contains $Brana) "na LAN = $gwText (prazdna je OK, dokud jede internet pres NIC1)" -JenPozor
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $lan.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
        Over '4 DNS' ($dns.Count -gt 0 -and $dns[0] -eq $E.DNS) "DNS = $($dns -join ', ') (ocekavano $($E.DNS))"
    }
} else {
    $manual = @($ipv4 | Where-Object PrefixOrigin -eq 'Manual')
    $txt = if ($manual) { "staticke adresy: $($manual.IPAddress -join ', ')" } else { 'zadna staticka adresa, vse automaticky' }
    Over '4 IP pres DHCP' ($manual.Count -eq 0) $txt
}

# ---------- 5 + 12. Ucty ----------
$admin = Get-LocalUser | Where-Object { $_.SID -like '*-500' }
Over '5 Administrator aktivni' ($admin.Name -eq 'Administrator' -and $admin.Enabled) "$($admin.Name), Enabled = $($admin.Enabled)"
$ms = @(Get-LocalUser | Where-Object PrincipalSource -eq 'MicrosoftAccount')
Over '5 Zadny Microsoft ucet' ($ms.Count -eq 0) $(if ($ms) { $ms.Name -join ', ' } else { 'jen lokalni ucty' })
$jini = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.SID -notlike '*-500' })
Over '5 Zadny jiny aktivni ucet' ($jini.Count -eq 0) $(if ($jini) { $jini.Name -join ', ' } else { 'jen Administrator' })
if ($E.Typ -eq 'Client') {
    $zbytky = @(Get-LocalUser | Where-Object { $_.Name -in 'Setup', 'defaultuser0' })
    Over '12 Docasne ucty smazane' ($zbytky.Count -eq 0) $(if ($zbytky) { $zbytky.Name -join ', ' } else { 'Setup ani defaultuser0 neexistuji' })
    $prof = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -notmatch '\\Administrator(\..+)?$' })
    Over '12 Zadne cizi profily' ($prof.Count -eq 0) $(if ($prof) { $prof.LocalPath -join ', ' } else { 'jen profil Administrator' })
}

# ---------- 6. Jazyk a region ----------
$ui = (Get-UICulture).Name
Over '6 Jazyk rozhrani' ($ui -eq 'en-US') "UI = $ui (ocekavano en-US)"
$cul = Get-Culture
Over '6 Region format' ($cul.Name -eq 'cs-CZ') "Culture = $($cul.Name)"
$sl = (Get-WinSystemLocale).Name
Over '6 System locale' ($sl -eq 'cs-CZ') "System locale = $sl"
$geo = Get-WinHomeLocation
Over '6 Home location' ($geo.GeoId -eq 75) "$($geo.HomeLocation) (GeoId $($geo.GeoId), ocekavano 75)"

# ---------- 7. Formaty ----------
$df = $cul.DateTimeFormat
Over '7 Format data' ($df.ShortDatePattern -eq 'd.M.yyyy') "$($df.ShortDatePattern) -> $((Get-Date).ToString('d')) (ocekavano d.M.yyyy)"
Over '7 Format casu' ($df.LongTimePattern -eq 'H:mm:ss') "$($df.LongTimePattern) -> $((Get-Date).ToString('T')) (ocekavano H:mm:ss)"
Over '7 Mena' ($cul.NumberFormat.CurrencySymbol -eq "K$([char]0x10D)") "$((12345.67).ToString('C'))"

# ---------- 8. Casove pasmo ----------
$tz = Get-TimeZone
Over '8 Casove pasmo' ($tz.Id -eq 'Central Europe Standard Time') "$($tz.Id) / $($tz.DisplayName)"

# ---------- 9. Klavesnice ----------
$ll = Get-WinUserLanguageList
$prvni = $ll[0]
Over '9 Vychozi US' ($prvni.LanguageTag -eq 'en-US' -and $prvni.InputMethodTips -contains '0409:00000409') "prvni v seznamu: $($prvni.LanguageTag) $($prvni.InputMethodTips -join ',')"
$cz = $ll | Where-Object LanguageTag -eq 'cs-CZ'
Over '9 Ceska QWERTZ' ($cz -and $cz.InputMethodTips -contains '0405:00000405') $(if ($cz) { "cs-CZ $($cz.InputMethodTips -join ',')" } else { 'cs-CZ chybi v seznamu jazyku' })

# ---------- 10. Soukromi ----------
$p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$v = Reg "$p\DataCollection" 'AllowTelemetry'
Over '10 Telemetrie Required' ($v -eq 1) "AllowTelemetry = $v (ocekavano 1)"
$v = Reg "$p\LocationAndSensors" 'DisableLocation'
Over '10 Poloha vypnuta' ($v -eq 1) "DisableLocation = $v (ocekavano 1)"
$v = Reg "$p\AdvertisingInfo" 'DisabledByGroupPolicy'
Over '10 Reklamni ID vypnuto' ($v -eq 1) "DisabledByGroupPolicy = $v (ocekavano 1)"
$v = Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\InkingAndTypingPersonalization' 'Value'
Over '10 Inking & typing' ($v -eq 0) "Value = $v (0 = vypnuto; kdyz prazdne, over v Settings)" -JenPozor
$v = Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled'
Over '10 Tailored experiences' ($v -eq 0) "hodnota = $v (0 = vypnuto; kdyz prazdne, over v Settings)" -JenPozor
if ($E.Typ -eq 'Client') {
    $f1 = Reg 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice'
    $f2 = Reg 'HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues' 'LocationSyncEnabled'
    Over '10 Find My Device' ($f1 -eq 0 -or $f2 -eq 0) "policy = $f1, LocationSyncEnabled = $f2 (kdyz prazdne, over v Settings)" -JenPozor
}

# ---------- 11. Aktivace ----------
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
    Select-Object -First 1
$stavy = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOBGrace'; 3 = 'OOTGrace'; 4 = 'NonGenuineGrace'; 5 = 'Notification'; 6 = 'ExtendedGrace' }
if ($lic) {
    Over '11 Aktivace' ($lic.LicenseStatus -eq 1) "$($stavy[[int]$lic.LicenseStatus]) ($($lic.Name))"
} else {
    Zapis '11 Aktivace' 'CHYBA' 'neni zadany zadny produktovy klic'
}

# ---------- shrnuti ----------
$ch = @($script:Vysledky | Where-Object Stav -eq 'CHYBA').Count
$po = @($script:Vysledky | Where-Object Stav -eq 'POZOR').Count
$barva = if ($ch) { 'Red' } elseif ($po) { 'Yellow' } else { 'Green' }
Write-Host "`n===== $Stroj : $ch chyb, $po upozorneni =====" -ForegroundColor $barva
Write-Host 'Rucne jeste over: prihlaseni Administrator / Pa55w.rd a prepinani ENG/CZE (Win + mezernik) s psanim r u e s hackem/carkou.' -ForegroundColor Cyan
