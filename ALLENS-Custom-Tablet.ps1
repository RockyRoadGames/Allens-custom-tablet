# ALLENS Custom Tablet update engine
$ErrorActionPreference = 'Stop'

$script:AppName = 'ALLENS Custom Tablet'
$script:AppVersion = '1.0.2'
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
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Get-AdbPath {
    $local = Join-Path $env:USERPROFILE 'Downloadsplatform-toolsadb.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'adb.exe was not found.'
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string[]]$AdbArgs,
        [switch]$AllowFailure
    )
    $adb = Get-AdbPath
    $output = & $adb @AdbArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ('ADB failed ({0}): adb {1}{2}{3}' -f $code,($AdbArgs -join ' '),[Environment]::NewLine,($output -join [Environment]::NewLine))
    }
    [pscustomobject]@{ Code=$code; Output=($output -join [Environment]::NewLine) }
}

function Get-TabletConnection {
    try {
        $r = Invoke-Adb @('devices')
        return @($r.Output -split '
' | Where-Object { $_ -match 'sdevice$' })
    } catch { return @() }
}

function Require-Tablet {
    if ((Get-TabletConnection).Count -ne 1) {
        throw 'Connect exactly one authorized Android tablet by USB.'
    }
}

function Device-Status {
    Require-Tablet
    $model = (Invoke-Adb @('shell','getprop','ro.product.model')).Output.Trim()
    $android = (Invoke-Adb @('shell','getprop','ro.build.version.release')).Output.Trim()
    $battery = (Invoke-Adb @('shell','dumpsys','battery')).Output
    $level = if ($battery -match 'level:\s*(\d+)') { $matches[1] } else { '?' }
    $mem = (Invoke-Adb @('shell','cat','/proc/meminfo')).Output
    $free = if ($mem -match 'MemAvailable:\s*(\d+)\s*kB') { [math]::Round(([double]$matches[1])/1024) } else { '?' }
    $vb = (Invoke-Adb @('shell','getprop','ro.boot.verifiedbootstate')).Output.Trim()
    $locked = (Invoke-Adb @('shell','getprop','ro.boot.flash.locked')).Output.Trim()
    Write-Log "Device: $model / Android $android"
    Write-Log "Battery: $level% | Available RAM: $free MB"
    Write-Log "Verified Boot: $vb | Boot locked: $locked"
}

function Safe-Tune {
    Require-Tablet
    $dir = Join-Path $script:BackupRoot ('before-safe-tune-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($key in @('window_animation_scale','transition_animation_scale','animator_duration_scale')) {
        $value = (Invoke-Adb @('shell','settings','--user','0','get','global',$key)).Output.Trim()
        Add-Content "$dir\settings.txt" "global|$key|$value"
    }
    & (Get-AdbPath) shell settings --user 0 put global window_animation_scale 0
    & (Get-AdbPath) shell settings --user 0 put global transition_animation_scale 0
    & (Get-AdbPath) shell settings --user 0 put global animator_duration_scale 0
    & (Get-AdbPath) shell settings --user 0 put system screen_off_timeout 600000
    & (Get-AdbPath) shell settings --user 0 put system status_bar_show_battery_percent 1
    Invoke-Adb @('shell','cmd','uimode','night','yes') -AllowFailure | Out-Null
    Invoke-Adb @('shell','cmd','package','set-home-activity','--user','0','com.android.launcher3/com.android.searchlauncher.SearchLauncher') -AllowFailure | Out-Null
    Invoke-Adb @('shell','input','keyevent','KEYCODE_HOME') -AllowFailure | Out-Null
    Write-Log 'Safe UI tune applied.'
    Write-Log "Backup: $dir"
}

function Privacy-Center {
    Require-Tablet
    $dns = (Invoke-Adb @('shell','settings','--user','0','get','secure','private_dns_mode') -AllowFailure).Output.Trim()
    $vpn = (Invoke-Adb @('shell','settings','--user','0','get','secure','always_on_vpn_app') -AllowFailure).Output.Trim()
    $vb = (Invoke-Adb @('shell','getprop','ro.boot.verifiedbootstate')).Output.Trim()
    Write-Log "Private DNS: $dns | Always-on VPN: $vpn | Verified Boot: $vb"
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
    $allowed = @(
        'com.kiloo.subwaysurf','com.roblox.client','com.ea.game.pvzfree_row',
        'com.fingersoft.hcr2','com.robtopx.geometryjumplite','com.innersloth.spacemafia'
    )
    if ($allowed -notcontains $PackageName) { throw 'Game is not in the approved list.' }

    $background = @(
        'com.instagram.android','com.snapchat.android','com.pinterest',
        'com.alibaba.aliexpresshd','com.netflix.mediaclient',
        'com.google.android.apps.tachyon','com.Garawell.BridgeRace',
        'com.fungames.sniper3d','com.block.juggle','com.youmusic.magictiles',
        'block.app.wars','com.fungames.blockcraft','com.nordcurrent.canteenhd'
    )

    $count = 0
    foreach ($pkg in $background) {
        $path = (Invoke-Adb @('shell','pm','path',$pkg) -AllowFailure).Output.Trim()
        if ($path) {
            Invoke-Adb @('shell','am','force-stop',$pkg) -AllowFailure | Out-Null
            $count++
        }
    }

    $modes = (Invoke-Adb @('shell','cmd','game','list-modes',$PackageName) -AllowFailure).Output.Trim()
    Write-Log "Gaming prep: $PackageName"
    Write-Log "Game modes: $modes"
    Write-Log "Stopped $count optional background apps."
    Invoke-Adb @('shell','monkey','-p',$PackageName,'-c','android.intent.category.LAUNCHER','1') -AllowFailure | Out-Null
    Write-Log 'Launch requested.'
}

function Backup {
    Require-Tablet
    $dir = Join-Path $script:BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    (Invoke-Adb @('shell','getprop')).Output | Set-Content "$dir\getprop.txt" -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','global')).Output | Set-Content "$dir\settings-global.txt" -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','secure')).Output | Set-Content "$dir\settings-secure.txt" -Encoding UTF8
    (Invoke-Adb @('shell','settings','list','system')).Output | Set-Content "$dir\settings-system.txt" -Encoding UTF8
    (Invoke-Adb @('shell','pm','list','packages')).Output | Set-Content "$dir\packages.txt" -Encoding UTF8
    (Invoke-Adb @('shell','dumpsys','battery')).Output | Set-Content "$dir\battery.txt" -Encoding UTF8
    Write-Log "Backup saved: $dir"
}

function Check-Update {
    try {
        $m = Invoke-RestMethod -Uri $script:ManifestUrl -TimeoutSec 8 -Headers @{ 'User-Agent' = "$($script:AppName)/$($script:AppVersion)" }
        if ([version]$m.version -gt [version]$script:AppVersion) {
            Write-Log "Update available: $($m.version)"
        } else {
            Write-Log "Customizer is up to date ($($script:AppVersion))."
        }
    }
    catch { Write-Log "Update channel unavailable: $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:AppName
$form.Size = New-Object System.Drawing.Size(900,650)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760,520)

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
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,$script:AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }.GetNewClosure())
    $panel.Controls.Add($button)
}

Add-ActionButton 'Device Status' { Device-Status }
Add-ActionButton 'Safe Tune' { Backup; Safe-Tune }
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

$form.Add_Shown({
    if ((Get-TabletConnection).Count -eq 1) { Write-Log 'Tablet connection: OK' }
    else { Write-Log 'Tablet connection: not detected' }
    Check-Update
})

[void]$form.ShowDialog()
