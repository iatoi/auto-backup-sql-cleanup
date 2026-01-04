# 🔄 Auto Backup SQL Cleanup - BFC System

> Tự động dọn dẹp backup SQL Server local & OneDrive với thông báo Telegram

![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue?logo=powershell)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-API-green?logo=microsoft)
![Telegram](https://img.shields.io/badge/Telegram-Bot-blue?logo=telegram)
![Version](https://img.shields.io/badge/Version-2.2.0-orange)

---

## ✨ Tính năng

| Tính năng | Mô tả |
|-----------|-------|
| **Local Cleanup** | Xóa file backup cũ (>.5h) trên ổ cứng |
| **Cloud Cleanup** | Dọn Recycle Bin OneDrive qua Graph API |
| **Storage Monitor** | Kiểm tra dung lượng OneDrive |
| **Telegram Alert** | Gửi thông báo tóm tắt sau mỗi lần chạy |

---

## 📋 Yêu cầu

- **PowerShell 7.0+** - [Download](https://github.com/PowerShell/PowerShell/releases)
- **Azure AD App** với quyền `Sites.FullControl.All`
- **Telegram Bot** (tùy chọn)

---

## 🚀 Cài đặt nhanh

```bash
# 1. Clone repo
git clone https://github.com/iatoi/auto-backup-sql-cleanup.git
cd auto-backup-sql-cleanup

# 2. Tạo config
cp config/config.template.json config/config.json

# 3. Điền thông tin vào config.json

# 4. Chạy
pwsh -ExecutionPolicy Bypass -File src/AutoClean_SQL.ps1
```

---

## ⚙️ Cấu hình

### config.json

```json
{
    "AzureAD": {
        "TenantId": "xxx-xxx-xxx",
        "ClientId": "xxx-xxx-xxx",
        "ClientSecret": "your-secret"
    },
    "OneDrive": {
        "SiteUrl": "https://tenant-my.sharepoint.com/personal/user_domain",
        "BackupFolderPath": "Backup.SQL"
    },
    "LocalBackup": {
        "Path": "D:\\BFC\\Backup\\",
        "RetentionMinutes": 300,
        "Extensions": [".bak", ".zip", ".7z"]
    },
    "CloudRecycleBin": {
        "FirstStageRetentionDays": 3,
        "RowLimit": 5000
    },
    "Telegram": {
        "BotToken": "123456:ABC-xyz",
        "ChatId": "987654321"
    },
    "StorageAlert": {
        "WarningThresholdPercent": 70
    }
}
```

### Lấy Telegram Bot Token & Chat ID

1. Mở Telegram, tìm **@BotFather**
2. Gửi `/newbot` → nhận **Bot Token**
3. Gửi tin nhắn cho bot của bạn
4. Truy cập: `https://api.telegram.org/bot<TOKEN>/getUpdates`
5. Tìm `"chat":{"id":XXXXXX}` → đó là **Chat ID**

---

## 📱 Telegram Notification

Thông báo mẫu:

```
✅ BFC SQL BACKUP
🟢 1015.53GB con (0.8% used)
📂 10 files: 20260104, 20260103
🗑️ 134 items (3-day safe)
```

| Emoji | Ý nghĩa |
|-------|---------|
| ✅/⚠️/❌ | Trạng thái: OK/Warning/Failed |
| 🟢/🟡/🔴 | Dung lượng: <50%/<80%/>80% |
| 📂 | Số file backup trên OneDrive |
| 🗑️ | Số items trong Recycle Bin |

---

## ⏰ Task Scheduler

```powershell
# Program: pwsh.exe
# Arguments: -ExecutionPolicy Bypass -File "D:\Scripts\AutoClean_SQL\src\AutoClean_SQL.ps1"
# Start in: D:\Scripts\AutoClean_SQL\
```

- ☑️ Run whether user is logged on or not
- ☑️ Run with highest privileges

---

## 📁 Cấu trúc

```
auto-backup-sql-cleanup/
├── src/AutoClean_SQL.ps1      # Script chính
├── config/
│   ├── config.template.json   # Template (commit)
│   └── config.json            # Config thực (gitignore)
├── logs/                      # Log files
└── README.md
```

---

## 🔒 Bảo mật

> ⚠️ **KHÔNG commit config.json** - chứa thông tin nhạy cảm!

```bash
# Nếu lỡ commit
git rm --cached config/config.json
git commit -m "Remove config"
```

---

## 📝 Changelog

### v2.2.0 (2026-01-04)
- ✨ Format Telegram message đẹp hơn với emoji
- ✨ Hiển thị files backup trên OneDrive folder
- ✨ Cấu hình BackupFolderPath

### v2.1.0 (2026-01-04)
- ✨ Thêm Telegram notification
- ✨ Thêm storage monitoring

### v2.0.0 (2026-01-04)
- 🔄 Chuyển từ PnP.PowerShell sang Microsoft Graph API

---

**Developed by BFC DevOps Team** | 2026
