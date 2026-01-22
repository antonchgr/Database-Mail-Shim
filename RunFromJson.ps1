
# C:\DBMailShim\RunFromJson.ps1

$cfgPath = "C:\DBMailShim\targets.json"
$targets = Get-Content $cfgPath -Raw | ConvertFrom-Json

# Common configuration SMTP & shim (override per target from JSON)
$common = @{
  SmtpMode       = 'Static'
  SmtpHost       = 'smtp.office365.com'
  SmtpPort       = 587
  UseSsl         = $true
  From           = '<email>'
  SmtpUsername   = '<email>'
  SmtpPassword   = '<password>'
  BatchSize      = 100
  LogPath        = 'C:\DBMailShim\DBMailShim.log'
  ForceTcp       = $true
  Encrypt        = $false         # is for SQL connection
}

foreach ($t in $targets) {

  if (-not $t.Enabled) {
    Write-Host "Skipping disabled target: $($t.Name)"
    continue
  }

  $args = $common.Clone()
  $args["SqlServer"] = $t.SqlServer

  if ($t.PSObject.Properties.Name -contains "TcpPort" -and $t.TcpPort) {
    $args["TcpPort"] = [int]$t.TcpPort
  }

  if ($t.PSObject.Properties.Name -contains "ProfileNames" -and $t.ProfileNames) {
    $args["ProfileNames"] = $t.ProfileNames
  }

  if ($t.PSObject.Properties.Name -contains "BatchSize" -and $t.BatchSize) {
    $args["BatchSize"] = [int]$t.BatchSize
  }

  # Optionally: SQL Authentication
  if ($t.PSObject.Properties.Name -contains "SqlAuthUsername" -and $t.SqlAuthUsername `
      -and $t.PSObject.Properties.Name -contains "SqlAuthPassword" -and $t.SqlAuthPassword) {
    $args["SqlAuthUsername"] = $t.SqlAuthUsername
    $args["SqlAuthPassword"] = $t.SqlAuthPassword
  }

  Write-Host "`n>>> Running shim for $($t.Name) [$($t.Type)] - $($t.SqlServer) ..."
  & "C:\DBMailShim\DatabaseMailShim.ps1" @args
  Write-Host "<<< Completed $($t.Name)`n"
}
