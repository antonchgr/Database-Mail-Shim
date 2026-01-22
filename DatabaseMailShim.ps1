[CmdletBinding()]
param(
    [string]$SqlServer = ".",
    [string]$Database  = "msdb",
    [int]$TcpPort      = 0,
    [switch]$Encrypt,
    [switch]$TrustServerCertificate,
    [switch]$ForceTcp,
    [string]$SqlAuthUsername = "",
    [string]$SqlAuthPassword = "",
    [string[]]$ProfileNames = @(),
    [ValidateSet('Static','FromMsdbRelay')]
    [string]$SmtpMode = "Static",
    [string]$SmtpHost = "smtp.office365.com",
    [int]$SmtpPort   = 587,
    [switch]$UseSsl,
    [string]$From    = "",
    [System.Management.Automation.PSCredential]$SmtpCredential = $null,
    [string]$SmtpUsername = "",
    [string]$SmtpPassword = "",
    [int]$BatchSize = 50,
    [string]$LogPath = "C:\DBMailShim\DBMailShim.log",
    [switch]$DryRun
)

if (-not $PSBoundParameters.ContainsKey('ForceTcp')) { $ForceTcp = $true }
if (-not $PSBoundParameters.ContainsKey('UseSsl'))   { $UseSsl   = $true }
if (-not $PSBoundParameters.ContainsKey('Encrypt'))  { $Encrypt  = $false }

function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fffK")
    Add-Content -Path $LogPath -Value "[$ts][$Level] $Message"
    Write-Host "[$ts][$Level] $Message"
}

function Ensure-SqlModule {
    if (Get-Module -ListAvailable -Name SqlServer) {
        Import-Module SqlServer -DisableNameChecking -ErrorAction Stop
        return
    }
    if (Get-Module -ListAvailable -Name SQLPS) {
        Import-Module SQLPS -DisableNameChecking -ErrorAction Stop
        return
    }
    throw "No SqlServer or SQLPS module found"
}

$UseSqlAuth = ($SqlAuthUsername -and $SqlAuthPassword)

function Build-CS {
    param([string]$Db)
    if ($TcpPort -gt 0) {
        $seg = "tcp:$($SqlServer.Split('\')[0]),$TcpPort"
    } else {
        $seg = "tcp:$SqlServer"
    }

    $cs = "Server=$seg;Database=$Db;Application Name=DBMailShim;"

    if ($Encrypt) {
        $cs += "Encrypt=True;"
        if ($TrustServerCertificate){ $cs+="TrustServerCertificate=True;" }
    } else {
        $cs += "Encrypt=False;"
    }

    if ($UseSqlAuth) {
        $cs += "User ID=$SqlAuthUsername;Password=$SqlAuthPassword;"
    } else {
        $cs += "Trusted_Connection=True;"
    }
    
    $cs += "Connect Timeout=120;"
    $cs += "MultiSubnetFailover=True;"

    return $cs
}

function SQL {
    param([string]$Query)
    $cs = Build-CS -Db $Database
    return Invoke-Sqlcmd -ConnectionString $cs -Query $Query -MaxCharLength 2147483647 -ErrorAction Stop
}

# Build SMTP credential
if (-not $SmtpCredential -and $SmtpUsername -and $SmtpPassword) {
    $sec = ConvertTo-SecureString $SmtpPassword -AsPlainText -Force
    $SmtpCredential = New-Object pscredential($SmtpUsername,$sec)
}

Ensure-SqlModule
Write-Log "Starting DatabaseMailShim on [$SqlServer] …"

# Create lock table
SQL @"
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name='dbmail_shim_lock')
CREATE TABLE dbo.dbmail_shim_lock(
  mailitem_id INT PRIMARY KEY,
  locked_at_utc DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  lock_owner NVARCHAR(200)
)
"@


# Custom shim log table 
SQL @"
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name='dbmail_shim_log' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
  CREATE TABLE dbo.dbmail_shim_log(
      log_id     INT IDENTITY(1,1) PRIMARY KEY,
      log_date   DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
      level      NVARCHAR(16) NOT NULL,           -- 'success' | 'error' | ...
      mailitem_id INT NULL,
      description NVARCHAR(4000) NULL
  );
END
"@



# -------------------------------
#  BUILD ACTUAL FETCH QUERY (NO sqlcmd variables)
# -------------------------------


$filter = ""

if ($ProfileNames.Count -gt 0) {

    # Proper quoting of profile names
    $quoted = ($ProfileNames | ForEach-Object { "'$_'" }) -join ","

    # Multi-line SQL block (correct concatenation)
    $filter = @"
AND EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profile p
    WHERE p.profile_id = mi.profile_id
      AND p.name IN ($quoted)
)
"@
}


$fetchQuery = @"
SELECT TOP ($BatchSize)
    mi.mailitem_id, mi.profile_id,
    mi.recipients, mi.copy_recipients, mi.blind_copy_recipients,
    mi.subject, mi.body, mi.body_format, mi.file_attachments
FROM msdb.dbo.sysmail_mailitems mi 
WHERE mi.sent_status IN (0,3)
 $filter 
ORDER BY mi.send_request_date
"@


$rows = SQL $fetchQuery

if ($rows.Count -eq 0) {
    Write-Log "No unsent messages."
    exit
}

Write-Log "Found $($rows.Count) items."

function Resolve-SMTP {
    param([int]$ProfileId)

    if ($SmtpMode -eq "Static") {
        return @{
            Host=$SmtpHost; Port=$SmtpPort;
            EnableSsl=[bool]$UseSsl; From=$From; Cred=$SmtpCredential
        }
    }

    $q = @"
SELECT TOP 1 s.servername,s.port,s.enable_ssl,a.email_address
FROM msdb.dbo.sysmail_profileaccount pa
JOIN msdb.dbo.sysmail_account a ON a.account_id=pa.account_id
JOIN msdb.dbo.sysmail_server  s ON s.account_id=a.account_id
WHERE pa.profile_id=$ProfileId
ORDER BY pa.sequence_number
"@
    $r = SQL $q
    return @{
        Host=$r.servername; Port=$r.port;
        EnableSsl=$r.enable_ssl; From=$r.email_address; Cred=$null
    }
}

foreach ($r in $rows) {

    $id=$r.mailitem_id

    # Try to lock
    $acq = SQL "BEGIN TRY INSERT INTO dbo.dbmail_shim_lock(mailitem_id,lock_owner) VALUES($id,HOST_NAME()); SELECT 1 as ok; END TRY BEGIN CATCH SELECT 0 as ok; END CATCH"
    if ($acq.ok -ne 1) {
        Write-Log "Skip locked $id"
        continue
    }

    try {
        $smtpCfg = Resolve-SMTP -ProfileId $r.profile_id

        if ($DryRun) {
            Write-Log "DryRun → skip send $id"
            SQL "DELETE FROM dbo.dbmail_shim_lock WHERE mailitem_id=$id"
            continue
        }

        
	
	# ----- FULL INLINE HTML
	$mail = New-Object System.Net.Mail.MailMessage
	$mail.From            = $smtpCfg.From
	$mail.Subject         = [string]$r.subject
	$mail.SubjectEncoding = [System.Text.Encoding]::UTF8
	$mail.HeadersEncoding = [System.Text.Encoding]::UTF8

	# Decode body msg
	$rawBody = [string]$r.body
	$looksEncoded = $rawBody -like '*&lt;*' -and $rawBody -like '*&gt;*'
	$html = if ($looksEncoded) { [System.Net.WebUtility]::HtmlDecode($rawBody) } else { $rawBody }

	# line breaks 
	$html = $html -replace '>(\s*)<', ">$1`r`n<"

	# AlternateView text/html (UTF-8) TransferEncoding Base64 
	$htmlView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
	    $html, [System.Text.Encoding]::UTF8, "text/html"
	)
	$htmlView.TransferEncoding = [System.Net.Mime.TransferEncoding]::Base64

	# Oprional text/plain view for deliverability
	$plain = [System.Text.RegularExpressions.Regex]::Replace($html, "<[^>]+>", " ")
	$plain = [System.Text.RegularExpressions.Regex]::Replace($plain, "\s+", " ").Trim()
	$plainView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
	    $plain, [System.Text.Encoding]::UTF8, "text/plain"
	)
	$plainView.TransferEncoding = [System.Net.Mime.TransferEncoding]::QuotedPrintable

	# views 
	$mail.AlternateViews.Clear()
	$mail.AlternateViews.Add($htmlView)
	$mail.AlternateViews.Add($plainView)

	# Flags for compatibility
	$mail.IsBodyHtml   = $true
	$mail.Body         = $html
	$mail.BodyEncoding = [System.Text.Encoding]::UTF8


        foreach ($lst in @($r.recipients,$r.copy_recipients,$r.blind_copy_recipients)) {
            if ($lst) {
                foreach ($addr in ($lst -split "[;,]" | % { $_.Trim() } | ? {$_})) {
                    if     ($lst -eq $r.recipients)          { $mail.To.Add($addr) }
                    elseif ($lst -eq $r.copy_recipients)     { $mail.CC.Add($addr) }
                    else                                      { $mail.Bcc.Add($addr) }
                }
            }
        }

        # Attachments
        if ($r.file_attachments) {
            foreach ($p in ($r.file_attachments -split "[;,]" | % {$_.Trim()} | ? {$_})) {
                if (-not (Test-Path $p)) { throw "Missing attachment $p" }
                $mail.Attachments.Add($p) | Out-Null
            }
        }

        # SMTP send
        $smtp = New-Object System.Net.Mail.SmtpClient($smtpCfg.Host,$smtpCfg.Port)
        $smtp.EnableSsl = $smtpCfg.EnableSsl
        if ($smtpCfg.Cred){ $smtp.Credentials=$smtpCfg.Cred } else { $smtp.UseDefaultCredentials=$true }

        $smtp.Send($mail)


        # --- mark as sent (1) + write shim log + release lock ---
 
$updateSql = @"
UPDATE msdb.dbo.sysmail_mailitems
   SET sent_status = 1,                  -- 1 = sent (tinyint)
       sent_date   = SYSUTCDATETIME()
 WHERE mailitem_id = $id;

INSERT INTO msdb.dbo.dbmail_shim_log(level, log_date, mailitem_id, description)
VALUES('success', SYSUTCDATETIME(), $id, 'DBMail shim: message sent');

DELETE FROM dbo.dbmail_shim_lock WHERE mailitem_id = $id;
"@
SQL $updateSql | Out-Null



        Write-Log "OK sent $id"
    }
    catch {

$msg = $_.Exception.Message.Replace("'", "''")
Write-Log "ERROR $id : $($msg)" "ERROR"

$errSql = @"
INSERT INTO msdb.dbo.dbmail_shim_log(level, log_date, mailitem_id, description)
VALUES('error', SYSUTCDATETIME(), $id, 'DBMail shim failure: $msg');

-- release lock for retry 
DELETE FROM dbo.dbmail_shim_lock WHERE mailitem_id = $id;
"@
SQL $errSql | Out-Null
     

    }
}

Write-Log "Completed batch."
