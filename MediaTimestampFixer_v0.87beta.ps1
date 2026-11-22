<#
.SYNOPSIS
    MediaTimestampFixer v0.86beta - Digital Archive Timestamp & Metadata Aligner
.DESCRIPTION
    1. Priority 1 (Filename): Extracts start/end timestamps from filenames using global regex rules.
    2. Priority 2 (XML Sidecar): Detects 1-to-1 matching .xml sidecar files (e.g., Sony XDCAM, GoPro, Reolink)
       and extracts CreationDate / StartTime / EndTime.
    3. Priority 3 (Metadata Fallback): Extracts CreateDate / DateTimeOriginal and Duration from internal metadata
       via ExifTool, and PDFs via iTextSharp / ExifTool.
    4. Duration Offset: Automatically adds video Duration to calculate Modified (end time) when applicable.
    5. Updates filesystem properties: Date created (CreationTime) and Date modified (LastWriteTime).
    6. Exports execution reports simultaneously in 3 formats: TSV, HTML (inline CSS3), and JSON.
.AUTHOR
    MidnightTabby
#>

param (
    [string]$TargetFolder = "",
    [string]$OutputBasePath = ""
)

# ==============================================================================
# 1. Initialization & Dependency Check
# ==============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = (Get-Location).Path }

$ExifToolPath   = Join-Path $ScriptDir "exiftool.exe"
$ITextSharpPath = Join-Path $ScriptDir "itextsharp.dll"

if ([string]::IsNullOrWhiteSpace($OutputBasePath)) {
    $OutputBasePath = Join-Path $ScriptDir "MediaTimestampFixer_report"
}

$BaseWithoutExt = [System.IO.Path]::Combine(
    ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutputBasePath))),
    ([System.IO.Path]::GetFileNameWithoutExtension($OutputBasePath))
)

$TsvPath  = "$BaseWithoutExt.tsv"
$HtmlPath = "$BaseWithoutExt.html"
$JsonPath = "$BaseWithoutExt.json"

$UseExifTool = $false
if (Test-Path -LiteralPath $ExifToolPath) {
    $UseExifTool = $true
} elseif (Get-Command "exiftool" -ErrorAction SilentlyContinue) {
    $ExifToolPath = "exiftool"
    $UseExifTool = $true
} else {
    Write-Warning "[WARN] exiftool.exe not found in script folder or PATH. Metadata fallback for media/videos will be limited."
}

$UseITextSharp = $false
if (Test-Path -LiteralPath $ITextSharpPath) {
    try {
        Add-Type -Path $ITextSharpPath -ErrorAction Stop
        $UseITextSharp = $true
    } catch {
        Write-Warning "[WARN] Failed to load itextsharp.dll. Will fall back to ExifTool for PDFs."
    }
}

# ==============================================================================
# 2. Helper Functions
# ==============================================================================

function Write-Utf8File {
    param (
        [string]$Path,
        [string]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function ConvertTo-HtmlSafe {
    param ([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-ValidDate {
    param (
        [int]$Year, [int]$Month, [int]$Day,
        [int]$Hour = 0, [int]$Minute = 0, [int]$Second = 0
    )
    try {
        if ($Year -lt 1990 -or $Year -gt 2099) { return $null }
        return [datetime]::new($Year, $Month, $Day, $Hour, $Minute, $Second)
    } catch {
        return $null
    }
}

function Extract-TimestampFromFilename {
    param ([string]$FileName)

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $StartDate = $null
    $EndDate = $null

    $MonthMap = @{
        "JAN"=1; "FEB"=2; "MAR"=3; "APR"=4; "MAY"=5; "JUN"=6;
        "JUL"=7; "AUG"=8; "SEP"=9; "OCT"=10; "NOV"=11; "DEC"=12
    }

    if ($BaseName -match '(?<!\d)(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)\s*(?:[-~_]|to)\s*(?:(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?)?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)(?!\d)') {
        $StartDate = Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
        $EndYear  = if ($Matches[7]) { $Matches[7] } else { $Matches[1] }
        $EndMonth = if ($Matches[8]) { $Matches[8] } else { $Matches[2] }
        $EndDay   = if ($Matches[9]) { $Matches[9] } else { $Matches[3] }
        $EndDate  = Get-ValidDate -Year $EndYear -Month $EndMonth -Day $EndDay -Hour $Matches[10] -Minute $Matches[11] -Second $Matches[12]
    }
    elseif ($BaseName -match '(?<!\d)(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)(?!\d)') {
        $StartDate = Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
    }
    elseif ($BaseName -match '(?<!\d)(0[0-9]|1\d|2\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_]([01]\d|2[0-3])([0-5]\d)([0-5]\d)?(?!\d)') {
        $FullYear = 2000 + [int]$Matches[1]
        $Sec = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $FullYear -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Sec
    }
    elseif ($BaseName -match '(?i)\b(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[-._]?(0[1-9]|[12]\d|3[01])[-._]?(20\d{2}|199\d)(?:[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d))?') {
        $MNum = $MonthMap[$Matches[1].ToUpper()]
        $H = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $Min = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $S = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $Matches[3] -Month $MNum -Day $Matches[2] -Hour $H -Minute $Min -Second $S
    }
    elseif ($BaseName -match '(?<!\d)(0[1-9]|1[0-2])[-._](0[1-9]|[12]\d|3[01])[-._](20\d{2}|199\d)(?:[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d))?(?!\d)') {
        $H = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $Min = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $S = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $Matches[3] -Month $Matches[1] -Day $Matches[2] -Hour $H -Minute $Min -Second $S
    }
    elseif ($BaseName -match '(?<!\d)(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])(?!\d)') {
        $StartDate = Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3]
    }

    if ($StartDate) {
        if (-not $EndDate) { $EndDate = $StartDate }
        return [PSCustomObject]@{
            Created  = $StartDate
            Modified = $EndDate
            Source   = "Filename"
        }
    }
    return $null
}

function Parse-XmlDateString {
    param ([string]$RawDateStr)
    if ([string]::IsNullOrWhiteSpace($RawDateStr)) { return $null }
    $trimmed = $RawDateStr.Trim()

    if ($trimmed -match '^(\d{4})[-/](\d{2})[-/](\d{2})[T ](\d{2}):(\d{2}):(\d{2})') {
        return Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
    }
    elseif ($trimmed -match '^(\d{4})[-/](\d{2})[-/](\d{2})$') {
        return Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3]
    }
    return $null
}

function Extract-TimestampFromXml {
    param ([string]$XmlFilePath)

    if (-not (Test-Path -LiteralPath $XmlFilePath)) { return $null }

    try {
        [xml]$xmlDoc = Get-Content -LiteralPath $XmlFilePath -Encoding UTF8 -ErrorAction Stop
        $StartDate = $null
        $EndDate = $null

        $sonyNode = $xmlDoc.SelectSingleNode("//*[local-name()='CreationDate']")
        if ($sonyNode) {
            $val = if ($sonyNode.GetAttribute("value")) { $sonyNode.GetAttribute("value") } else { $sonyNode.InnerText }
            $StartDate = Parse-XmlDateString -RawDateStr $val
        }

        if (-not $StartDate) {
            $startNode = $xmlDoc.SelectSingleNode("//*[local-name()='StartTime' or local-name()='CreateDate' or local-name()='DateTimeOriginal' or local-name()='RecordingStart']")
            if ($startNode) {
                $val = if ($startNode.GetAttribute("value")) { $startNode.GetAttribute("value") } else { $startNode.InnerText }
                $StartDate = Parse-XmlDateString -RawDateStr $val
            }

            $endNode = $xmlDoc.SelectSingleNode("//*[local-name()='EndTime' or local-name()='ModifyDate' or local-name()='RecordingEnd']")
            if ($endNode) {
                $val = if ($endNode.GetAttribute("value")) { $endNode.GetAttribute("value") } else { $endNode.InnerText }
                $EndDate = Parse-XmlDateString -RawDateStr $val
            }
        }

        if ($StartDate) {
            if (-not $EndDate) { $EndDate = $StartDate }
            return [PSCustomObject]@{
                Created  = $StartDate
                Modified = $EndDate
                Source   = "XML Sidecar"
            }
        }
    } catch {}
    return $null
}

function Parse-PdfDateString {
    param ([string]$RawPdfDate)
    if ([string]::IsNullOrWhiteSpace($RawPdfDate)) { return $null }
    if ($RawPdfDate -match 'D:(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?') {
        $H = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $M = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $S = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        return Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $H -Minute $M -Second $S
    }
    return $null
}

function Extract-TimestampFromPdf {
    param ([string]$FilePath)
    $Created = $null
    $Modified = $null

    if ($UseITextSharp) {
        $reader = $null
        try {
            $reader = New-Object iTextSharp.text.pdf.PdfReader($FilePath)
            $info = $reader.Info
            if ($info.ContainsKey("CreationDate")) {
                $Created = Parse-PdfDateString -RawPdfDate $info["CreationDate"]
            }
            if ($info.ContainsKey("ModDate")) {
                $Modified = Parse-PdfDateString -RawPdfDate $info["ModDate"]
            }
        } catch {} finally {
            if ($reader) { $reader.Close() }
        }
    }

    if (-not $Created -and -not $Modified -and $UseExifTool) {
        $meta = Extract-TimestampFromExifTool -FilePath $FilePath
        if ($meta) { return $meta }
    }

    if ($Created -or $Modified) {
        if (-not $Created)  { $Created = $Modified }
        if (-not $Modified) { $Modified = $Created }
        return [PSCustomObject]@{
            Created  = $Created
            Modified = $Modified
            Source   = "PDF Metadata"
        }
    }
    return $null
}

function Extract-TimestampFromExifTool {
    param ([string]$FilePath)
    if (-not $UseExifTool) { return $null }

    $Args = @(
        "-s3", "-d", "%Y-%m-%d %H:%M:%S",
        "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-ModifyDate", "-Duration",
        $FilePath
    )

    try {
        $Output = & $ExifToolPath @Args 2>$null
        $ValidDates = @()
        $DurationSeconds = 0.0

        foreach ($line in $Output) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' -and $trimmed -notmatch '^0000') {
                try {
                    $dt = [datetime]::ParseExact($trimmed, "yyyy-MM-dd HH:mm:ss", $null)
                    if ($dt.Year -ge 1990 -and $dt.Year -le 2099) {
                        $ValidDates += $dt
                    }
                } catch {}
            }
            elseif ($trimmed -match '^[\d\.:]+$') {
                if ($trimmed -match ':') {
                    $parts = $trimmed.Split(':')
                    if ($parts.Length -eq 3) {
                        $DurationSeconds = [double]$parts[0] * 3600 + [double]$parts[1] * 60 + [double]$parts[2]
                    } elseif ($parts.Length -eq 2) {
                        $DurationSeconds = [double]$parts[0] * 60 + [double]$parts[1]
                    }
                } else {
                    $parsedSec = 0.0
                    if ([double]::TryParse($trimmed, [ref]$parsedSec)) {
                        if ($parsedSec -gt 0 -and $parsedSec -lt 86400) {
                            $DurationSeconds = $parsedSec
                        }
                    }
                }
            }
        }

        if ($ValidDates.Count -gt 0) {
            $Created = ($ValidDates | Sort-Object)[0]
            $Modified = ($ValidDates | Sort-Object)[-1]

            if ($Created -eq $Modified -and $DurationSeconds -gt 0) {
                $Modified = $Created.AddSeconds($DurationSeconds)
            }

            return [PSCustomObject]@{
                Created  = $Created
                Modified = $Modified
                Source   = "Internal Metadata (ExifTool)"
            }
        }
    } catch {}
    return $null
}

function Export-FixerReports {
    param (
        [array]$Entries,
        [string]$TargetDir,
        [string]$ExecutionTime,
        [string]$OutTsv,
        [string]$OutHtml,
        [string]$OutJson
    )

    # 1. TSV Output
    $tsvLines = New-Object System.Collections.Generic.List[string]
    $tsvLines.Add("Timestamp`tStatus`tFilePath`tSource`tCreated`tModified")
    foreach ($e in $Entries) {
        $tsvLines.Add("$($e.Timestamp)`t$($e.Status)`t$($e.FilePath)`t$($e.Source)`t$($e.Created)`t$($e.Modified)")
    }
    Write-Utf8File -Path $OutTsv -Content ($tsvLines -join "`r`n")

    # 2. JSON Output
    $updatedCount = ($Entries | Where-Object { $_.Status -eq "UPDATED" }).Count
    $skippedCount = ($Entries | Where-Object { $_.Status -eq "SKIPPED" }).Count
    $errorCount   = ($Entries | Where-Object { $_.Status -eq "ERROR" }).Count

    $jsonPayload = [PSCustomObject]@{
        tool          = "MediaTimestampFixer"
        version       = "v0.86beta"
        generated_at  = $ExecutionTime
        target_folder = $TargetDir
        summary       = [PSCustomObject]@{
            total   = $Entries.Count
            updated = $updatedCount
            skipped = $skippedCount
            error   = $errorCount
        }
        items         = $Entries
    }
    $jsonText = $jsonPayload | ConvertTo-Json -Depth 5
    Write-Utf8File -Path $OutJson -Content $jsonText

    # 3. HTML Output (Inline CSS3)
    $rowsBuilder = New-Object System.Text.StringBuilder
    foreach ($e in $Entries) {
        $badgeClass = switch ($e.Status) {
            "UPDATED" { "badge-ok" }
            "SKIPPED" { "badge-skip" }
            "ERROR"   { "badge-err" }
            default   { "badge-skip" }
        }
        [void]$rowsBuilder.AppendLine("        <tr>")
        [void]$rowsBuilder.AppendLine("          <td class='mono'>$(ConvertTo-HtmlSafe $e.Timestamp)</td>")
        [void]$rowsBuilder.AppendLine("          <td><span class='badge $badgeClass'>$(ConvertTo-HtmlSafe $e.Status)</span></td>")
        [void]$rowsBuilder.AppendLine("          <td class='path' title='$(ConvertTo-HtmlSafe $e.FilePath)'>$(ConvertTo-HtmlSafe $e.FilePath)</td>")
        [void]$rowsBuilder.AppendLine("          <td>$(ConvertTo-HtmlSafe $e.Source)</td>")
        [void]$rowsBuilder.AppendLine("          <td class='mono'>$(ConvertTo-HtmlSafe $e.Created)</td>")
        [void]$rowsBuilder.AppendLine("          <td class='mono'>$(ConvertTo-HtmlSafe $e.Modified)</td>")
        [void]$rowsBuilder.AppendLine("        </tr>")
    }

    $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MediaTimestampFixer v0.86beta Report</title>
  <style>
    :root {
      --bg: #f6f8fa;
      --surface: #ffffff;
      --surface-alt: #f0f4f8;
      --text: #1f2328;
      --muted: #59636e;
      --border: #d0d7de;
      --accent: #0969da;
      --ok-bg: #dafbe1;
      --ok-fg: #116329;
      --skip-bg: #eef1f4;
      --skip-fg: #57606a;
      --err-bg: #ffebe9;
      --err-fg: #cf222e;
      --radius: 10px;
      --shadow: 0 4px 16px rgba(31, 35, 40, 0.06);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --surface: #161b22;
        --surface-alt: #1f2630;
        --text: #e6edf3;
        --muted: #8b949e;
        --border: #30363d;
        --accent: #58a6ff;
        --ok-bg: rgba(46, 160, 67, 0.2);
        --ok-fg: #3fb950;
        --skip-bg: rgba(139, 148, 158, 0.18);
        --skip-fg: #8b949e;
        --err-bg: rgba(248, 81, 73, 0.2);
        --err-fg: #ff7b72;
        --shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 24px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: linear-gradient(180deg, var(--bg) 0%, var(--surface-alt) 100%);
      color: var(--text);
      line-height: 1.5;
    }
    .container {
      max-width: 1360px;
      margin: 0 auto;
    }
    .header {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 20px 24px;
      box-shadow: var(--shadow);
      margin-bottom: 18px;
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      gap: 12px;
    }
    .header h1 {
      margin: 0 0 4px 0;
      font-size: 1.35rem;
      letter-spacing: -0.01em;
    }
    .meta {
      color: var(--muted);
      font-size: 0.88rem;
    }
    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
      gap: 12px;
      margin-bottom: 18px;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 16px;
      box-shadow: var(--shadow);
      transition: transform 0.15s ease;
    }
    .card:hover { transform: translateY(-2px); }
    .card .label { font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
    .card .value { font-size: 1.6rem; font-weight: 700; margin-top: 4px; }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 14px;
    }
    .search-input {
      flex: 1 1 280px;
      padding: 10px 14px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text);
      font-size: 0.92rem;
    }
    .search-input:focus {
      outline: 2px solid var(--accent);
      outline-offset: 1px;
    }
    .table-wrap {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      box-shadow: var(--shadow);
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.88rem;
    }
    th, td {
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      text-align: left;
      white-space: nowrap;
    }
    th {
      background: var(--surface-alt);
      font-weight: 600;
      position: sticky;
      top: 0;
    }
    tbody tr:hover {
      background: var(--surface-alt);
    }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.83rem; }
    .path { max-width: 460px; overflow: hidden; text-overflow: ellipsis; }
    .badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 0.76rem;
      font-weight: 600;
    }
    .badge-ok { background: var(--ok-bg); color: var(--ok-fg); }
    .badge-skip { background: var(--skip-bg); color: var(--skip-fg); }
    .badge-err { background: var(--err-bg); color: var(--err-fg); }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1>MediaTimestampFixer v0.86beta Report</h1>
        <div class="meta">Target: $(ConvertTo-HtmlSafe $TargetDir)</div>
      </div>
      <div class="meta">Generated: $(ConvertTo-HtmlSafe $ExecutionTime)</div>
    </div>

    <div class="stats">
      <div class="card"><div class="label">Total Files</div><div class="value">$($Entries.Count)</div></div>
      <div class="card"><div class="label">Updated</div><div class="value">$updatedCount</div></div>
      <div class="card"><div class="label">Skipped</div><div class="value">$skippedCount</div></div>
      <div class="card"><div class="label">Errors</div><div class="value">$errorCount</div></div>
    </div>

    <div class="toolbar">
      <input id="filterInput" class="search-input" type="search" placeholder="Filter by file path, source, or status..." oninput="filterRows()" />
    </div>

    <div class="table-wrap">
      <table id="reportTable">
        <thead>
          <tr>
            <th>Timestamp</th>
            <th>Status</th>
            <th>FilePath</th>
            <th>Source</th>
            <th>Created</th>
            <th>Modified</th>
          </tr>
        </thead>
        <tbody>
$($rowsBuilder.ToString())
        </tbody>
      </table>
    </div>
  </div>

  <script>
    function filterRows() {
      const q = document.getElementById('filterInput').value.toLowerCase();
      const rows = document.querySelectorAll('#reportTable tbody tr');
      rows.forEach(tr => {
        const match = tr.textContent.toLowerCase().includes(q);
        tr.style.display = match ? '' : 'none';
      });
    }
  </script>
</body>
</html>
"@
    Write-Utf8File -Path $OutHtml -Content $htmlContent
}

# ==============================================================================
# 3. Main Execution Flow
# ==============================================================================
Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " 📸 Media Timestamp & Metadata Fixer v0.86beta (MidnightTabby)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Rule: [1] Filename -> [2] XML Sidecar -> [3] Metadata + Duration Offset" -ForegroundColor DarkGray
Write-Host " Outputs: TSV + HTML (Inline CSS3) + JSON" -ForegroundColor DarkGray
Write-Host ""

if ([string]::IsNullOrWhiteSpace($TargetFolder)) {
    while ([string]::IsNullOrWhiteSpace($TargetFolder)) {
        $InputPath = Read-Host "Enter target folder path (Leave blank to use script folder)"
        $TrimmedInput = $InputPath.Trim('"', "'", ' ')

        if ([string]::IsNullOrWhiteSpace($TrimmedInput)) {
            $TargetFolder = $ScriptDir
            Write-Host "[INFO] Using script directory as target: $TargetFolder" -ForegroundColor Yellow
            break
        }

        if (-not (Test-Path -LiteralPath $TrimmedInput -PathType Container)) {
            Write-Host "[ERROR] Folder not found or not a directory: $TrimmedInput" -ForegroundColor Red
            $TargetFolder = ""
        } else {
            $TargetFolder = $TrimmedInput
        }
    }
}

$ExcludeNames = @(
    "MediaTimestampFixer_v0.80.ps1", "MediaTimestampFixer_v0.81.ps1",
    "MediaTimestampFixer_v0.82.ps1", "MediaTimestampFixer_v0.83.ps1",
    "MediaTimestampFixer_v0.84beta.ps1", "MediaTimestampFixer_v0.85beta.ps1",
    "MediaTimestampFixer_v0.86beta.ps1",
    "exiftool.exe", "itextsharp.dll", "README.md", "MediaTimestampFixer.log"
)

$Files = Get-ChildItem -LiteralPath $TargetFolder -File -Recurse | Where-Object {
    $ExcludeNames -notcontains $_.Name -and $_.FullName -notmatch '\\exiftool_files\\' -and $_.FullName -notmatch '\\\.git\\'
}

Write-Host "`nFound $($Files.Count) target files. Starting analysis...`n" -ForegroundColor White

$CountUpdated = 0
$CountSkipped = 0
$ExecutionTimeStr = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$ReportEntries = New-Object System.Collections.Generic.List[PSObject]

foreach ($File in $Files) {
    $Result = $null

    # Step 1: Priority 1 - Check Filename
    $Result = Extract-TimestampFromFilename -FileName $File.Name

    # Step 2: Priority 2 - XML Sidecar Matching
    if (-not $Result) {
        if ($File.Extension -ieq ".xml") {
            $Result = Extract-TimestampFromXml -XmlFilePath $File.FullName
            if ($Result) { $Result.Source = "XML Metadata (Self)" }
        } else {
            $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            $SidecarXml = Get-ChildItem -LiteralPath $File.DirectoryName -File | Where-Object {
                $_.Extension -ieq ".xml" -and [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $BaseName
            } | Select-Object -First 1

            if ($SidecarXml) {
                $Result = Extract-TimestampFromXml -XmlFilePath $SidecarXml.FullName
            }
        }
    }

    # Step 3: Priority 3 - Internal Metadata Fallback (PDF / ExifTool with Duration Offset)
    if (-not $Result) {
        if ($File.Extension -ieq ".pdf") {
            $Result = Extract-TimestampFromPdf -FilePath $File.FullName
        } else {
            $Result = Extract-TimestampFromExifTool -FilePath $File.FullName
        }
    }

    # Step 4: Apply to Filesystem Properties & Record Entry
    if ($Result) {
        try {
            $File.CreationTime  = $Result.Created
            $File.LastWriteTime = $Result.Modified

            $CreatedStr  = $Result.Created.ToString('yyyy-MM-dd HH:mm:ss')
            $ModifiedStr = $Result.Modified.ToString('yyyy-MM-dd HH:mm:ss')

            Write-Host "[UPDATED] $($File.Name)" -ForegroundColor Green
            Write-Host "          Source   : $($Result.Source)" -ForegroundColor DarkCyan
            Write-Host "          Created  : $CreatedStr" -ForegroundColor Gray
            Write-Host "          Modified : $ModifiedStr" -ForegroundColor Gray

            $ReportEntries.Add([PSCustomObject]@{
                Timestamp = $ExecutionTimeStr
                Status    = "UPDATED"
                FilePath  = $File.FullName
                Source    = $Result.Source
                Created   = $CreatedStr
                Modified  = $ModifiedStr
            })

            $CountUpdated++
        } catch {
            Write-Host "[ERROR]   Failed to update $($File.Name): $_" -ForegroundColor Red
            $ReportEntries.Add([PSCustomObject]@{
                Timestamp = $ExecutionTimeStr
                Status    = "ERROR"
                FilePath  = $File.FullName
                Source    = "N/A"
                Created   = "N/A"
                Modified  = "N/A"
            })
        }
    } else {
        Write-Host "[SKIPPED] $($File.Name) (No valid date in filename, XML sidecar, or metadata)" -ForegroundColor DarkGray
        $ReportEntries.Add([PSCustomObject]@{
            Timestamp = $ExecutionTimeStr
            Status    = "SKIPPED"
            FilePath  = $File.FullName
            Source    = "None"
            Created   = "N/A"
            Modified  = "N/A"
        })
        $CountSkipped++
    }
}

Export-FixerReports `
    -Entries $ReportEntries.ToArray() `
    -TargetDir $TargetFolder `
    -ExecutionTime $ExecutionTimeStr `
    -OutTsv $TsvPath `
    -OutHtml $HtmlPath `
    -OutJson $JsonPath

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " Summary: $CountUpdated updated, $CountSkipped skipped." -ForegroundColor Cyan
Write-Host " TSV  saved to: $TsvPath" -ForegroundColor DarkCyan
Write-Host " HTML saved to: $HtmlPath" -ForegroundColor DarkCyan
Write-Host " JSON saved to: $JsonPath" -ForegroundColor DarkCyan
Write-Host "=================================================================" -ForegroundColor Cyan
Pause