<#
.SYNOPSIS
    MediaTimestampFixer v0.86beta - Digital Archive Timestamp & Metadata Aligner
.DESCRIPTION
    1. Priority 1 (Filename): Extracts start/end timestamps from filenames using global regex rules.
    2. Priority 2 (XML Sidecar): Detects 1-to-1 matching .xml sidecar files (e.g., Sony XDCAM, GoPro, Reolink)
       and extracts CreationDate / StartTime / EndTime.
    3. Priority 3 (Metadata Fallback): Extracts CreateDate / DateTimeOriginal from internal metadata 
       via ExifTool, and PDFs via iTextSharp / ExifTool.
    4. Hybrid Video Duration Offset: For video files where Created and Modified are identical 
       (even when matched via Filename or XML Sidecar), queries ExifTool for exact numeric Duration 
       and adds it to calculate the true Modified (end time) timestamp.
    5. Updates filesystem properties: Date created (CreationTime) and Date modified (LastWriteTime).
    6. Logs all execution results to MediaTimestampFixer.log in TSV format.
.AUTHOR
    MidnightTabby
#>

# ==============================================================================
# 1. Initialization & Dependency Check
# ==============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExifToolPath = Join-Path $ScriptDir "exiftool.exe"
$ITextSharpPath = Join-Path $ScriptDir "itextsharp.dll"
$LogFilePath = Join-Path $ScriptDir "MediaTimestampFixer.log"

$VideoExtensions = @(".mp4", ".mov", ".mkv", ".avi", ".m4v", ".3gp", ".mts", ".m2ts", ".wmv", ".flv", ".webm")

# Check ExifTool
$UseExifTool = $false
if (Test-Path $ExifToolPath) {
    $UseExifTool = $true
} elseif (Get-Command "exiftool" -ErrorAction SilentlyContinue) {
    $ExifToolPath = "exiftool"
    $UseExifTool = $true
} else {
    Write-Warning "[WARN] exiftool.exe not found in script folder or PATH. Metadata fallback and video duration offset will be limited."
}

# Check iTextSharp
$UseITextSharp = $false
if (Test-Path $ITextSharpPath) {
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

# Standalone helper to extract exact numeric Duration (in seconds) via ExifTool -n
function Get-VideoDurationSeconds {
    param ([string]$FilePath)
    if (-not $UseExifTool) { return 0.0 }

    try {
        # -n outputs raw numeric values (e.g., 45.12 instead of "45.12 s" or "0:00:45")
        $rawDuration = & $ExifToolPath -s3 -n -Duration $FilePath 2>$null
        if ($rawDuration) {
            $trimmed = ($rawDuration | Select-Object -First 1).ToString().Trim()
            $parsedSec = 0.0
            if ([double]::TryParse($trimmed, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSec)) {
                if ($parsedSec -gt 0 -and $parsedSec -lt 86400) {
                    return $parsedSec
                }
            }
        }
    } catch {}
    return 0.0
}

# Priority 1: Extract Start & End Timestamps from Filename
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

# Helper to normalize ISO-8601 or standard date strings from XML
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

# Priority 2: Extract Timestamp from 1-to-1 XML Sidecar
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
        "-DateTimeOriginal", "-CreateDate", "-MediaCreateDate", "-ModifyDate",
        $FilePath
    )

    try {
        $Output = & $ExifToolPath @Args 2>$null
        $ValidDates = @()

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
        }

        if ($ValidDates.Count -gt 0) {
            $Created = ($ValidDates | Sort-Object)[0]
            $Modified = ($ValidDates | Sort-Object)[-1]

            return [PSCustomObject]@{
                Created  = $Created
                Modified = $Modified
                Source   = "Internal Metadata (ExifTool)"
            }
        }
    } catch {}
    return $null
}

# Write Log Helper (TSV Format)
function Write-LogEntry {
    param (
        [string]$Timestamp,
        [string]$Status,
        [string]$FilePath,
        [string]$Source,
        [string]$Created,
        [string]$Modified
    )
    if (-not (Test-Path $LogFilePath)) {
        "Timestamp`tStatus`tFilePath`tSource`tCreated`tModified" | Out-File -FilePath $LogFilePath -Encoding utf8
    }
    "$Timestamp`t$Status`t$FilePath`t$Source`t$Created`t$Modified" | Out-File -FilePath $LogFilePath -Append -Encoding utf8
}

# ==============================================================================
# 3. Main Execution Flow
# ==============================================================================
Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " 📸 Media Timestamp & Metadata Fixer v0.86beta (MidnightTabby)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Rule: [1] Filename -> [2] XML Sidecar -> [3] Metadata + Duration Offset" -ForegroundColor DarkGray
Write-Host ""

$TargetFolder = ""
while ([string]::IsNullOrWhiteSpace($TargetFolder)) {
    $InputPath = Read-Host "Enter target folder path (Leave blank to use script folder)"
    $TrimmedInput = $InputPath.Trim('"', "'", ' ')

    if ([string]::IsNullOrWhiteSpace($TrimmedInput)) {
        $TargetFolder = $ScriptDir
        Write-Host "[INFO] Using script directory as target: $TargetFolder" -ForegroundColor Yellow
        break
    }

    $TargetFolder = $TrimmedInput

    if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
        Write-Host "[ERROR] Folder not found or not a directory: $TargetFolder" -ForegroundColor Red
        $TargetFolder = ""
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

    # Step 3: Priority 3 - Internal Metadata Fallback (PDF / ExifTool)
    if (-not $Result) {
        if ($File.Extension -ieq ".pdf") {
            $Result = Extract-TimestampFromPdf -FilePath $File.FullName
        } else {
            $Result = Extract-TimestampFromExifTool -FilePath $File.FullName
        }
    }

    # Step 3.5: Hybrid Video Duration Offset
    # If a video file has identical Created and Modified timestamps (e.g., matched from Filename or XML start time only),
    # query ExifTool for its Duration and add it to Modified.
    if ($Result -and ($VideoExtensions -contains $File.Extension.ToLower())) {
        if ($Result.Created -eq $Result.Modified) {
            $durSec = Get-VideoDurationSeconds -FilePath $File.FullName
            if ($durSec -gt 0) {
                $Result.Modified = $Result.Created.AddSeconds([math]::Round($durSec))
                $Result.Source = "$($Result.Source) + Duration"
            }
        }
    }

    # Step 4: Apply to Filesystem Properties & Log
    if ($Result) {
        try {
            $File.CreationTime  = $Result.Created
            $File.LastWriteTime = $Result.Modified

            $CreatedStr = $Result.Created.ToString('yyyy-MM-dd HH:mm:ss')
            $ModifiedStr = $Result.Modified.ToString('yyyy-MM-dd HH:mm:ss')

            Write-Host "[UPDATED] $($File.Name)" -ForegroundColor Green
            Write-Host "          Source   : $($Result.Source)" -ForegroundColor DarkCyan
            Write-Host "          Created  : $CreatedStr" -ForegroundColor Gray
            Write-Host "          Modified : $ModifiedStr" -ForegroundColor Gray

            Write-LogEntry -Timestamp $ExecutionTimeStr -Status "UPDATED" -FilePath $File.FullName -Source $Result.Source -Created $CreatedStr -Modified $ModifiedStr

            $CountUpdated++
        } catch {
            Write-Host "[ERROR]   Failed to update $($File.Name): $_" -ForegroundColor Red
            Write-LogEntry -Timestamp $ExecutionTimeStr -Status "ERROR" -FilePath $File.FullName -Source "N/A" -Created "N/A" -Modified "N/A"
        }
    } else {
        Write-Host "[SKIPPED] $($File.Name) (No valid date in filename, XML sidecar, or metadata)" -ForegroundColor DarkGray
        Write-LogEntry -Timestamp $ExecutionTimeStr -Status "SKIPPED" -FilePath $File.FullName -Source "None" -Created "N/A" -Modified "N/A"
        $CountSkipped++
    }
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " Summary: $CountUpdated updated, $CountSkipped skipped." -ForegroundColor Cyan
Write-Host " Log saved to: $LogFilePath" -ForegroundColor DarkCyan
Write-Host "=================================================================" -ForegroundColor Cyan
Pause