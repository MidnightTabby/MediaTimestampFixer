<#
.SYNOPSIS
    Media Timestamp & Metadata Fixer v0.80 (MidnightTabby Edition)
    - All-in-One Integrated Script (No external JSON required)
    - PDF Path-Error Free Edition (Bypasses ExifTool multibyte/CP932 directory path glitches by parsing PDF dates from safe local filenames/patterns)
    - 8.3 Short Path Translation for Media Files
    - Hybrid Priority Logic:
        * Images & Videos: Filename-First Priority -> ExifTool (ShortPath)
        * PDFs & Documents: Filename/Pattern-First Priority (Zero external path dependency, lightning fast and error-free)
    - Fully English UI, comments, and log output for global/US market
#>

# ---------------------------------------------------------
# 0. INITIALIZATION & CONFIGURATION
# ---------------------------------------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# --- [USER CONFIGURATION] ---
$ManualOffsetHours      = 0                         
$EnableUS_DSTCorrection = $false                    
$TargetUSTimeZone       = "Eastern Standard Time"   
# --------------------------------------------------

$targetDir = $PSScriptRoot
if (-not $targetDir) { $targetDir = Get-Location }
$targetDir = [System.IO.Path]::GetFullPath($targetDir)

$exifToolName = "exiftool.exe"
$exifToolCmd = Join-Path $targetDir $exifToolName
$logPath = Join-Path $targetDir "MediaTimestampFixer.log"

# Windows 8.3 Short Path API for multibyte safety
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NativeMethods {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint GetShortPathName(string lpszLongPath, StringBuilder lpszShortPath, uint cchBuffer);
}
"@

function Get-ShortPath {
    param([string]$longPath)
    $sb = New-Object System.Text.StringBuilder 260
    $res = [NativeMethods]::GetShortPathName($longPath, $sb, $sb.Capacity)
    if ($res -gt 0) { return $sb.ToString() }
    return $longPath
}

function Write-Log {
    param([string]$Level, [string]$Target, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "$timestamp`t[$Level]`t$Target`t$Message"
    Add-Content -Path $logPath -Value $logLine -Encoding UTF8
    
    switch ($Level) {
        "INFO"         { Write-Host $logLine -ForegroundColor Cyan }
        "EXIF"         { Write-Host $logLine -ForegroundColor Green }
        "METADATA"     { Write-Host $logLine -ForegroundColor Green }
        "XML_SIDECAR"  { Write-Host $logLine -ForegroundColor Green }
        "FILENAME"     { Write-Host $logLine -ForegroundColor Yellow }
        "PDF"          { Write-Host $logLine -ForegroundColor Magenta }
        "DST"          { Write-Host $logLine -ForegroundColor Magenta }
        "WARN"         { Write-Host $logLine -ForegroundColor DarkYellow }
        "ERROR"        { Write-Host $logLine -ForegroundColor Red }
        default        { Write-Host $logLine }
    }
}

Clear-Host
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "     Media Timestamp & Metadata Fixer v0.80       " -ForegroundColor Cyan
Write-Host "     Developed by MidnightTabby | PDF Safe Mode   " -ForegroundColor Cyan
Write-Host "     Target Directory: $targetDir                 " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

Write-Log "INFO" "SYSTEM" "START Processing v0.80 (PDF Path-Error Free Edition)..."

if (-not (Test-Path $exifToolCmd)) {
    Write-Log "ERROR" "SYSTEM" "exiftool.exe not found in target directory: $exifToolCmd"
    Write-Host "Exiting. Please place exiftool.exe in the script directory." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# ---------------------------------------------------------
# 1. FILE DISCOVERY
# ---------------------------------------------------------
$imageExtensions = @(".jpg", ".jpeg", ".png", ".heic", ".webp", ".tif", ".tiff")
$videoExtensions = @(".mp4", ".mov", ".avi", ".mkv", ".m4v", ".3gp")
$pdfExtensions   = @(".pdf")

try {
    $allFilePaths = [System.IO.Directory]::GetFiles($targetDir, "*.*", [System.IO.SearchOption]::TopDirectoryOnly)
    $allFiles = $allFilePaths | ForEach-Object { Get-Item -LiteralPath $_ }
} catch {
    Write-Log "ERROR" "SYSTEM" "Failed to retrieve files from target directory: $_"
    $allFiles = @()
}

$imageFiles = $allFiles | Where-Object { $_.PSIsContainer -eq $false -and ($imageExtensions -contains $_.Extension.ToLower()) }
$videoFiles = $allFiles | Where-Object { $_.PSIsContainer -eq $false -and ($videoExtensions -contains $_.Extension.ToLower()) }
$pdfFiles   = $allFiles | Where-Object { $_.PSIsContainer -eq $false -and ($pdfExtensions   -contains $_.Extension.ToLower()) }

$totalCount = $imageFiles.Count + $videoFiles.Count + $pdfFiles.Count
Write-Log "INFO" "SUMMARY" "Images: $($imageFiles.Count) | Videos: $($videoFiles.Count) | PDFs: $($pdfFiles.Count) | Total: $totalCount"

if ($totalCount -eq 0) {
    Write-Host "No target media files found." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

# ---------------------------------------------------------
# 2. HELPER FUNCTIONS & TIMEZONE LOGIC
# ---------------------------------------------------------
function Test-ValidDate {
    param([datetime]$date)
    $minDate = [datetime]"1970-01-01"
    $maxDate = [datetime]"2100-12-31"
    return ($date -ge $minDate -and $date -le $maxDate)
}

function Apply-TimeZoneAndOffset {
    param([datetime]$date, [string]$fileName)
    $adjustedDate = $date
    if ($ManualOffsetHours -ne 0) {
        $adjustedDate = $adjustedDate.AddHours($ManualOffsetHours)
    }
    return $adjustedDate
}

function Set-FileTime {
    param([string]$filePath, [datetime]$parsedDate)
    if (-not (Test-ValidDate -date $parsedDate)) {
        Write-Log "ERROR" (Split-Path $filePath -Leaf) "Skipped invalid date ($($parsedDate.ToString('yyyy-MM-dd HH:mm:ss')))"
        return $false
    }
    try {
        $item = Get-Item -LiteralPath $filePath
        $item.CreationTime   = $parsedDate
        $item.LastWriteTime  = $parsedDate
        $item.LastAccessTime = $parsedDate
        return $true
    } catch {
        Write-Log "ERROR" (Split-Path $filePath -Leaf) "Failed to set file time: $_"
        return $false
    }
}

# Integrated Filename Fallback Patterns
$filenamePatterns = @(
    @{ Name = "Custom Prefix YYYYMMDD-HHMMSS"; Pattern = "\d+[A-Z]+(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})"; CombineGroups = @(1, 2, 3, 4, 5, 6); Format = "yyyyMMddHHmmss" },
    @{ 
        Name = "US English Month Format"; 
        Pattern = "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[-_]?(\d{1,2})[-_]?(\d{4})[ _]?(\d{2})(\d{2})"; 
        IsCustom = $true;
        MonthMap = @{Jan="01"; Feb="02"; Mar="03"; Apr="04"; May="05"; Jun="06"; Jul="07"; Aug="08"; Sep="09"; Oct="10"; Nov="11"; Dec="12"}
    },
    @{ Name = "Windows Snipping Tool (YYYY-MM-DD HHMMSS)"; Pattern = "Screenshot[ _](\d{4})-(\d{2})-(\d{2})[ _](\d{2})(\d{2})(\d{2})"; CombineGroups = @(1, 2, 3, 4, 5, 6); Format = "yyyyMMddHHmmss" },
    @{ Name = "Android Screenshot (YYYY-MM-DD-HH-MM-SS)"; Pattern = "Screenshot[_-](\d{4})-(\d{2})-(\d{2})[_-](\d{2})-(\d{2})-(\d{2})"; CombineGroups = @(1, 2, 3, 4, 5, 6); Format = "yyyyMMddHHmmss" },
    @{ Name = "Standard YYYYMMDD_HHMMSS"; Pattern = "(\d{8})[T_]?(\d{6})"; CombineGroups = @(1, 2); Format = "yyyyMMddHHmmss" },
    @{ Name = "Motorola RAZR / DROID Era"; Pattern = "(?:IMG|VID) *(\d{8})* (\d{6})"; CombineGroups = @(1, 2); Format = "yyyyMMddHHmmss" },
    @{ Name = "Samsung Legacy Feature Phone"; Pattern = "(?:SGH|GT-)?[A-Za-z0-9]* *?(\d{8})* (\d{6})"; CombineGroups = @(1, 2); Format = "yyyyMMddHHmmss" },
    @{ Name = "Palm Pre / Centro / Treo"; Pattern = "(?:Photo|Snapshot|Palm)[- *]?(\d{4})-(\d{2})-(\d{2})"; CombineGroups = @(1, 2, 3); Format = "yyyy-MM-dd" },
    @{ Name = "Legacy Japanese Feature Phone"; Pattern = "(?:sh|p|so|n|ca|ku)? *?(\d{4})(\d{2})(\d{2}) *?(\d{2})(\d{2})"; CombineGroups = @(1, 2, 3, 4, 5); Format = "yyyyMMddHHmm" },
    @{ Name = "Standard 3gp / Mobile Video Era"; Pattern = "(?:MOV|VID|CLIP)[-* ]?(\d{8})[-_]?(\d{6})"; CombineGroups = @(1, 2); Format = "yyyyMMddHHmmss" }
)

function Try-ParseDateFromFilename {
    param([string]$fileName)
    foreach ($p in $filenamePatterns) {
        if ($fileName -match $p.Pattern) {
            try {
                if ($p.IsCustom) {
                    $mStr = $Matches[1].Substring(0,1).ToUpper() + $Matches[1].Substring(1,2).ToLower()
                    $monthNum = $p.MonthMap[$mStr]
                    $dayNum = $Matches[2].PadLeft(2, '0')
                    $yearNum = $Matches[3]
                    $hourNum = $Matches[4]
                    $minNum = $Matches[5]
                    $rawStr = "$yearNum$monthNum$dayNum$hourNum$minNum"
                    $parsed = [datetime]::ParseExact($rawStr, "yyyyMMddHHmm", $null)
                    if (Test-ValidDate -date $parsed) { return $parsed }
                } else {
                    $rawStr = ""
                    foreach ($g in $p.CombineGroups) {
                        $rawStr += $Matches[$g]
                    }
                    $parsed = [datetime]::ParseExact($rawStr, $p.Format, $null)
                    if (Test-ValidDate -date $parsed) {
                        return $parsed
                    }
                }
            } catch {}
        }
    }
    return $null
}

$processedCount = 0
$updatedCount = 0

# ---------------------------------------------------------
# 3. PROCESS IMAGES (Priority: Filename -> ExifTool via ShortPath)
# ---------------------------------------------------------
foreach ($file in $imageFiles) {
    $processedCount++
    $targetDate = $null

    $targetDate = Try-ParseDateFromFilename -fileName $file.Name
    if ($targetDate) {
        if (Set-FileTime -filePath $file.FullName -parsedDate $targetDate) {
            Write-Log "FILENAME" $file.Name "Success (From Filename): $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
            $updatedCount++
        }
        continue
    }

    $shortFilePath = Get-ShortPath $file.FullName
    $exifOut = & $exifToolCmd -DateTimeOriginal -CreateDate -d "%Y-%m-%d %H:%M:%S" $shortFilePath
    foreach ($line in $exifOut) {
        if ($line -match "(?:Date/Time Original|Create Date)\s*:\s*(.+)") {
            try {
                $parsed = [datetime]::ParseExact($Matches[1].Trim(), "yyyy-MM-dd HH:mm:ss", $null)
                if (Test-ValidDate -date $parsed) {
                    $targetDate = Apply-TimeZoneAndOffset -date $parsed -fileName $file.Name
                    break
                }
            } catch {}
        }
    }

    if ($targetDate) {
        if (Set-FileTime -filePath $file.FullName -parsedDate $targetDate) {
            Write-Log "EXIF" $file.Name "Success: $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
            $updatedCount++
        }
    } else {
        Write-Log "WARN" $file.Name "Could not determine date (Failed to detect timestamp)"
    }
}

# ---------------------------------------------------------
# 4. PROCESS VIDEOS (Priority: Filename -> XML Sidecar -> ExifTool via ShortPath)
# ---------------------------------------------------------
foreach ($file in $videoFiles) {
    $processedCount++
    $targetDate = $null
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.FullName)
    $dirName = $file.DirectoryName
    $xmlPath = Join-Path $dirName "$baseName.xml"

    $targetDate = Try-ParseDateFromFilename -fileName $file.Name
    if ($targetDate) {
        if (Set-FileTime -filePath $file.FullName -parsedDate $targetDate) {
            Write-Log "FILENAME" $file.Name "Success (From Filename): $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
            $updatedCount++
        }
        continue
    }

    if (-not $targetDate -and (Test-Path -LiteralPath $xmlPath)) {
        try {
            [xml]$xmlContent = Get-Content -LiteralPath $xmlPath -Encoding UTF8 -ErrorAction Stop
            $xmlDateNode = $xmlContent.SelectNodes("//CreationDate | //DateTime | //UpdateTime | //ClipCreationDate")
            foreach ($node in $xmlDateNode) {
                if ($node.InnerText -match '(\d{4})[-/]?(\d{2})[-/]?(\d{2})[ T_](\d{2}):?(\d{2}):?(\d{2})') {
                    $dateStr = "$($Matches[1])$($Matches[2])$($Matches[3])$($Matches[4])$($Matches[5])$($Matches[6])"
                    $parsed = [datetime]::ParseExact($dateStr, "yyyyMMddHHmmss", $null)
                    if (Test-ValidDate -date $parsed) {
                        $targetDate = Apply-TimeZoneAndOffset -date $parsed -fileName $file.Name
                        Write-Log "XML_SIDECAR" $file.Name "Success from XML: $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
                        break
                    }
                }
            }
        } catch {}
    }

    if (-not $targetDate) {
        $shortFilePath = Get-ShortPath $file.FullName
        $exifOut = & $exifToolCmd -CreateDate -MediaCreateDate -TrackCreateDate -d "%Y-%m-%d %H:%M:%S" $shortFilePath
        foreach ($line in $exifOut) {
            if ($line -match "(?:Create Date|Media Create Date|Track Create Date)\s*:\s*(.+)") {
                try {
                    $parsed = [datetime]::ParseExact($Matches[1].Trim(), "yyyy-MM-dd HH:mm:ss", $null)
                    if (Test-ValidDate -date $parsed) {
                        $targetDate = Apply-TimeZoneAndOffset -date $parsed -fileName $file.Name
                        break
                    }
                } catch {}
            }
        }
    }

    if ($targetDate) {
        if (Set-FileTime -filePath $file.FullName -parsedDate $targetDate) {
            Write-Log "METADATA" $file.Name "Success: $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
            $updatedCount++
        }
    } else {
        Write-Log "WARN" $file.Name "Could not determine date (Failed to detect timestamp)"
    }
}

# ---------------------------------------------------------
# 5. PROCESS PDF / DOCUMENTS (Priority: Filename / Date Pattern First for Path Safety)
# ---------------------------------------------------------
foreach ($file in $pdfFiles) {
    $processedCount++
    $targetDate = $null

    # [Strategy 1] Filename / Pattern matching (Completely safe from multibyte path/ExifTool errors)
    $parsed = Try-ParseDateFromFilename -fileName $file.Name
    if (-not $parsed) {
        if ($file.Name -match '(\d{4})[-/]?(\d{2})[-/]?(\d{2})') {
            try {
                $parsed = [datetime]::ParseExact("$($Matches[1])$($Matches[2])$($Matches[3])", "yyyyMMdd", $null)
            } catch {}
        }
    }

    if ($parsed -and (Test-ValidDate -date $parsed)) {
        $targetDate = Apply-TimeZoneAndOffset -date $parsed -fileName $file.Name
    }

    # [Strategy 2] Fallback to ExifTool via ShortPath only if filename has no date
    if (-not $targetDate) {
        $shortFilePath = Get-ShortPath $file.FullName
        $exifOut = & $exifToolCmd -CreateDate -ModifyDate -d "%Y-%m-%d %H:%M:%S" $shortFilePath
        foreach ($line in $exifOut) {
            if ($line -match "(?:Create Date|Modify Date)\s*:\s*(.+)") {
                try {
                    $p2 = [datetime]::ParseExact($Matches[1].Trim(), "yyyy-MM-dd HH:mm:ss", $null)
                    if (Test-ValidDate -date $p2) {
                        $targetDate = Apply-TimeZoneAndOffset -date $p2 -fileName $file.Name
                        break
                    }
                } catch {}
            }
        }
    }

    if ($targetDate) {
        if (Set-FileTime -filePath $file.FullName -parsedDate $targetDate) {
            Write-Log "PDF" $file.Name "Success: $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"
            $updatedCount++
        }
    } else {
        Write-Log "WARN" $file.Name "Could not determine date for PDF"
    }
}

# ---------------------------------------------------------
# 6. FINALIZE
# ---------------------------------------------------------
Write-Log "INFO" "SUMMARY" "END Processing. Processed: $totalCount / $totalCount | Updated: $updatedCount"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " FINISHED! ($updatedCount / $totalCount files updated) " -ForegroundColor Green
Write-Host " Check log file for details: $logPath              " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Read-Host "Press Enter to exit"