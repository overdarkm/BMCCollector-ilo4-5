#requires -Version 5.1
<#
BMC Collector v4 - FULL (PowerShell 5.1 compatible)
- Redfish via curl.exe
- Prometheus exporter (/metrics)
Adds:
A health status code
B uptime (BootTime when available)
C system info
D manager info
G collector metrics
H storage/drives (SMART-like: FailurePredicted + Health)
#>

param(
  [string]$TargetsPath = "C:\BMCCollector\targets.json",
  [int]$PollSeconds = 30,
  [int]$ListenPort = 9105,
  [int]$TimeoutSec = 8
)

$ErrorActionPreference = "Stop"
$BaseDir = "C:\BMCCollector"
$MetricsPath = Join-Path $BaseDir "metrics.txt"

if (!(Test-Path $BaseDir)) {
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
}

# ---------------- Helpers (main scope) ----------------
function Esc([string]$s) {
  if ($null -eq $s) { return "" }
  return ($s -replace '\\','\\' -replace '"','\"')
}

function PromLine([string]$name, [hashtable]$labels, [string]$value) {
  $lbl = ($labels.GetEnumerator() | Sort-Object Name | ForEach-Object {
    "$($_.Name)=`"$(Esc $_.Value)`""
  }) -join ","
  if ($lbl) { return "$name{$lbl} $value" }
  return "$name $value"
}

function HealthCode([string]$h) {
  switch ($h) {
    "OK" { return 1 }
    "Warning" { return 2 }
    "Critical" { return 3 }
    default { return 0 }
  }
}

function Invoke-RedfishJsonCurl([string]$Ip, [string]$Path, [string]$User, [string]$Pass, [int]$TimeoutSecLocal) {
  $url = "https://$Ip$Path"
  $args = @("-ks", "--max-time", "$TimeoutSecLocal", "-u", "$User`:$Pass", $url)
  $json = & curl.exe @args
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    throw "curl failed (exit=$LASTEXITCODE) url=$url"
  }
  return $json | ConvertFrom-Json
}

# ---------------- Poll job (background) ----------------
$pollScript = {
  param($TargetsPath,$PollSeconds,$TimeoutSec,$MetricsPath)

  $ErrorActionPreference = "Continue"

  function Esc([string]$s) { if ($null -eq $s) { return "" }; return ($s -replace '\\','\\' -replace '"','\"') }
  function PromLine([string]$name, [hashtable]$labels, [string]$value) {
    $lbl = ($labels.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=`"$(Esc $_.Value)`"" }) -join ","
    if ($lbl) { return "$name{$lbl} $value" }
    return "$name $value"
  }
  function HealthCode([string]$h) {
    switch ($h) {
      "OK" { return 1 }
      "Warning" { return 2 }
      "Critical" { return 3 }
      default { return 0 }
    }
  }
  function Invoke-RedfishJsonCurl([string]$Ip, [string]$Path, [string]$User, [string]$Pass, [int]$TimeoutSecLocal) {
    $url = "https://$Ip$Path"
    $args = @("-ks", "--max-time", "$TimeoutSecLocal", "-u", "$User`:$Pass", $url)
    $json = & curl.exe @args
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
      throw "curl failed (exit=$LASTEXITCODE) url=$url"
    }
    return $json | ConvertFrom-Json
  }

  $User = [Environment]::GetEnvironmentVariable("REDFISH_USER","Machine")
  $Pass = [Environment]::GetEnvironmentVariable("REDFISH_PASS","Machine")

  while ($true) {
    $pollStart = Get-Date
    $lines = New-Object System.Collections.Generic.List[string]

    # --- HELP/TYPE (solo ciò che aggiungiamo/gestiamo)
    $lines.Add("# HELP bmc_up 1 se il BMC risponde a Redfish, 0 altrimenti")
    $lines.Add("# TYPE bmc_up gauge")
    $lines.Add("# HELP bmc_health_status 0=Unknown 1=OK 2=Warning 3=Critical")
    $lines.Add("# TYPE bmc_health_status gauge")
    $lines.Add("# HELP bmc_system_uptime_seconds Uptime stimato dal BootTime Redfish (se disponibile)")
    $lines.Add("# TYPE bmc_system_uptime_seconds gauge")
    $lines.Add("# HELP bmc_system_info Info sistema (labels) value=1")
    $lines.Add("# TYPE bmc_system_info gauge")
    $lines.Add("# HELP bmc_manager_info Info BMC/Manager (labels) value=1")
    $lines.Add("# TYPE bmc_manager_info gauge")

    $lines.Add("# HELP bmc_drive_health_ok 1=OK, 0=Warning/Critical/Altro")
    $lines.Add("# TYPE bmc_drive_health_ok gauge")
    $lines.Add("# HELP bmc_drive_failure_predicted 1=FailurePredicted true (SMART-like), 0 altrimenti")
    $lines.Add("# TYPE bmc_drive_failure_predicted gauge")
    $lines.Add("# HELP bmc_drive_capacity_bytes Capacita disco in bytes (se disponibile)")
    $lines.Add("# TYPE bmc_drive_capacity_bytes gauge")
    $lines.Add("# HELP bmc_drive_info Info disco (labels) value=1")
    $lines.Add("# TYPE bmc_drive_info gauge")

    $lines.Add("# HELP bmc_scrape_success 1=successo scrape target, 0=errore")
    $lines.Add("# TYPE bmc_scrape_success gauge")
    $lines.Add("# HELP bmc_target_scrape_duration_seconds Durata scrape per target")
    $lines.Add("# TYPE bmc_target_scrape_duration_seconds gauge")
    $lines.Add("# HELP bmc_scrape_duration_seconds Durata totale polling loop")
    $lines.Add("# TYPE bmc_scrape_duration_seconds gauge")
    $lines.Add("# HELP bmc_last_poll_timestamp Epoch seconds ultimo poll completato")
    $lines.Add("# TYPE bmc_last_poll_timestamp gauge")

    if ([string]::IsNullOrWhiteSpace($User) -or [string]::IsNullOrWhiteSpace($Pass)) {
      $lines.Add("# ERROR: REDFISH_USER/REDFISH_PASS mancanti (Machine env)")
      $body = ($lines -join "`n") + "`n"
      $body = $body -replace "`r",""
      try {
        $tmp = "$MetricsPath.tmp"
        [IO.File]::WriteAllText($tmp, $body, [Text.UTF8Encoding]::new($false))
        Move-Item -Force $tmp $MetricsPath
      } catch { }
      Start-Sleep -Seconds $PollSeconds
      continue
    }

    # targets
    $targets = @()
    try {
      $raw = Get-Content $TargetsPath -Raw -ErrorAction Stop
      $targets = $raw | ConvertFrom-Json
    } catch {
      $lines.Add("# ERROR: impossibile leggere targets.json")
      $targets = @()
    }

    foreach ($t in $targets) {
      $tStart = Get-Date
      $base = @{
        instance = $t.name
        bmc_ip   = $t.ip
        vendor   = $t.vendor
        site     = $t.site
	customer = $t.customer
      }

      $success = 1

      try {
        # Systems root
        $sysRoot = Invoke-RedfishJsonCurl -Ip $t.ip -Path "/redfish/v1/Systems" -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec
        if (!$sysRoot.Members -or $sysRoot.Members.Count -lt 1) { throw "No Systems members" }

        $sysId = $sysRoot.Members[0].'@odata.id'   # e.g. /redfish/v1/Systems/System.Embedded.1
        $sys   = Invoke-RedfishJsonCurl -Ip $t.ip -Path $sysId -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

        $lines.Add((PromLine "bmc_up" $base "1"))
        $lines.Add((PromLine "bmc_health_status" $base ([string](HealthCode $sys.Status.Health))))

        # Uptime from BootTime
        try {
          if ($sys.BootTime) {
            $bt = [DateTime]$sys.BootTime
            $upt = (New-TimeSpan -Start $bt -End (Get-Date)).TotalSeconds
            if ($upt -gt 0) { $lines.Add((PromLine "bmc_system_uptime_seconds" $base ([string][int]$upt))) }
          }
        } catch { }

        # System info metric
        try {
          $sLbl = $base.Clone()
          if ($sys.Manufacturer) { $sLbl.manufacturer = $sys.Manufacturer }
          if ($sys.Model)        { $sLbl.model        = $sys.Model }
          if ($sys.SerialNumber) { $sLbl.serial       = $sys.SerialNumber }
          if ($sys.BiosVersion)  { $sLbl.bios         = $sys.BiosVersion }
          $lines.Add((PromLine "bmc_system_info" $sLbl "1"))
        } catch { }

        # Manager info metric (firmware)
        try {
          $mgrRoot = Invoke-RedfishJsonCurl -Ip $t.ip -Path "/redfish/v1/Managers" -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec
          if ($mgrRoot.Members -and $mgrRoot.Members.Count -gt 0) {
            $mgrId = $mgrRoot.Members[0].'@odata.id'
            $mgr   = Invoke-RedfishJsonCurl -Ip $t.ip -Path $mgrId -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

            $mLbl = $base.Clone()
            if ($mgr.Model)          { $mLbl.model    = $mgr.Model }
            if ($mgr.FirmwareVersion){ $mLbl.firmware = $mgr.FirmwareVersion }
            if ($mgr.SerialNumber)   { $mLbl.serial   = $mgr.SerialNumber }
            $lines.Add((PromLine "bmc_manager_info" $mLbl "1"))
          }
        } catch { }

        # Storage / Drives (H)
        try {
          # derive Systems/<id>/Storage from actual sysId (safer)
          $storagePath = "$sysId/Storage"
          $storRoot = Invoke-RedfishJsonCurl -Ip $t.ip -Path $storagePath -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

          if ($storRoot.Members) {
            foreach ($sm in $storRoot.Members) {
              $stor = Invoke-RedfishJsonCurl -Ip $t.ip -Path $sm.'@odata.id' -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

              if ($stor.Drives) {
                foreach ($d in $stor.Drives) {
                  try {
                    $drv = Invoke-RedfishJsonCurl -Ip $t.ip -Path $d.'@odata.id' -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

                    # drive identity (prefer Id, fallback Name)
                    $driveId = $null
                    if ($drv.Id) { $driveId = [string]$drv.Id }
                    elseif ($drv.Name) { $driveId = [string]$drv.Name }
                    else { $driveId = "drive" }

                    $dLbl = $base.Clone()
                    $dLbl.drive = $driveId

        # ---------------- Thermal / Fans / Temperatures ----------------
        try {
          $chRoot = Invoke-RedfishJsonCurl -Ip $t.ip -Path "/redfish/v1/Chassis" -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec
          if ($chRoot.Members -and $chRoot.Members.Count -gt 0) {
            $chId = $chRoot.Members[0].'@odata.id'
            $ch   = Invoke-RedfishJsonCurl -Ip $t.ip -Path $chId -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

            # ---- Thermal ----
            try {
              if ($ch.Thermal.'@odata.id') {
                $therm = Invoke-RedfishJsonCurl -Ip $t.ip -Path $ch.Thermal.'@odata.id' -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

                # Fans
                if ($therm.Fans) {
                  foreach ($fan in $therm.Fans) {
                    $fanName = if ($fan.Name) { $fan.Name } else { "fan" }
                    $fLbl = $base.Clone()
                    $fLbl.fan = $fanName

                    $fanOk = 0
                    try { if ($fan.Status.Health -eq "OK") { $fanOk = 1 } } catch { }
                    $lines.Add((PromLine "bmc_fan_health_ok" $fLbl ([string]$fanOk)))

                    if ($fan.ReadingRPM) {
                      $lines.Add((PromLine "bmc_fan_rpm" $fLbl ([string]$fan.ReadingRPM)))
                    } elseif ($fan.Reading) {
                      $lines.Add((PromLine "bmc_fan_rpm" $fLbl ([string]$fan.Reading)))
                    }
                  }
                }

                # Temperatures
                if ($therm.Temperatures) {
                  foreach ($temp in $therm.Temperatures) {
                    if ($null -ne $temp.ReadingCelsius) {
                      $tName = if ($temp.Name) { $temp.Name } else { "temp" }
                      $tLbl = $base.Clone()
                      $tLbl.sensor = $tName

                      $lines.Add((PromLine "bmc_temp_celsius" $tLbl ([string]$temp.ReadingCelsius)))

                      $tOk = 0
                      try { if ($temp.Status.Health -eq "OK") { $tOk = 1 } } catch { }
                      $lines.Add((PromLine "bmc_temp_health_ok" $tLbl ([string]$tOk)))
                    }
                  }
                }
              }
            } catch { }

            # ---- Power / PSU ----
            try {
              if ($ch.Power.'@odata.id') {
                $pwr = Invoke-RedfishJsonCurl -Ip $t.ip -Path $ch.Power.'@odata.id' -User $User -Pass $Pass -TimeoutSecLocal $TimeoutSec

                # PSU
                if ($pwr.PowerSupplies) {
                  foreach ($psu in $pwr.PowerSupplies) {
                    $pName = if ($psu.Name) { $psu.Name } else { "psu" }
                    $pLbl = $base.Clone()
                    $pLbl.psu = $pName

                    $psuOk = 0
                    try { if ($psu.Status.Health -eq "OK") { $psuOk = 1 } } catch { }
                    $lines.Add((PromLine "bmc_psu_health_ok" $pLbl ([string]$psuOk)))

                    if ($psu.PowerOutputWatts) {
                      $lines.Add((PromLine "bmc_psu_output_watts" $pLbl ([string]$psu.PowerOutputWatts)))
                    }
                  }
                }

                # Power consumption (best metric)
                if ($pwr.PowerControl -and $pwr.PowerControl.Count -gt 0) {
                  $pc = $pwr.PowerControl[0]
                  if ($pc.PowerConsumedWatts) {
                    $lines.Add((PromLine "bmc_power_consumed_watts" $base ([string]$pc.PowerConsumedWatts)))
                  }
                  if ($pc.PowerMetrics) {
                    if ($pc.PowerMetrics.AverageConsumedWatts) {
                      $lines.Add((PromLine "bmc_power_average_watts" $base ([string]$pc.PowerMetrics.AverageConsumedWatts)))
                    }
                    if ($pc.PowerMetrics.MaxConsumedWatts) {
                      $lines.Add((PromLine "bmc_power_max_watts" $base ([string]$pc.PowerMetrics.MaxConsumedWatts)))
                    }
                  }
                }
              }
            } catch { }
          }
        } catch { }

                    # health ok
                    $healthOk = 0
                    try { if ($drv.Status.Health -eq "OK") { $healthOk = 1 } } catch { }
                    $lines.Add((PromLine "bmc_drive_health_ok" $dLbl ([string]$healthOk)))

                    # failure predicted (SMART-like)
                    $fp = 0
                    try { if ($drv.FailurePredicted -eq $true) { $fp = 1 } } catch { }
                    $lines.Add((PromLine "bmc_drive_failure_predicted" $dLbl ([string]$fp)))

                    # capacity
                    try {
                      if ($null -ne $drv.CapacityBytes) {
                        $lines.Add((PromLine "bmc_drive_capacity_bytes" $dLbl ([string]$drv.CapacityBytes)))
                      }
                    } catch { }

                    # drive info metric (labels only)
                    try {
                      $iLbl = $dLbl.Clone()
                      if ($drv.Model)        { $iLbl.model = $drv.Model }
                      if ($drv.SerialNumber) { $iLbl.serial = $drv.SerialNumber }
                      if ($drv.MediaType)    { $iLbl.media_type = $drv.MediaType }
                      if ($drv.Protocol)     { $iLbl.protocol = $drv.Protocol }
                      if ($drv.Manufacturer) { $iLbl.manufacturer = $drv.Manufacturer }
                      $lines.Add((PromLine "bmc_drive_info" $iLbl "1"))
                    } catch { }

                  } catch { }
                }
              }
            }
          }
        } catch { }

      } catch {
        $success = 0
        $lines.Add((PromLine "bmc_up" $base "0"))
      }

      # collector per-target
      try {
        $tDur = (New-TimeSpan -Start $tStart -End (Get-Date)).TotalSeconds
        $lines.Add((PromLine "bmc_target_scrape_duration_seconds" $base ([string]([math]::Round($tDur,3)))))
      } catch { }

      $lines.Add((PromLine "bmc_scrape_success" $base ([string]$success)))
    }

    # collector global
    $loopDur = (New-TimeSpan -Start $pollStart -End (Get-Date)).TotalSeconds
    $lines.Add((PromLine "bmc_scrape_duration_seconds" @{} ([string]([math]::Round($loopDur,3)))))
    $lines.Add((PromLine "bmc_last_poll_timestamp" @{} ([string][int][DateTimeOffset]::Now.ToUnixTimeSeconds())))

    # write (LF-only, UTF8 no BOM, atomic)
    $body = ($lines -join "`n") + "`n"
    $body = $body -replace "`r",""

    try {
      $tmp = "$MetricsPath.tmp"
      [IO.File]::WriteAllText($tmp, $body, [Text.UTF8Encoding]::new($false))
      Move-Item -Force $tmp $MetricsPath
    } catch { }

    Start-Sleep -Seconds $PollSeconds
  }
}

# Replace existing job
$existing = Get-Job -Name "BMC_POLL" -ErrorAction SilentlyContinue
if ($existing) { Remove-Job -Name "BMC_POLL" -Force -ErrorAction SilentlyContinue }
Start-Job -Name "BMC_POLL" -ScriptBlock $pollScript -ArgumentList $TargetsPath,$PollSeconds,$TimeoutSec,$MetricsPath | Out-Null

# ---------------- HTTP Listener (/metrics) ----------------
$listener = New-Object System.Net.HttpListener
$prefix = "http://+:$ListenPort/"
$listener.Prefixes.Add($prefix)

try { $listener.Start() } catch {
  throw "Impossibile avviare HttpListener su $prefix. Errore: $($_.Exception.Message)"
}

Write-Host "BMC Collector v4 attivo: http://localhost:$ListenPort/metrics  (poll ogni $PollSeconds s)"

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $path = $ctx.Request.Url.AbsolutePath

  if ($path -eq "/" -or $path -eq "/metrics") {
    $body = "# no data yet`n"
    if (Test-Path $MetricsPath) {
      try { $body = Get-Content $MetricsPath -Raw } catch { $body = "# read error`n" }
    }

    $body = $body -replace "`r",""
    if (-not $body.EndsWith("`n")) { $body += "`n" }

    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
  } else {
    $ctx.Response.StatusCode = 404
    $ctx.Response.OutputStream.Close()
  }
}
