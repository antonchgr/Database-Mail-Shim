# Database Mail Shim for SQL Servers impacted from SQL Server 2022 CU23 or SQL Server 2025 CU1

A lightweight, production‑ready workaround that delivers **SQL Server Database Mail** messages through an external SMTP service (e.g., **Office 365 / Exchange Online**) **only** when the built‑in Database Mail host process cannot run due to a **known packaging defect** in specific cumulative updates.

> **Important:**  
> If standard **Database Mail is available and functional** in your environment, **this shim is NOT needed**.  
> This workaround exists **only** for environments impacted by **SQL Server 2022 CU23** and **SQL Server 2025 CU1**, which were temporarily withdrawn due to a Database Mail breakage acknowledged by Microsoft. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

***

## Why This Workaround Exists

In **January 2026**, Microsoft confirmed that **SQL Server 2022 CU23 (KB5074819)** and **SQL Server 2025 CU1 (KB5074901)** were **temporarily unavailable** because they **break Database Mail**. After installation, Database Mail fails with a missing assembly error (e.g., `Microsoft.SqlServer.DatabaseMail.XEvents`), and Microsoft advises users who rely on Database Mail to **avoid installing** or to **uninstall** these updates until a fix is released. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

Microsoft engineering publicly acknowledged the problem and recommended uninstalling the affected CUs if you need Database Mail; community reports corroborate the behavior (unsent queue accumulation; `DatabaseMail.exe` failing to load the XEvents assembly). [\[support.zendesk.com\]](https://support.zendesk.com/hc/en-us/articles/8130298032538-Using-Microsoft-Exchange-Online-with-the-Authenticated-SMTP-Connector), [\[linkedin.com\]](https://www.linkedin.com/pulse/how-set-up-smtp-client-submission-joy-emeto-03nmf)

**Therefore:** use this shim **only** when you **cannot immediately roll back** from the impacted CUs and you must keep email notifications flowing. If Database Mail works normally in your environment, **do not** use this shim—use native `sp_send_dbmail` as usual. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

***
## <a name="how-it-works"></a> How It Works (High‑Level)

1.  SQL Server enqueues Database Mail messages in **`msdb.dbo.sysmail_mailitems`** via `sp_send_dbmail` or your custom code.
2.  Due to the CU defect, the Database Mail host process cannot run, so messages remain **unsent**. The shim processes items with **`sent_status IN (0,3)`** (unsent + retrying).
3.  For each item, the shim acquires a **per‑row lock**, sends the email via **SMTP** (e.g., O365), sets **`sent_status = 1`**, and writes results to a **shim log**.
4.  A wrapper iterates **multiple SQL endpoints** (listeners/instances) listed in a **JSON** file.
5.  A **Windows Scheduled Task** triggers the wrapper every **2 minutes**.

***

## <a name="architecture"></a> Architecture

     SQL Server (msdb)
     ────────────────────────────────────────────
      sysmail_mailitems        ← queue (unsent/retrying)
      dbmail_shim_lock         ← prevents double sends
      dbmail_shim_log          ← success/error log

     PowerShell Shim (DatabaseMailShim.ps1)
     ────────────────────────────────────────────
      - Batch fetch from msdb
      - SMTP submit (Office 365 / relay)
      - sent_status update (→ 1)
      - lock/log maintenance

     Wrapper (RunFromJson.ps1)
     ────────────────────────────────────────────
      - Loads targets.json (listeners & instances)
      - Invokes DatabaseMailShim.ps1 per target

     Windows Task Scheduler
     ────────────────────────────────────────────
      - Executes wrapper every 2 minutes
      - Ignore new instance if still running

***

## <a name="sql-requirements"></a> SQL Requirements

### Queue semantics — `msdb.dbo.sysmail_mailitems`

*   `sent_status` (`TINYINT`):
    *   `0 = unsent`, `1 = sent`, `2 = failed`, `3 = retrying`.
    *   The shim targets **`IN (0,3)`** to avoid re‑sending sent items and to skip permanently failed ones unless you deliberately change policy. *(Microsoft’s CU pages confirm Database Mail stops after the affected CUs; the status mapping is standard for Database Mail.)* [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

### Shim Lock Table (auto‑created)

```sql
dbmail_shim_lock
  mailitem_id   INT PRIMARY KEY
  locked_at_utc DATETIME2(3) DEFAULT SYSUTCDATETIME()
  lock_owner    NVARCHAR(256) NULL
```

### Shim Log Table (auto‑created)

```sql
dbmail_shim_log
  log_id       INT IDENTITY(1,1) PRIMARY KEY
  log_date     DATETIME2(3) DEFAULT SYSUTCDATETIME()
  level        NVARCHAR(16)     -- 'success' | 'error' | ...
  mailitem_id  INT NULL
  description  NVARCHAR(4000) NULL
```

> **Note:** Do **not** write to `msdb.dbo.sysmail_event_log` (read‑only view). Use your own shim log.

***

## <a name="powershell-shim-responsibilities"></a> PowerShell Shim Responsibilities

> This describes the behavior you should keep in your implementation. It does **not** include full scripts.

### Batch Fetch

Use a robust connection string (`Server=tcp:...; Database=msdb; Application Name=...;`) and consider:

*   Integrated security (`Trusted_Connection=True`) or SQL Auth,
*   `Connect Timeout=60; MultiSubnetFailover=True;` for AG listeners,
*   `Encrypt=` per your security policy.

Fetch query:

```sql
SELECT TOP (@BatchSize)
    mi.mailitem_id, mi.profile_id,
    mi.recipients, mi.copy_recipients, mi.blind_copy_recipients,
    mi.subject, mi.body, mi.body_format, mi.file_attachments
FROM msdb.dbo.sysmail_mailitems AS mi
WHERE mi.sent_status IN (0,3)
ORDER BY mi.send_request_date;
```

### Per‑Message Flow

1.  **Lock** the `mailitem_id` in `dbmail_shim_lock` (skip if insert fails).
2.  Build email:
    *   UTF‑8 for `SubjectEncoding`, `HeadersEncoding`, `BodyEncoding`.
    *   Send HTML via **AlternateView** (`text/html; charset=utf-8`) with **TransferEncoding = Base64** (or Quoted‑Printable) to prevent line‑wrap corruption in transit.
    *   If your producer emits HTML entities (`&lt; &gt;`), decode once; otherwise send raw HTML.
    *   Add To/CC/Bcc; verify at least one To.
    *   Optionally handle attachments from `file_attachments`.
3.  Submit via SMTP:
    *   O365: `smtp.office365.com:587` with STARTTLS and valid credentials.
    *   Ensure **From** matches the authenticated mailbox or has **Send As** rights.
4.  On success:
    *   `UPDATE msdb.dbo.sysmail_mailitems SET sent_status=1, sent_date=SYSUTCDATETIME() WHERE mailitem_id=@id;`
    *   `INSERT` into `dbmail_shim_log (success)`; `DELETE` from `dbmail_shim_lock`.
5.  On error:
    *   `INSERT` into `dbmail_shim_log (error)` (capture exception text); `DELETE` lock (allow retry later).

### Module/Query Notes

*   Prefer the **SqlServer** module (not legacy **SQLPS**).
*   Avoid parameter combinations in `Invoke‑Sqlcmd` that truncate `NVARCHAR(MAX)`; if needed, use a large `-MaxCharLength` value or `-OutputAs DataTables`. In many environments, **not** using `-NoScan` avoids unexpected type inference and truncation. *(Behavior is module/version dependent; verify in your environment.)*

***

## <a name="targets-json"></a> Targets JSON (Multi‑Instance Execution)

Define listeners and/or instances in **`targets.json`**; the wrapper runs the shim once per target:

```json
[
  {
    "Name": "Listener-A",
    "Type": "Listener",
    "SqlServer": "listener-a.yourdomain.local",
    "TcpPort": 7777,
    "ProfileNames": [],
    "BatchSize": 150,
    "Enabled": true
  },
  {
    "Name": "Instance-1",
    "Type": "Instance",
    "SqlServer": "HOST1\\INSTANCE1",
    "BatchSize": 120,
    "Enabled": true
  }
]
```

*   **Name**: friendly label for logs
*   **SqlServer**: AG listener DNS/IP or `HOST\INSTANCE`
*   **TcpPort**: fixed port recommended for listeners
*   **ProfileNames**: optional filter for Database Mail profiles
*   **BatchSize**: per‑target override
*   **Enabled**: quickly include/exclude a target

***

## <a name="task-scheduler"></a> Windows Task Scheduler

Create **one** Scheduled Task that runs the wrapper every **2 minutes**.

**Action (one‑liner):**

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\DBMailShim\RunFromJson.ps1"
```

**Recommended Settings**

*   Run whether user is logged on or not
*   Run with highest privileges
*   If task is already running → **Do not start a new instance**
*   Execution time limit: **5–10 minutes**
*   Service account with: required **msdb** permissions and outbound SMTP access

***

## <a name="smtp"></a> SMTP / Office 365 Considerations

*   Host: `smtp.office365.com`, Port: **587** (STARTTLS), authenticated SMTP enabled.
*   Use mailbox credentials (or **App Password** for MFA).
*   **From** must be the authenticated mailbox or a shared mailbox with **Send As** rights.
*   Message size limits apply (tenant configuration).
*   Prefer **AlternateView + Base64** for HTML robustness in transit. *(O365 guidance + widely documented incident context around the CU regression.)* [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

***

## <a name="security"></a> Security

*   Store secrets securely; minimize plaintext credentials in Task history.
*   Restrict access to the shim’s working folder and `dbmail_shim_log`.
*   Consider fixed SQL TCP ports for firewalls and deterministic connectivity.
*   Use SQL connection encryption per policy.

***

## <a name="troubleshooting"></a> Troubleshooting

**Database Mail broken after CU**

*   Confirm whether servers run **SQL 2022 CU23** or **SQL 2025 CU1**—both were temporarily unavailable due to a Database Mail defect; roll back or avoid per Microsoft guidance. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

**Items remain “unsent”**

*   Verify shim runs, targets are enabled, and fetch condition uses **`IN (0,3)`**.
*   Check for stale locks in `dbmail_shim_lock`.

**HTML body looks truncated**

*   Send via **AlternateView** (`text/html; charset=utf-8`) with **Base64** transfer encoding; avoid `Invoke‑Sqlcmd` options that truncate `NVARCHAR(MAX)`.

**Pre‑login handshake timeouts**

*   Validate listener’s port/IP is **ONLINE** and reachable; set `Connect Timeout=60; MultiSubnetFailover=True`. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)

**Insert into `sysmail_event_log` fails**

*   That view is read‑only; use `dbmail_shim_log`.

***

## <a name="runbook"></a> Operational Runbook

**Pending items**

```sql
SELECT COUNT(*) 
FROM msdb.dbo.sysmail_mailitems 
WHERE sent_status IN (0,3);
```

**Last 100 shim logs**

```sql
SELECT TOP (100) log_date, level, mailitem_id, description
FROM msdb.dbo.dbmail_shim_log
ORDER BY log_id DESC;
```

**Requeue a specific message (rare)**

```sql
UPDATE msdb.dbo.sysmail_mailitems
SET sent_status = 0
WHERE mailitem_id = <id>;

DELETE FROM dbo.dbmail_shim_lock WHERE mailitem_id = <id>;
```

***

## <a name="extensibility"></a> Extensibility

*   Add/remove endpoints in `targets.json`.
*   Per‑target overrides (batch, profile filtering).
*   Optional retry on `failed (2)` with cool‑offs / max attempts.
*   Telemetry counters per run for dashboards.
*   Per‑target SMTP overrides if needed.

***

## <a name="summary"></a> Summary

*   This shim is a **targeted workaround** for the **Database Mail breakage** introduced by **SQL Server 2022 CU23** and **SQL Server 2025 CU1**—both **temporarily withdrawn** due to the defect that prevents Database Mail from running. Use it **only** if you cannot roll back immediately and still need Database Mail functionality. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)
*   If Database Mail works normally in your environment, **do not** use this shim.

***

## <a name="references"></a> References

*   **Microsoft Learn — SQL Server 2022 CU23 (KB5074819)**: temporarily unavailable due to Database Mail issue; explicit warning and error text. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)
*   **Microsoft Learn — SQL Server 2025 CU1 (KB5074901)**: temporarily unavailable for the same Database Mail issue.
*   **Bob Ward (Microsoft)** — public advisory to uninstall CU23/CU1 if you need Database Mail.
*   **Community incident threads** confirming breakage and rollback outcomes. [\[support.zendesk.com\]](https://support.zendesk.com/hc/en-us/articles/8130298032538-Using-Microsoft-Exchange-Online-with-the-Authenticated-SMTP-Connector), [\[linkedin.com\]](https://www.linkedin.com/pulse/how-set-up-smtp-client-submission-joy-emeto-03nmf)


