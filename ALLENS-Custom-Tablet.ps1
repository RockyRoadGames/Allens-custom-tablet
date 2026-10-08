$ErrorActionPreference = 'Stop'

$script:AppName = 'ALLENS Custom Tablet'
$script:AppVersion = '1.2.1'
$script:Repo = 'RockyRoadGames/Allens-custom-tablet'
$script:ManifestUrl = "https://raw.githubusercontent.com/$($script:Repo)/main/update.json"
$script:DataRoot = Join-Path $env:USERPROFILE 'YQ10S'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:BackupRoot = Join-Path $script:DataRoot 'backups'
New-Item -ItemType Directory -Force -Path $script:LogRoot,$script:BackupRoot | Out-Null
$script:LogFile = Join-Path $script:LogRoot 'customizer.log'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'),$Message
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    if ($script:LogBox) { $script:LogBox.AppendText($line + [Environment]::NewLine) }
}

function Get-AdbPath {
    $local = Join-Path (Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'platform-tools') 'adb.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'adb.exe was not found.'
}

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]]$AdbArgs,[switch]$AllowFailure)
    $adb = Get-AdbPath
    $output = & $adb @AdbArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) { throw ('ADB failed ({0}): {1}' -f $code,($output -join ' ')) }
    [pscustomobject]@{ Code=$code; Output=($output -join [Environment]::NewLine) }
}

function Get-TabletConnection {
    try {
        $r = Invoke-Adb @('get-state')
        if ($r.Code -eq 0 -and $r.Output.Trim() -eq 'device') { return @('device') }
        return @()
    } catch { return @() }
}

function Require-Tablet {
    if ((Get-TabletConnection).Count -ne 1) { throw 'Connect exactly one authorized Android tablet by USB.' }
}

function Device-Status {
    Require-Tablet
    $model = (Invoke-Adb @('shell','getprop','ro.product.model')).Output.Trim()
    $android = (Invoke-Adb @('shell','getprop','ro.build.version.release')).Output.Trim()
    $battery = (Invoke-Adb @('shell','dumpsys','battery')).Output
    $level = if ($battery -match 'level:[ ]*([0-9]+)') { $matches[1] } else { '?' }
    $mem = (Invoke-Adb @('shell','cat','/proc/meminfo')).Output
    $free = if ($mem -match 'MemAvailable:[ ]*([0-9]+)[ ]*kB') { [math]::Round(([double]$matches[1])/1024) } else { '?' }
    $vb = (Invoke-Adb @('shell','getprop','ro.boot.verifiedbootstate')).Output.Trim()
    $locked = (Invoke-Adb @('shell','getprop','ro.boot.flash.locked')).Output.Trim()
    Write-Log "Device: $model / Android $android"
    Write-Log "Battery: $level% | Available RAM: $free MB"
    Write-Log "Verified Boot: $vb | Boot locked: $locked"
}

function Backup {
    Require-Tablet
    $dir = Join-Path $script:BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    (Invoke-Adb @('shell','getprop')).Output | Set-Content (Join-Path $dir 'getprop.txt') -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','global')).Output | Set-Content (Join-Path $dir 'settings-global.txt') -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','secure')).Output | Set-Content (Join-Path $dir 'settings-secure.txt') -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','system')).Output | Set-Content (Join-Path $dir 'settings-system.txt') -Encoding UTF8
    (Invoke-Adb @('shell','pm','list','packages')).Output | Set-Content (Join-Path $dir 'packages.txt') -Encoding UTF8
    (Invoke-Adb @('shell','dumpsys','battery')).Output | Set-Content (Join-Path $dir 'battery.txt') -Encoding UTF8
    Write-Log "Backup saved: $dir"
}

function Safe-Tune {
    Backup
    Require-Tablet
    $adb = Get-AdbPath
    & $adb shell settings --user 0 put global window_animation_scale 0
    & $adb shell settings --user 0 put global transition_animation_scale 0
    & $adb shell settings --user 0 put global animator_duration_scale 0
    & $adb shell settings --user 0 put system screen_off_timeout 600000
    & $adb shell settings --user 0 put system status_bar_show_battery_percent 1
    Invoke-Adb @('shell','cmd','uimode','night','yes') -AllowFailure | Out-Null
    Invoke-Adb @('shell','cmd','package','set-home-activity','--user','0','com.android.launcher3/com.android.searchlauncher.SearchLauncher') -AllowFailure | Out-Null
    Invoke-Adb @('shell','input','keyevent','KEYCODE_HOME') -AllowFailure | Out-Null
    Write-Log 'Safe UI tune applied.'
}

function Privacy-Center {
    Require-Tablet
    $dns = (Invoke-Adb @('shell','settings','--user','0','get','global','private_dns_mode') -AllowFailure).Output.Trim()
    $specifier = (Invoke-Adb @('shell','settings','--user','0','get','global','private_dns_specifier') -AllowFailure).Output.Trim()
    $vpn = (Invoke-Adb @('shell','settings','--user','0','get','secure','always_on_vpn_app') -AllowFailure).Output.Trim()
    Write-Log "Private DNS: $dns | provider: $specifier | Always-on VPN: $vpn"
    Invoke-Adb @('shell','am','start','-a','android.settings.PRIVACY_SETTINGS') -AllowFailure | Out-Null
}

function Open-SettingsPage {
    param([string]$Action)
    Require-Tablet
    Invoke-Adb @('shell','am','start','-a',$Action) -AllowFailure | Out-Null
}

function Gaming-Prep {
    param([string]$PackageName)
    Require-Tablet
    $allowed = @('com.kiloo.subwaysurf','com.roblox.client','com.ea.game.pvzfree_row','com.fingersoft.hcr2','com.robtopx.geometryjumplite','com.innersloth.spacemafia')
    if ($allowed -notcontains $PackageName) { throw 'Game is not in the approved list.' }
    $background = @('com.instagram.android','com.snapchat.android','com.pinterest','com.alibaba.aliexpresshd','com.netflix.mediaclient','com.google.android.apps.tachyon','com.Garawell.BridgeRace','com.fungames.sniper3d','com.block.juggle','com.youmusic.magictiles','block.app.wars','com.fungames.blockcraft','com.nordcurrent.canteenhd')
    $count = 0
    foreach ($pkg in $background) {
        $path = (Invoke-Adb @('shell','pm','path',$pkg) -AllowFailure).Output.Trim()
        if ($path) { Invoke-Adb @('shell','am','force-stop',$pkg) -AllowFailure | Out-Null; $count++ }
    }
    $modes = (Invoke-Adb @('shell','cmd','game','list-modes',$PackageName) -AllowFailure).Output.Trim()
    Write-Log "Gaming prep: $PackageName"
    Write-Log "Game modes: $modes"
    Write-Log "Stopped $count optional background apps."
    Invoke-Adb @('shell','monkey','-p',$PackageName,'-c','android.intent.category.LAUNCHER','1') -AllowFailure | Out-Null
    Write-Log 'Launch requested.'
}


function Save-SettingBackup {
    param([string]$Scope,[string]$Name)
    $dir = Join-Path $script:BackupRoot ('setting-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $value = (Invoke-Adb @('shell','settings','--user','0','get',$Scope,$Name)).Output.Trim()
    Set-Content -LiteralPath (Join-Path $dir "$Scope-$Name.txt") -Value $value -Encoding UTF8
    return $dir
}

function Customize-Home {
    Open-SettingsPage 'android.settings.HOME_SETTINGS'
}

function Customize-Wallpaper {
    Open-SettingsPage 'android.settings.WALLPAPER_SETTINGS'
}

function Customize-Display {
    Open-SettingsPage 'android.settings.DISPLAY_SETTINGS'
}

function Customize-Sound {
    Open-SettingsPage 'android.settings.SOUND_SETTINGS'
}

function Customize-HomeLayout {
    Open-SettingsPage 'android.settings.HOME_SETTINGS'
}

function Set-DarkMode {
    Require-Tablet
    Invoke-Adb @('shell','cmd','uimode','night','yes') | Out-Null
    Write-Log 'Dark mode enabled.'
}

function Set-LightMode {
    Require-Tablet
    Invoke-Adb @('shell','cmd','uimode','night','no') | Out-Null
    Write-Log 'Light mode enabled.'
}

function Set-ThreeButtonNav {
    Require-Tablet
    $dir = Save-SettingBackup 'secure' 'navigation_mode'
    $result = Invoke-Adb @('shell','settings','--user','0','put','secure','navigation_mode','0') -AllowFailure
    if ($result.Code -eq 0) { Write-Log '3-button navigation requested.' } else { Write-Log '3-button navigation was not accepted by this firmware.' }
    Write-Log "Navigation backup: $dir"
}

function Set-GestureNav {
    Require-Tablet
    $dir = Save-SettingBackup 'secure' 'navigation_mode'
    $result = Invoke-Adb @('shell','settings','--user','0','put','secure','navigation_mode','2') -AllowFailure
    if ($result.Code -eq 0) { Write-Log 'Gesture navigation requested.' } else { Write-Log 'Gesture navigation was not accepted by this firmware.' }
    Write-Log "Navigation backup: $dir"
}

function Set-FontScale {
    param([string]$Value)
    Require-Tablet
    $dir = Save-SettingBackup 'system' 'font_scale'
    $result = Invoke-Adb @('shell','settings','--user','0','put','system','font_scale',$Value) -AllowFailure
    if ($result.Code -eq 0) { Write-Log "Font scale set to $Value." } else { Write-Log "Font scale change was not accepted." }
    Write-Log "Font backup: $dir"
}

function Set-Timeout {
    param([int]$Milliseconds)
    Require-Tablet
    $dir = Save-SettingBackup 'system' 'screen_off_timeout'
    $result = Invoke-Adb @('shell','settings','--user','0','put','system','screen_off_timeout',[string]$Milliseconds) -AllowFailure
    if ($result.Code -eq 0) { Write-Log "Screen timeout set to $([math]::Round($Milliseconds/60000,0)) minutes." } else { Write-Log 'Screen timeout change was not accepted.' }
    Write-Log "Timeout backup: $dir"
}

function Set-AutoRotate {
    Require-Tablet
    $result = Invoke-Adb @('shell','settings','--user','0','put','system','accelerometer_rotation','1') -AllowFailure
    if ($result.Code -eq 0) { Write-Log 'Auto-rotate enabled.' } else { Write-Log 'Auto-rotate change was not accepted.' }
}

function LaunchApp {
    param([string]$PackageName)
    Require-Tablet
    Invoke-Adb @('shell','monkey','-p',$PackageName,'-c','android.intent.category.LAUNCHER','1') -AllowFailure | Out-Null
    Write-Log "Launch requested: $PackageName"
}


function Privacy-Audit {
    Require-Tablet
    $dnsMode = (Invoke-Adb @('shell','settings','get','global','private_dns_mode') -AllowFailure).Output.Trim()
    $dnsDefault = (Invoke-Adb @('shell','settings','get','global','private_dns_default_mode') -AllowFailure).Output.Trim()
    $dnsSpecifier = (Invoke-Adb @('shell','settings','get','global','private_dns_specifier') -AllowFailure).Output.Trim()
    $vpn = (Invoke-Adb @('shell','settings','--user','0','get','secure','always_on_vpn_app') -AllowFailure).Output.Trim()
    $location = (Invoke-Adb @('shell','settings','--user','0','get','secure','location_mode') -AllowFailure).Output.Trim()
    $adbEnabled = (Invoke-Adb @('shell','settings','get','global','adb_enabled') -AllowFailure).Output.Trim()
    $wifiScan = (Invoke-Adb @('shell','settings','get','global','wifi_scan_always_enabled') -AllowFailure).Output.Trim()
    $bleScan = (Invoke-Adb @('shell','settings','get','global','ble_scan_always_enabled') -AllowFailure).Output.Trim()

    $dnsLabel = switch ($dnsMode.ToLowerInvariant()) {
        'opportunistic' { 'Automatic/Opportunistic' }
        'hostname' { 'Private provider' }
        'off' { 'Off' }
        default { if ($dnsDefault) { "Default ($dnsDefault)" } else { 'Not explicitly configured / firmware default' } }
    }
    $locationLabel = switch ($location) {
        '0' { 'OFF' }
        '1' { 'ON (legacy sensors-only value)' }
        '2' { 'ON (legacy battery-saving value)' }
        '3' { 'ON (legacy high-accuracy value)' }
        default { 'Unknown / not exposed' }
    }

    Write-Log '=== PRIVACY AUDIT ==='
    Write-Log "Private DNS: $dnsLabel | explicit mode=$dnsMode | default=$dnsDefault | provider=$dnsSpecifier"
    Write-Log "Always-on VPN app: $(if ($vpn) { $vpn } else { 'none configured' })"
    Write-Log "Location: $locationLabel"
    Write-Log "ADB/USB debugging: $(if ($adbEnabled -eq '1') { 'ON (expected while using this tool)' } else { 'OFF' })"
    Write-Log "Wi-Fi scanning always available: $(if ($wifiScan) { $wifiScan } else { '0 / not explicitly enabled' })"
    Write-Log "BLE scanning always available: $(if ($bleScan) { $bleScan } else { '0 / not explicitly enabled' })"
    Write-Log 'Privacy audit complete.'
}

function Set-PrivateDnsAutomatic {
    Require-Tablet
    $dir = Join-Path $script:BackupRoot ('privacy-dns-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($name in @('private_dns_mode','private_dns_specifier')) {
        (Invoke-Adb @('shell','settings','--user','0','get','global',$name) -AllowFailure).Output.Trim() |
            Set-Content -LiteralPath (Join-Path $dir "global-$name.txt") -Encoding UTF8
    }
    $result = Invoke-Adb @('shell','settings','--user','0','put','global','private_dns_mode','opportunistic') -AllowFailure
    if ($result.Code -eq 0) {
        Write-Log 'Private DNS set to Automatic/Opportunistic.'
    } else {
        Write-Log 'Private DNS change was not accepted by this firmware.'
    }
    Write-Log "Private DNS backup: $dir"
}

function Set-PrivateDnsOff {
    Require-Tablet
    $result = Invoke-Adb @('shell','settings','--user','0','put','global','private_dns_mode','off') -AllowFailure
    if ($result.Code -eq 0) { Write-Log 'Private DNS disabled.' } else { Write-Log 'Private DNS change was not accepted by this firmware.' }
}

function Performance-Audit {
    Require-Tablet
    $battery = (Invoke-Adb @('shell','dumpsys','battery') -AllowFailure).Output
    $level = if ($battery -match 'level:[ ]*([0-9]+)') { $matches[1] } else { '?' }
    $tempRaw = if ($battery -match 'temperature:[ ]*([0-9]+)') { [int]$matches[1] } else { -1 }
    $temp = if ($tempRaw -ge 0) { '{0:N1} C' -f ($tempRaw / 10.0) } else { '?' }
    $mem = (Invoke-Adb @('shell','cat','/proc/meminfo') -AllowFailure).Output
    $avail = if ($mem -match 'MemAvailable:[ ]*([0-9]+)[ ]*kB') { [math]::Round(([double]$matches[1])/1024) } else { '?' }
    $swapTotal = if ($mem -match 'SwapTotal:[ ]*([0-9]+)[ ]*kB') { [math]::Round(([double]$matches[1])/1024) } else { '?' }
    $swapFree = if ($mem -match 'SwapFree:[ ]*([0-9]+)[ ]*kB') { [math]::Round(([double]$matches[1])/1024) } else { '?' }
    $zramSize = (Invoke-Adb @('shell','cat','/sys/block/zram0/disksize') -AllowFailure).Output.Trim()
    $zramMb = if ($zramSize -match '^[0-9]+

function Safe-Cache-Cleanup {
    Require-Tablet
    Write-Log 'Safe cache cleanup started (user data is not cleared).'
    $result = Invoke-Adb @('shell','pm','trim-caches','8589934592') -AllowFailure
    if ($result.Code -eq 0) { Write-Log 'Safe cache cleanup completed.' } else { Write-Log "Cache cleanup could not be completed: $($result.Output)" }
}

function Disable-BatterySaver {
    Require-Tablet
    $before = (Invoke-Adb @('shell','settings','get','global','low_power') -AllowFailure).Output.Trim()
    $result = Invoke-Adb @('shell','settings','put','global','low_power','0') -AllowFailure
    if ($result.Code -eq 0) { Write-Log "Battery Saver forced off (was: $before)." } else { Write-Log 'Battery Saver setting was not accepted.' }
}

function Stop-OptionalBackground {
    Require-Tablet
    $background = @(
        'com.instagram.android',
        'com.snapchat.android',
        'com.pinterest',
        'com.alibaba.aliexpresshd',
        'com.netflix.mediaclient',
        'com.google.android.apps.tachyon',
        'com.Garawell.BridgeRace',
        'com.fungames.sniper3d',
        'com.block.juggle',
        'com.youmusic.magictiles',
        'block.app.wars',
        'com.fungames.blockcraft',
        'com.nordcurrent.canteenhd'
    )
    $count = 0
    foreach ($pkg in $background) {
        $path = (Invoke-Adb @('shell','pm','path',$pkg) -AllowFailure).Output.Trim()
        if ($path) {
            Invoke-Adb @('shell','am','force-stop',$pkg) -AllowFailure | Out-Null
            $count++
        }
    }
    Write-Log "Stopped $count optional background apps."
}

function Check-Update {
    try {
        $m = Invoke-RestMethod -Uri $script:ManifestUrl -TimeoutSec 8 -Headers @{ 'User-Agent' = "$($script:AppName)/$($script:AppVersion)" }
        if ([version]$m.version -gt [version]$script:AppVersion) { Write-Log "Update available: $($m.version)" }
        else { Write-Log "Customizer is up to date ($($script:AppVersion))." }
    } catch { Write-Log "Update channel unavailable: $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.Size = New-Object System.Drawing.Size(900,650)
$form.StartPosition = 'CenterScreen'
$title = New-Object System.Windows.Forms.Label
$title.Text = 'ALLENS CUSTOM TABLET'
$title.Font = New-Object System.Drawing.Font('Segoe UI',20,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24,18)
$form.Controls.Add($title)
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Location = New-Object System.Drawing.Point(24,62)
$panel.Size = New-Object System.Drawing.Size(840,130)
$panel.WrapContents = $true
$panel.AutoScroll = $true
$form.Controls.Add($panel)

function Add-ActionButton {
    param([string]$Text,[scriptblock]$Action)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size(185,42)
    $localAction = $Action
    $button.Add_Click({
        try { & $localAction }
        catch {
            Write-Log "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,$script:AppName) | Out-Null
        }
    }.GetNewClosure())
    $panel.Controls.Add($button)
}


Add-ActionButton 'Wallpaper' { Customize-Wallpaper }
Add-ActionButton 'Home Settings' { Customize-Home }
Add-ActionButton 'Display Settings' { Customize-Display }
Add-ActionButton 'Sound Settings' { Customize-Sound }
Add-ActionButton 'Dark Mode' { Set-DarkMode }
Add-ActionButton 'Light Mode' { Set-LightMode }
Add-ActionButton '3-Button Nav' { Set-ThreeButtonNav }
Add-ActionButton 'Gesture Nav' { Set-GestureNav }
Add-ActionButton 'Small Text' { Set-FontScale '0.9' }
Add-ActionButton 'Normal Text' { Set-FontScale '1.0' }
Add-ActionButton 'Large Text' { Set-FontScale '1.15' }
Add-ActionButton '5-Min Timeout' { Set-Timeout 300000 }
Add-ActionButton '10-Min Timeout' { Set-Timeout 600000 }
Add-ActionButton '30-Min Timeout' { Set-Timeout 1800000 }
Add-ActionButton 'Auto-Rotate' { Set-AutoRotate }
Add-ActionButton 'Launch YouTube' { LaunchApp 'com.google.android.youtube' }
Add-ActionButton 'Launch Photo Vault' { LaunchApp 'com.asurion.android.mediabackup.vault.cricket' }

Add-ActionButton 'Privacy Audit' { Privacy-Audit }
Add-ActionButton 'Private DNS Automatic' { Set-PrivateDnsAutomatic }
Add-ActionButton 'Private DNS Off' { Set-PrivateDnsOff }
Add-ActionButton 'VPN Settings' { Open-SettingsPage 'android.settings.VPN_SETTINGS' }
Add-ActionButton 'App Permissions' { Invoke-Adb @('shell','am','start','-a','android.intent.action.MANAGE_APP_PERMISSIONS') -AllowFailure | Out-Null }
Add-ActionButton 'Performance Audit' { Performance-Audit }
Add-ActionButton 'Safe Cache Cleanup' { Safe-Cache-Cleanup }
Add-ActionButton 'Battery Saver Off' { Disable-BatterySaver }
Add-ActionButton 'Stop Optional Background' { Stop-OptionalBackground }

Add-ActionButton 'Device Status' { Device-Status }
Add-ActionButton 'Safe Tune' { Safe-Tune }
Add-ActionButton 'Privacy Center' { Privacy-Center }
Add-ActionButton 'Backup' { Backup }
Add-ActionButton 'Android Display' { Open-SettingsPage 'android.settings.DISPLAY_SETTINGS' }
Add-ActionButton 'Default Apps' { Open-SettingsPage 'android.settings.MANAGE_DEFAULT_APPS_SETTINGS' }
Add-ActionButton 'Notifications' { Open-SettingsPage 'android.settings.NOTIFICATION_SETTINGS' }
Add-ActionButton 'Storage' { Open-SettingsPage 'android.settings.INTERNAL_STORAGE_SETTINGS' }
Add-ActionButton 'Gaming: Subway' { Gaming-Prep 'com.kiloo.subwaysurf' }
Add-ActionButton 'Gaming: Roblox' { Gaming-Prep 'com.roblox.client' }
Add-ActionButton 'Check for Update' { Check-Update }
Add-ActionButton 'Open Logs' { Start-Process notepad.exe $script:LogFile }

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas',9)
$script:LogBox.Location = New-Object System.Drawing.Point(24,205)
$script:LogBox.Size = New-Object System.Drawing.Size(840,370)
$form.Controls.Add($script:LogBox)
$form.Add_Shown({ if ((Get-TabletConnection).Count -eq 1) { Write-Log 'Tablet connection: OK' } else { Write-Log 'Tablet connection: not detected' }; Check-Update })
[void]$form.ShowDialog()
) { [math]::Round(([double]$zramSize)/1MB) } else { '?' }
    $df = (Invoke-Adb @('shell','df','-h','/data') -AllowFailure).Output.Trim()
    $lowPower = (Invoke-Adb @('shell','settings','get','global','low_power') -AllowFailure).Output.Trim()
    $refresh = (Invoke-Adb @('shell','settings','get','system','peak_refresh_rate') -AllowFailure).Output.Trim()

    Write-Log '=== PERFORMANCE AUDIT ==='
    Write-Log "Battery: $level% | Temperature: $temp"
    Write-Log "Available RAM: $avail MB"
    Write-Log "Swap: $swapFree MB free / $swapTotal MB total | ZRAM configured: $zramMb MB"
    Write-Log "Battery Saver low_power: $(if ($lowPower) { $lowPower } else { '0 / default' })"
    Write-Log "Peak refresh rate setting: $(if ($refresh) { $refresh } else { 'firmware default / not exposed' })"
    Write-Log "Storage: $df"
    Write-Log 'Performance audit complete.'
}

function Safe-Cache-Cleanup {
    Require-Tablet
    Write-Log 'Safe cache cleanup started (user data is not cleared).'
    $result = Invoke-Adb @('shell','pm','trim-caches','8589934592') -AllowFailure
    if ($result.Code -eq 0) { Write-Log 'Safe cache cleanup completed.' } else { Write-Log "Cache cleanup could not be completed: $($result.Output)" }
}

function Disable-BatterySaver {
    Require-Tablet
    $before = (Invoke-Adb @('shell','settings','get','global','low_power') -AllowFailure).Output.Trim()
    $result = Invoke-Adb @('shell','settings','put','global','low_power','0') -AllowFailure
    if ($result.Code -eq 0) { Write-Log "Battery Saver forced off (was: $before)." } else { Write-Log 'Battery Saver setting was not accepted.' }
}

function Stop-OptionalBackground {
    Require-Tablet
    $background = @(
        'com.instagram.android',
        'com.snapchat.android',
        'com.pinterest',
        'com.alibaba.aliexpresshd',
        'com.netflix.mediaclient',
        'com.google.android.apps.tachyon',
        'com.Garawell.BridgeRace',
        'com.fungames.sniper3d',
        'com.block.juggle',
        'com.youmusic.magictiles',
        'block.app.wars',
        'com.fungames.blockcraft',
        'com.nordcurrent.canteenhd'
    )
    $count = 0
    foreach ($pkg in $background) {
        $path = (Invoke-Adb @('shell','pm','path',$pkg) -AllowFailure).Output.Trim()
        if ($path) {
            Invoke-Adb @('shell','am','force-stop',$pkg) -AllowFailure | Out-Null
            $count++
        }
    }
    Write-Log "Stopped $count optional background apps."
}

function Check-Update {
    try {
        $m = Invoke-RestMethod -Uri $script:ManifestUrl -TimeoutSec 8 -Headers @{ 'User-Agent' = "$($script:AppName)/$($script:AppVersion)" }
        if ([version]$m.version -gt [version]$script:AppVersion) { Write-Log "Update available: $($m.version)" }
        else { Write-Log "Customizer is up to date ($($script:AppVersion))." }
    } catch { Write-Log "Update channel unavailable: $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.Size = New-Object System.Drawing.Size(900,650)
$form.StartPosition = 'CenterScreen'
$title = New-Object System.Windows.Forms.Label
$title.Text = 'ALLENS CUSTOM TABLET'
$title.Font = New-Object System.Drawing.Font('Segoe UI',20,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24,18)
$form.Controls.Add($title)
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Location = New-Object System.Drawing.Point(24,62)
$panel.Size = New-Object System.Drawing.Size(840,130)
$panel.WrapContents = $true
$panel.AutoScroll = $true
$form.Controls.Add($panel)

function Add-ActionButton {
    param([string]$Text,[scriptblock]$Action)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size(185,42)
    $localAction = $Action
    $button.Add_Click({
        try { & $localAction }
        catch {
            Write-Log "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,$script:AppName) | Out-Null
        }
    }.GetNewClosure())
    $panel.Controls.Add($button)
}


Add-ActionButton 'Wallpaper' { Customize-Wallpaper }
Add-ActionButton 'Home Settings' { Customize-Home }
Add-ActionButton 'Display Settings' { Customize-Display }
Add-ActionButton 'Sound Settings' { Customize-Sound }
Add-ActionButton 'Dark Mode' { Set-DarkMode }
Add-ActionButton 'Light Mode' { Set-LightMode }
Add-ActionButton '3-Button Nav' { Set-ThreeButtonNav }
Add-ActionButton 'Gesture Nav' { Set-GestureNav }
Add-ActionButton 'Small Text' { Set-FontScale '0.9' }
Add-ActionButton 'Normal Text' { Set-FontScale '1.0' }
Add-ActionButton 'Large Text' { Set-FontScale '1.15' }
Add-ActionButton '5-Min Timeout' { Set-Timeout 300000 }
Add-ActionButton '10-Min Timeout' { Set-Timeout 600000 }
Add-ActionButton '30-Min Timeout' { Set-Timeout 1800000 }
Add-ActionButton 'Auto-Rotate' { Set-AutoRotate }
Add-ActionButton 'Launch YouTube' { LaunchApp 'com.google.android.youtube' }
Add-ActionButton 'Launch Photo Vault' { LaunchApp 'com.asurion.android.mediabackup.vault.cricket' }

Add-ActionButton 'Privacy Audit' { Privacy-Audit }
Add-ActionButton 'Private DNS Automatic' { Set-PrivateDnsAutomatic }
Add-ActionButton 'Private DNS Off' { Set-PrivateDnsOff }
Add-ActionButton 'VPN Settings' { Open-SettingsPage 'android.settings.VPN_SETTINGS' }
Add-ActionButton 'App Permissions' { Invoke-Adb @('shell','am','start','-a','android.intent.action.MANAGE_APP_PERMISSIONS') -AllowFailure | Out-Null }
Add-ActionButton 'Performance Audit' { Performance-Audit }
Add-ActionButton 'Safe Cache Cleanup' { Safe-Cache-Cleanup }
Add-ActionButton 'Battery Saver Off' { Disable-BatterySaver }
Add-ActionButton 'Stop Optional Background' { Stop-OptionalBackground }

Add-ActionButton 'Device Status' { Device-Status }
Add-ActionButton 'Safe Tune' { Safe-Tune }
Add-ActionButton 'Privacy Center' { Privacy-Center }
Add-ActionButton 'Backup' { Backup }
Add-ActionButton 'Android Display' { Open-SettingsPage 'android.settings.DISPLAY_SETTINGS' }
Add-ActionButton 'Default Apps' { Open-SettingsPage 'android.settings.MANAGE_DEFAULT_APPS_SETTINGS' }
Add-ActionButton 'Notifications' { Open-SettingsPage 'android.settings.NOTIFICATION_SETTINGS' }
Add-ActionButton 'Storage' { Open-SettingsPage 'android.settings.INTERNAL_STORAGE_SETTINGS' }
Add-ActionButton 'Gaming: Subway' { Gaming-Prep 'com.kiloo.subwaysurf' }
Add-ActionButton 'Gaming: Roblox' { Gaming-Prep 'com.roblox.client' }
Add-ActionButton 'Check for Update' { Check-Update }
Add-ActionButton 'Open Logs' { Start-Process notepad.exe $script:LogFile }

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas',9)
$script:LogBox.Location = New-Object System.Drawing.Point(24,205)
$script:LogBox.Size = New-Object System.Drawing.Size(840,370)
$form.Controls.Add($script:LogBox)
$form.Add_Shown({ if ((Get-TabletConnection).Count -eq 1) { Write-Log 'Tablet connection: OK' } else { Write-Log 'Tablet connection: not detected' }; Check-Update })
[void]$form.ShowDialog()
