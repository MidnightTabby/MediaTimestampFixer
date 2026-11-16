<#
.SYNOPSIS
    MediaTimestampFixer v0.81 - Digital Archive Timestamp & Metadata Aligner
.DESCRIPTION
    1. Priority 1 (Filename): Extracts start/end timestamps from filenames using global regex rules.
    2. Priority 2 (Metadata Fallback): If no timestamp exists in the filename, extracts CreateDate / DateTimeOriginal 
       from internal metadata (EXIF, QuickTime videos via ExifTool, and PDFs via iTextSharp / ExifTool).
    3. Updates filesystem properties: Date created (CreationTime) and Date modified (LastWriteTime).
.AUTHOR
    MidnightTabby
#>

# ==============================================================================
# 1. Initialization & Dependency Check
# ==============================================================================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExifToolPath = Join-Path $ScriptDir "exiftool.exe"
$ITextSharpPath = Join-Path $ScriptDir "itextsharp.dll"

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

    # Month Name Map (US English formats like NOV15-2027)
    $MonthMap = @{
        "JAN"=1; "FEB"=2; "MAR"=3; "APR"=4; "MAY"=5; "JUN"=6;
        "JUL"=7; "AUG"=8; "SEP"=9; "OCT"=10; "NOV"=11; "DEC"=12
    }

    # Pattern A: Start & End Range (e.g., 20230815_103000-20230815_103500 or 2023-08-15_10-30-00_to_10-35-00)
    if ($BaseName -match '(?<!\d)(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)\s*(?:[-~_]|to)\s*(?:(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?)?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)(?!\d)') {
        $StartDate = Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
        
        $EndYear  = if ($Matches[7]) { $Matches[7] } else { $Matches[1] }
        $EndMonth = if ($Matches[8]) { $Matches[8] } else { $Matches[2] }
        $EndDay   = if ($Matches[9]) { $Matches[9] } else { $Matches[3] }
        $EndDate  = Get-ValidDate -Year $EndYear -Month $EndMonth -Day $EndDay -Hour $Matches[10] -Minute $Matches[11] -Second $Matches[12]
    }
    # Pattern B: Standard YYYYMMDD_HHMMSS / YYYY-MM-DD HH.MM.SS (Smartphones, Dashcams, Screenshots)
    elseif ($BaseName -match '(?<!\d)(20\d{2}|199\d)[-._]?(0[1-9]|1[0-2])[-._]?(0[1-9]|[12]\d|3[01])[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d)(?!\d)') {
        $StartDate = Get-ValidDate -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
    }
    # Pattern C: Legacy Feature Phones (e.g., 080512_1430 or 080512_143022 -> YYMMDD_HHMM[SS])
    elseif ($BaseName -match '(?<!\d)(0[0-9]|1\d|2\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])[-_]([01]\d|2[0-3])([0-5]\d)([0-5]\d)?(?!\d)') {
        $FullYear = 2000 + [int]$Matches[1]
        $Sec = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $FullYear -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Sec
    }
    # Pattern D: US Month Name Format (e.g., NOV15-2027 or NOV15-2027_143000)
    elseif ($BaseName -match '(?i)\b(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[-._]?(0[1-9]|[12]\d|3[01])[-._]?(20\d{2}|199\d)(?:[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d))?') {
        $MNum = $MonthMap[$Matches[1].ToUpper()]
        $H = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $Min = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $S = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $Matches[3] -Month $MNum -Day $Matches[2] -Hour $H -Minute $Min -Second $S
    }
    # Pattern E: US Numeric Format MM-DD-YYYY
    elseif ($BaseName -match '(?<!\d)(0[1-9]|1[0-2])[-._](0[1-9]|[12]\d|3[01])[-._](20\d{2}|199\d)(?:[-._T ]?([01]\d|2[0-3])[-._:]?([0-5]\d)[-._:]?([0-5]\d))?(?!\d)') {
        $H = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        $Min = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $S = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $StartDate = Get-ValidDate -Year $Matches[3] -Month $Matches[1] -Day $Matches[2] -Hour $H -Minute $Min -Second $S
    }
    # Pattern F: Date Only YYYY-MM-DD or YYYYMMDD
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

# Parse PDF Date String (e.g., D:20230815103000+09'00')
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

# Priority 2A: Extract Metadata from PDF (iTextSharp -> ExifTool Fallback)
function Extract-TimestampFromPdf {
    param ([string]$FilePath)

    $Created = $null
    $Modified = $null

    # Try iTextSharp first
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
        } catch {
            # Silently fall back to ExifTool if PDF is encrypted or malformed
        } finally {
            if ($reader) { $reader.Close() }
        }
    }

    # Fallback to ExifTool for PDF if iTextSharp didn't get dates
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

# Priority 2B: Extract Metadata from Media/Videos/PDFs via ExifTool
function Extract-TimestampFromExifTool {
    param ([string]$FilePath)

    if (-not $UseExifTool) { return $null }

    # Query DateTimeOriginal, CreateDate, MediaCreateDate, ModifyDate in standardized format
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
            # Earliest valid tag as CreateDate, latest valid tag (or ModifyDate) as ModifyDate
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

# ==============================================================================
# 3. Main Execution Flow
# ==============================================================================
Clear-Host
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " 📸 Media Timestamp & Metadata Fixer v0.81 (by MidnightTabby)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " Rule: [1] Filename Timestamp (Priority) -> [2] Internal Metadata" -ForegroundColor DarkGray
Write-Host ""

$TargetFolder = Read-Host "Enter target folder path (e.g., D:\Photos\Chaos_Archive)"
$TargetFolder = $TargetFolder.Trim('"').Trim("'")

if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
    Write-Host "[ERROR] Folder not found: $TargetFolder" -ForegroundColor Red
    Pause
    exit
}

# Exclude script's own helper files if running inside the same directory
$ExcludeNames = @("MediaTimestampFixer_v0.80.ps1", "MediaTimestampFixer_v0.81.ps1", "exiftool.exe", "itextsharp.dll", "README.md")

$Files = Get-ChildItem -LiteralPath $TargetFolder -File -Recurse | Where-Object {
    $ExcludeNames -notcontains $_.Name -and $_.FullName -notmatch '\\exiftool_files\\' -and $_.FullName -notmatch '\\\.git\\'
}

Write-Host "`nFound $($Files.Count) target files. Starting analysis...`n" -ForegroundColor White

$CountUpdated = 0
$CountSkipped = 0

foreach ($File in $Files) {
    $Result = $null

    # Step 1: Priority 1 - Check Filename
    $Result = Extract-TimestampFromFilename -FileName $File.Name

    # Step 2: Priority 2 - Metadata Fallback (if filename had no timestamp)
    if (-not $Result) {
        if ($File.Extension -ieq ".pdf") {
            $Result = Extract-TimestampFromPdf -FilePath $File.FullName
        } else {
            $Result = Extract-TimestampFromExifTool -FilePath $File.FullName
        }
    }

    # Step 3: Apply to Filesystem Properties (Date created & Date modified)
    if ($Result) {
        try {
            $File.CreationTime  = $Result.Created
            $File.LastWriteTime = $Result.Modified

            Write-Host "[UPDATED] $($File.Name)" -ForegroundColor Green
            Write-Host "          Source   : $($Result.Source)" -ForegroundColor DarkCyan
            Write-Host "          Created  : $($Result.Created.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            Write-Host "          Modified : $($Result.Modified.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
            $CountUpdated++
        } catch {
            Write-Host "[ERROR]   Failed to update $($File.Name): $_" -ForegroundColor Red
        }
    } else {
        Write-Host "[SKIPPED] $($File.Name) (No valid date in filename or metadata)" -ForegroundColor DarkGray
        $CountSkipped++
    }
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " Summary: $CountUpdated updated, $CountSkipped skipped." -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Pause