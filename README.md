# 🔄 Auto Backup SQL Cleanup - BFC System

> Tự động hóa vòng đời Backup SQL Server & Dọn dẹp OneDrive với thông báo Telegram

![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue?logo=powershell)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-API-green?logo=microsoft)
![Telegram](https://img.shields.io/badge/Telegram-Bot-blue?logo=telegram)
![Version](https://img.shields.io/badge/Version-2.1.0-orange)
![License](https://img.shields.io/badge/License-MIT-yellow)

## 📋 Mục lục

- [Giới thiệu](#-giới-thiệu)
- [Tính năng](#-tính-năng)
- [Yêu cầu hệ thống](#-yêu-cầu-hệ-thống)
- [Cài đặt](#-cài-đặt)
- [Cấu hình](#️-cấu-hình)
- [Sử dụng](#-sử-dụng)
- [Thiết lập Task Scheduler](#-thiết-lập-task-scheduler)
- [Cấu trúc thư mục](#-cấu-trúc-thư-mục)
- [Bảo mật](#-bảo-mật)

---

## 📖 Giới thiệu

Script PowerShell tự động hóa việc quản lý backup SQL Server và dọn dẹp OneDrive, giúp tiết kiệm dung lượng và thời gian quản trị.

| Nhiệm vụ | Mô tả |
|----------|-------|
| **A. Local Cleanup** | Xóa file backup (.bak, .zip, .7z) cũ hơn 5 tiếng để tiết kiệm ổ cứng |
| **B. Cloud Cleanup** | Dọn dẹp First-Stage Recycle Bin OneDrive qua Microsoft Graph API |
| **C. Storage Monitor** | Kiểm tra dung lượng OneDrive, cảnh báo khi > 70% |
| **D. Telegram Alert** | Gửi thông báo kết quả qua Telegram Bot |

---

## ✨ Tính năng

### 🗂️ Local Backup Cleanup
- Tự động xóa file backup cũ theo retention period
- Hỗ trợ nhiều loại file: `.bak`, `.zip`, `.7z`
- An toàn: Bỏ qua file đang bị lock

### ☁️ Cloud Recycle Bin Cleanup
- Sử dụng **Microsoft Graph API** (không cần PnP.PowerShell)
- **Batch delete** nhanh chóng (xóa hàng trăm items trong vài giây)
- Retention: Giữ lại items < 3 ngày để phòng khôi phục

### 📊 Storage Monitoring
- Kiểm tra dung lượng OneDrive qua API
- Hiển thị: Used / Total (%)
- Cảnh báo khi vượt ngưỡng (mặc định 70%)

### 📱 Telegram Notification
- Thông báo tự động sau mỗi lần chạy
- Hiển thị kết quả cleanup (local + cloud)
- Icon trạng thái: ✅ SUCCESS / ⚠️ WARNING / ❌ FAILED
- Cảnh báo dung lượng với icon 🟢/🔴

---

## 💻 Yêu cầu hệ thống

| Yêu cầu | Chi tiết |
|---------|----------|
| **PowerShell** | Core 7.0+ ([Download](https://github.com/PowerShell/PowerShell/releases)) |
| **Azure AD App** | Với quyền Microsoft Graph `Sites.FullControl.All` |
| **Telegram Bot** | Tạo qua @BotFather (tùy chọn) |

> ⚠️ **Lưu ý**: Script **KHÔNG** cần PnP.PowerShell module!

---

## 📦 Cài đặt

### 1. Clone repository

```bash
git clone https://github.com/iatoi/auto-backup-sql-cleanup.git
cd auto-backup-sql-cleanup
```

### 2. Tạo file cấu hình

```powershell
Copy-Item .\config\config.template.json .\config\config.json
```

### 3. Điền thông tin vào config.json

Xem phần [Cấu hình](#️-cấu-hình) bên dưới.

---

## ⚙️ Cấu hình

### Bước 1: Tạo Azure AD App Registration

1. Truy cập [Azure Portal](https://portal.azure.com)
2. Vào **Azure Active Directory** → **App registrations** → **New registration**
3. Đặt tên: `AutoClean SQL` (hoặc tên tùy ý)
4. Copy các giá trị:
   - **Application (client) ID** → `ClientId`
   - **Directory (tenant) ID** → `TenantId`
5. Vào **Certificates & secrets** → **New client secret** → Copy → `ClientSecret`

### Bước 2: Cấp quyền API

Vào **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**:

| Permission | Mô tả |
|------------|-------|
| `Sites.FullControl.All` | Truy cập toàn bộ SharePoint/OneDrive sites |

> ⚠️ **QUAN TRỌNG**: Nhấn **"Grant admin consent for [Tên Org]"** sau khi thêm quyền!

### Bước 3: Tạo Telegram Bot (Tùy chọn)

1. Mở Telegram, tìm **@BotFather**
2. Gửi `/newbot` và làm theo hướng dẫn
3. Copy **Bot Token**
4. Gửi tin nhắn cho bot của bạn
5. Truy cập: `https://api.telegram.org/bot<TOKEN>/getUpdates`
6. Tìm `"chat":{"id":XXXXXX}` → đó là **Chat ID**

### Bước 4: Cập nhật config.json

```json
{
    "AzureAD": {
        "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "ClientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "ClientSecret": "your-client-secret"
    },
    
    "OneDrive": {
        "SiteUrl": "https://yourtenant-my.sharepoint.com/personal/username_domain_com"
    },
    
    "LocalBackup": {
        "Path": "D:\\BFC\\BFC Information - Backup.SQL\\",
        "RetentionMinutes": 300,
        "Extensions": [".bak", ".zip", ".7z"]
    },
    
    "CloudRecycleBin": {
        "FirstStageRetentionDays": 3,
        "RowLimit": 5000
    },
    
    "Telegram": {
        "BotToken": "123456789:ABC-DEF...",
        "ChatId": "987654321"
    },
    
    "StorageAlert": {
        "WarningThresholdPercent": 70
    }
}
```

---

## 🚀 Sử dụng

### Chạy thủ công

```powershell
pwsh -ExecutionPolicy Bypass -File .\src\AutoClean_SQL.ps1
```

### Output mẫu

```
╔════════════════════════════════════════════════════════════╗
║   AUTO BACKUP SQL CLEANUP - BFC SYSTEM (GRAPH API)       ║
║   Phiên bản: 2.1.0 | Ngày: 2026-01-04 08:30:00           ║
╚════════════════════════════════════════════════════════════╝

Bước 1: Đọc cấu hình...
✓ Đã load cấu hình thành công

Bước 2: Thực hiện dọn dẹp Local...
✓ Đã xóa: 2 files

Bước 3: Thực hiện dọn dẹp Cloud (Microsoft Graph)...
✓ Đã xóa vĩnh viễn 226 items!

Bước 4: Kiểm tra dung lượng OneDrive...
Dung lượng: 450 GB / 1024 GB (44%)

╔════════════════════════════════════════════════════════════╗
║ LOCAL CLEANUP:  Xóa: 2 | Giữ: 10 | Lỗi: 0                ║
║ CLOUD CLEANUP:  Xóa: 226 | Giữ: 132 | Lỗi: 0             ║
║ STORAGE: 450 GB / 1024 GB (44%)                          ║
╚════════════════════════════════════════════════════════════╝
```

### Telegram Notification mẫu

```
✅ AUTO BACKUP SQL CLEANUP
📅 2026-01-04 08:30:00

📁 LOCAL CLEANUP:
• Đã xóa: 2 files
• Giữ lại: 10 files
• Lỗi: 0 files

☁️ CLOUD CLEANUP:
• Đã xóa: 226 items
• Giữ lại: 132 items
• Lỗi: 0 items

💾 DUNG LƯỢNG ONEDRIVE:
🟢 450 GB / 1024 GB (44%)
Còn trống: 574 GB
```

---

## ⏰ Thiết lập Task Scheduler

### 1. Mở Task Scheduler

```cmd
taskschd.msc
```

### 2. Tạo Task mới

| Field | Value |
|-------|-------|
| **Name** | `Auto Backup SQL Cleanup` |
| **Trigger** | Daily hoặc mỗi 6 tiếng |
| **Program/script** | `pwsh.exe` |
| **Arguments** | `-ExecutionPolicy Bypass -File "D:\Scripts\AutoClean_SQL\src\AutoClean_SQL.ps1"` |
| **Start in** | `D:\Scripts\AutoClean_SQL\` |

### 3. Cấu hình bổ sung

- ☑️ Run whether user is logged on or not
- ☑️ Run with highest privileges

---

## 📁 Cấu trúc thư mục

```
📁 auto-backup-sql-cleanup/
├── 📁 src/
│   └── AutoClean_SQL.ps1       # Script chính (v2.1.0)
├── 📁 config/
│   ├── config.template.json    # Template (commit lên Git)
│   └── config.json             # Credentials thực (KHÔNG commit!)
├── 📁 logs/
│   └── cleanup_YYYYMMDD.log    # Log files hàng ngày
├── .gitignore                  # Bảo vệ config.json
└── README.md                   # File này
```

---

## 🔒 Bảo mật

> ⚠️ **CẢNH BÁO**: KHÔNG BAO GIỜ commit file `config.json` lên Git!

### Files được bảo vệ bởi .gitignore:
- `config/config.json` - Chứa Azure AD secrets
- `logs/` - Thư mục log

### Nếu vô tình commit config.json:

```bash
git rm --cached config/config.json
git commit -m "Remove sensitive config from tracking"
```

### Bảo mật Telegram Bot Token:
- Nếu token bị lộ, vào @BotFather và gửi `/revoke` để tạo token mới

---

## 📝 Changelog

### v2.1.0 (2026-01-04)
- ✨ Thêm thông báo Telegram
- ✨ Thêm kiểm tra dung lượng OneDrive
- ✨ Cảnh báo khi dung lượng > 70%

### v2.0.0 (2026-01-04)
- 🔄 Chuyển từ PnP.PowerShell sang Microsoft Graph API
- ⚡ Batch delete thay vì xóa từng item
- 📝 Thêm logging ra file

### v1.0.0 (2026-01-03)
- 🎉 Initial release với PnP.PowerShell

---

## 📄 License

MIT License - Xem file [LICENSE](LICENSE) để biết thêm chi tiết.

---

**Developed by BFC DevOps Team** | 2026
