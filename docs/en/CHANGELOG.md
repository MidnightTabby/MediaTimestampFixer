# Changelog
> Portable PowerShell script to standardize media file timestamps from filenames,
> XML sidecars, or metadata—with video duration offset support.

## ✨ What's New in v0.87 - 2026-11-23 (Pre-release)
- **Simultaneous 3-Format Export:** Outputs `.tsv`, self-contained `.html` (inline CSS3), and `.json` side by side from a single run.
- **Preserves Zero-Byte File Integrity:** Updates filesystem `CreationTime` and `LastWriteTime` without altering media bytes.

#### ⚙️ Requirements
- Windows 10 / 11 (PowerShell 5.1+ / PowerShell 7)
- Optional: `exiftool.exe`, `itextsharp.dll`

*Built by MidnightTabby.*

---

## 🚀 MediaTimestampFixer v0.86 (Pre-release)

> **"Digital Archive Timestamp & Metadata Aligner"**  
> Zero-byte modification, immutable filenames/metadata, and crystal-clear audit logging to bring absolute chronological order to your digital archives and pro editing workflows.

---

## 📝 Release Summary
Welcome to **v0.86**! This pre-release introduces our robust, hybrid **Video Duration Offset** feature. For video files where filenames or XML sidecars only specify a start timestamp, the script now queries ExifTool for exact numeric duration and automatically calculates the true end timestamp (`LastWriteTime`). 

While we continue active real-world testing, this version brings enterprise-grade reliability, zero-clutter safety, and total transparency to your media pipelines.

---

## ✨ What's New & Key Features

* **3-Tier Hybrid Fallback Pipeline**
  1. **Priority 1 (Filename)**: High-precision regex rules extract start/end timestamps directly from file naming conventions.
  2. **Priority 2 (XML Sidecar)**: Automatically detects 1-to-1 matching `.xml` sidecar files (Sony XDCAM, GoPro, CCTV/dashcams) in the same directory to parse `CreationDate` or `StartTime`.
  3. **Priority 3 (Internal Metadata)**: Fallback parsing for media Exif/QuickTime tags via ExifTool and PDF metadata via iTextSharp.
* **🎥 Hybrid Video Duration Offset (`Filename/XML + Duration`)**
  * Automatically appends the exact video duration (queried via ExifTool `-n`) to the start time when only a single timestamp is found, setting an accurate end time (`LastWriteTime`).
* **📋 Transparent Audit Logging (TSV Format)**
  * Every action (Updated, Skipped, Error) is logged instantly to `MediaTimestampFixer.log` in a clean Tab-Separated Values (TSV) format, complete with exact source tracking (e.g., `Filename + Duration`, `XML Sidecar`).
* **🛡️ Win32 Range Guard**
  * Built-in safety boundaries prevent abnormal or out-of-range dates (like stray year tokens) from crashing the script, ensuring 100% batch completion.

---

## 📂 System Requirements
* **PowerShell 7** (Recommended) / Windows PowerShell 5.1+
* **ExifTool** (`exiftool.exe` placed in the script root directory)
* **iTextSharp** (`itextsharp.dll` for advanced PDF parsing / Optional)

---

## 📊 Verification Status
* **Status**: Pre-release / Continuous Real-World Testing
* **Supported Formats**: JPEG, PNG, HEIC, MP4, MOV, PDF, and 1-to-1 XML Sidecars.

---

## ☕ Credits & Behind the Scenes
* **Author**: **MidnightTabby** — Operating in the dead of night to bring aesthetic order ("治安維持") to chaotic camera rolls and legacy media archives.
* **AI Collaborator**: **Gemini** — Translating borderline-obsessive regex rules and edge-case media pipelines into clean PowerShell.

*Built by MidnightTabby in the dead of night.*
