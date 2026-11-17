# 📸 Media Timestamp & Metadata Fixer

> A portable, dependency-free PowerShell tool to rescue and align legacy digital archives (2005–present) into pristine chronological order. 
> Built by **MidnightTabby** in the dead of night, powered by pure PowerShell, ExifTool, and a borderline-obsessive amount of regex rules.

## 🔒 Zero-Byte Modification Guarantee
This tool only adjusts the file system timestamps (NTFS Creation & Modification times) to restore chronological order. Your original file binaries remain 100% untouched—exact hashes and internal metadata are completely preserved.

<img src="images/z_gen_manga.jpg" alt="Z-Gen Student Chaos" width="100%">

## 🚀 Why this exists (For Gen-Z, students, & digital packrats)
If you've ever moved files across multiple phones, cloud syncs, and old hard drives, you know the pain: your precious memories (including those "historical archives" from middle school) are scattered in a chaotic timewarp. 

This tool brings **order and Aesthetic peacekeeping** back to your camera rolls, dashcam footage, security cams, and random PDFs without requiring heavy runtimes or Python environments.

<img src="images/pdf_manga.jpg" alt="PDF Chaos" width="100%">

## 🛠️ Supported Naming Schemas (The Global Regex Vault)
MidnightTabby didn't sleep so your files could stay messy. We support:
- **Windows & Android Screenshots** (Snipping Tool & mobile variants)
- **Dashcams & Security Cameras** (BlackVue, Thinkware, Viofo, 70mai, Reolink)
- **Legacy Feature Phones** (SHARP, Panasonic, Nokia, Motorola, Samsung from the mid-2000s)
- **US English Month & Numeric Formats** (`NOV15-2027...`, `MM-DD-YYYY`)
- **Standard EXIF & QuickTime Metadata / PDFs (iTextSharp)**

<p align="center">
  <img src="./images/imagesDemo.gif" alt="ChronoShift Actual Behaviour" width="100%">
</p>

## ☕ Credits & Acknowledgments
- **Phil Harvey**: Legend who created ExifTool. Without him, we'd be guessing dates like it's 1999.
- **iText Group & Community**: Creators of iTextSharp, making robust PDF metadata and structure manipulation possible in a lightweight environment.
- **AI Collaborator (Gemini)**: Who drank way too much iced coffee to translate a Japanese developer's hyper-fixation on 20-year-old mobile regexes into clean PowerShell, proving that AI and human stubbornness are a **match made in heaven**.

---

## ⚡ Quick Start & Usage (How to Restore Order)

No complex installation or Python environments required. Just drop and run.

### 1. Prerequisites
- **Windows 10 / 11** (PowerShell 5.1 or later)
- **`exiftool.exe`**: Download the Windows Executable from [Phil Harvey's official site](https://exiftool.org/), rename `exiftool(-k).exe` to `exiftool.exe`, and place it in the **same folder** as this script (or add it to your System PATH).
- **`itextsharp.dll`**: Placed alongside the script for handling PDF metadata extraction.

### 2. Folder Structure
Keep it portable—put everything in one folder:
```text
📁 Chaos_Archive/
 ├── 📜 MediaTimestampFixer_v0.80.ps1
 ├── ⚙️ itextsharp.dll
 ├── ⚙️ exiftool.exe
 └── 📁 exiftool_files
 ```
### 3. Run the Script
1. Right-click `MediaTimestampFixer_v0.80.ps1` and select **"Run with PowerShell"** (or open PowerShell in the folder and run `.\MediaTimestampFixer_v0.80.ps1`).
2. If prompted about Execution Policy, run the following command in PowerShell first:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
3. Follow the on-screen prompt to specify your target folder (e.g., `D:\Photos\Chaos_Archive`) and let the hybrid engine align your timestamps.
4. Clean up the portable files/folders once the operation is complete.

### 💡Pro Tip (Safety First)
**Always test on a small backup folder first before unleashing it on your entire 10-year camera roll!**
