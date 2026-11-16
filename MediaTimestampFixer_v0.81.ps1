<#
.SYNOPSIS
    MediaTimestampFixer v0.81 (With TSV Logging) - Digital Archive Timestamp & Metadata Aligner
.DESCRIPTION
    1. Priority 1 (Filename): Extracts start/end timestamps from filenames using global regex rules.
    2. Priority 2 (Metadata Fallback): If no timestamp exists in the filename, extracts CreateDate / DateTimeOriginal 
       from internal metadata (EXIF, QuickTime videos via ExifTool, and PDFs via iTextSharp / ExifTool).
    3. Updates filesystem properties: Date created (CreationTime) and Date modified (LastWriteTime).
    4. Logs all execution results to MediaTimestampFixer.log in TSV format.
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

# Check ExifTool
$UseExifTool = $false
if (Test-Path $ExifToolPath) {
    $UseExifTool = $true
} elseif (Get-Command "exiftool" -ErrorAction SilentlyContinue) {
    $ExifToolPath = "exiftool"
    $UseExifTool = $true
} else {
    Write-Warning "[WARN] exiftool.exe not found in script folder or PATH. Metadata fallback for media/videos will be limited."
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
    # If log file doesn't exist, create header first
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
Write-Host " 📸 Media Timestamp & Metadata Fixer v0.81 (by MidnightTabby)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Rule: [1] Filename Timestamp (Priority) -> [2] Internal Metadata" -ForegroundColor DarkGray
Write-Host ""

$TargetFolder = ""
while ([string]::IsNullOrWhiteSpace($TargetFolder)) {
    $InputPath = Read-Host "Enter target folder path (e.g., D:\Photos\Chaos_Archive)"
    $TargetFolder = $InputPath.Trim('"', "'", ' ')

    if ([string]::IsNullOrWhiteSpace($TargetFolder)) {
        Write-Host "[WARNING] Path cannot be empty. Please enter a valid folder path." -ForegroundColor Yellow
        continue
    }

    if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
        Write-Host "[ERROR] Folder not found or not a directory: $TargetFolder" -ForegroundColor Red
        $TargetFolder = ""
    }
}

$ExcludeNames = @("MediaTimestampFixer_v0.80.ps1", "MediaTimestampFixer_v0.81.ps1", "exiftool.exe", "itextsharp.dll", "README.md", "MediaTimestampFixer.log")

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

    # Step 2: Priority 2 - Metadata Fallback
    if (-not $Result) {
        if ($File.Extension -ieq ".pdf") {
            $Result = Extract-TimestampFromPdf -FilePath $File.FullName
        } else {
            $Result = Extract-TimestampFromExifTool -FilePath $File.FullName
        }
    }

    # Step 3: Apply to Filesystem Properties & Log
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

            # Write TSV Log (Updated)
            Write-LogEntry -Timestamp $ExecutionTimeStr -Status "UPDATED" -FilePath $File.FullName -Source $Result.Source -Created $CreatedStr -Modified $ModifiedStr

            $CountUpdated++
        } catch {
            Write-Host "[ERROR]   Failed to update $($File.Name): $_" -ForegroundColor Red
            Write-LogEntry -Timestamp $ExecutionTimeStr -Status "ERROR" -FilePath $File.FullName -Source "N/A" -Created "N/A" -Modified "N/A"
        }
    } else {
        Write-Host "[SKIPPED] $($File.Name) (No valid date in filename or metadata)" -ForegroundColor DarkGray

        # Write TSV Log (Skipped)
        Write-LogEntry -Timestamp $ExecutionTimeStr -Status "SKIPPED" -FilePath $File.FullName -Source "None" -Created "N/A" -Modified "N/A"

        $CountSkipped++
    }
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " Summary: $CountUpdated updated, $CountSkipped skipped." -ForegroundColor Cyan
Write-Host " Log saved to: $LogFilePath" -ForegroundColor DarkCyan
Write-Host "=================================================================" -ForegroundColor Cyan
Pause