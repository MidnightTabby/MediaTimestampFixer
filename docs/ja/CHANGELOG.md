# 🚀 MediaTimestampFixer v0.86 (Pre-release)

> **"Digital Archive Timestamp & Metadata Aligner"**  
> 撮影日時とファイルシステムのタイムスタンプを非破壊（Zero-Byte Modification）で完全に一致させ、プロの編集環境や長期アーカイブに秩序をもたらすためのツールです。

---

## 📝 Release Summary
本リリース（v0.86）では、映像制作現場や監視カメラ・ドライブレコーダーなどで重要となる**「動画ファイルの終了時刻（LastWriteTime）の自動補正機能（Duration Offset）」**を正式に統合しました。
ファイル名やXMLサイドカーから開始時刻が特定できた動画ファイルに対し、内部メタデータから正確な再生時間（Duration）を算出して終了時刻に加算するハイブリッド処理を実現しています。

引き続き実機テストは継続・検証中となりますが、実用フェーズにおいて極めて高い堅牢性と透明性を備えたバージョンとなります。

---

## ✨ What's New & Key Features

* **3段階の多段フォールバック（Hybrid Pipeline）**
  1. **Priority 1 (Filename)**: 柔軟な正規表現ルールにより、ファイル名から開始・終了タイムスタンプを最優先で抽出。
  2. **Priority 2 (XML Sidecar)**: 同ディレクトリ内の同名 `.xml` ファイル（Sony XDCAM形式、GoPro、各種Vlog・防犯カメラ等）を1対1で自動検出し、`CreationDate` や `StartTime` をパース。
  3. **Priority 3 (Internal Metadata)**: メディアファイルのExif/QuickTimeメタデータ（ExifTool）およびPDF（iTextSharp）のメタデータをフォールバックとして解析。
* **🎥 ハイブリッド動画 Duration 補正 (`Filename/XML + Duration`)**
  * ファイル名やXMLから開始日時が特定された動画ファイルについて、開始・終了時刻が同値（単一の時刻のみ）である場合、ExifTool を用いて正確な数値 Duration（秒数）を自動取得し、終了時刻（`LastWriteTime`）へ正確に加算・反映。
* **📋 監査ログの透明性向上（TSV Format）**
  * すべての処理結果（更新・スキップ・エラー）を `MediaTimestampFixer.log` にタブ区切り（TSV）で自動記録。どのソース（例: `Filename + Duration` や `XML Sidecar`）から日時が確定したかを一目で追跡可能。
* **🛡️ 堅牢なWin32レンジガード**
  * 不正な年号やシステム範囲外の日付を検知した際は、安全にスキップ処理を行ってスクリプト全体のクラッシュを防止。

---

## 📂 System Requirements
* **PowerShell 7** (推奨) / Windows PowerShell 5.1以降
* **ExifTool** (`exiftool.exe` をスクリプトと同階層に配置)
* **iTextSharp** (PDFメタデータ解析用 `itextsharp.dll` / 任意)

---

## 📊 Verification Status
* **Test Status**: Pre-release / 実機テスト継続中
* **Target Formats**: JPEG, PNG, HEIC, MP4, MOV, PDF, XML Sidecars

---

## ☕ Credits & Behind the Scenes
* **Author**: **MidnightTabby**
* **AI Collaborator**: **Gemini**