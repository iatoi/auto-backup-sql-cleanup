# 🔄 Auto Backup SQL Cleanup - BFC System

> Tự động hóa vòng đời Backup SQL Server & Dọn dẹp OneDrive

![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue?logo=powershell)
![PnP.PowerShell](https://img.shields.io/badge/PnP.PowerShell-Required-green)
![License](https://img.shields.io/badge/License-MIT-yellow)

## 📋 Mục lục

- [Giới thiệu](#giới-thiệu)
- [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
- [Cài đặt](#cài-đặt)
- [Cấu hình](#cấu-hình)
- [Sử dụng](#sử-dụng)
- [Thiết lập Task Scheduler](#thiết-lập-task-scheduler)
- [Hướng dẫn Git](#hướng-dẫn-git)

---

## 📖 Giới thiệu

Script PowerShell giải quyết 2 bài toán chính:

| Nhiệm vụ | Mô tả |
|----------|-------|
| **A. Local Cleanup** | Xóa file backup (.bak, .zip, .7z) cũ hơn 5 tiếng để tiết kiệm ổ cứng |
| **B. Cloud Cleanup** | Dọn dẹp thùng rác OneDrive qua API để giải phóng dung lượng 1TB |

### Logic xử lý Cloud:

1. **Second-Stage Recycle Bin**: Xóa sạch ngay lập tức (Purge)
2. **First-Stage Recycle Bin**: Chỉ xóa items > 3 ngày, giữ lại items mới để an toàn

---

## 💻 Yêu cầu hệ thống

- **PowerShell Core 7.0+** - [Download](https://github.com/PowerShell/PowerShell/releases)
- **Module PnP.PowerShell** - Cài đặt bằng lệnh:
  ```powershell
  Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
  ```
- **Azure AD App Registration** - Xem hướng dẫn bên dưới

---

## 📦 Cài đặt

### 1. Clone repository

```bash
git clone https://github.com/YOUR_USERNAME/auto-backup-sql-cleanup.git
cd auto-backup-sql-cleanup
```

### 2. Tạo file cấu hình

```powershell
# Copy file template thành config.json
Copy-Item .\config\config.template.json .\config\config.json
```

### 3. Cài đặt PnP.PowerShell (nếu chưa có)

```powershell
Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
```

---

## ⚙️ Cấu hình

### Bước 1: Tạo Azure AD App Registration

1. Truy cập [Azure Portal](https://portal.azure.com)
2. Vào **Azure Active Directory** → **App registrations** → **New registration**
3. Đặt tên app, ví dụ: `OneDrive-Cleanup-App`
4. Sau khi tạo, copy:
   - **Application (client) ID** → `ClientId`
   - **Directory (tenant) ID** → `TenantId`
5. Vào **Certificates & secrets** → **New client secret** → Copy giá trị → `ClientSecret`

### Bước 2: Cấp quyền API

Vào **API permissions** → **Add a permission** → **SharePoint** → **Application permissions**:

| Permission | Mô tả |
|------------|-------|
| `Sites.FullControl.All` | Truy cập toàn bộ SharePoint/OneDrive |

> ⚠️ **Quan trọng**: Nhấn **Grant admin consent** sau khi thêm quyền!

### Bước 3: Cập nhật config.json

Mở file `config/config.json` và điền thông tin thực:

```json
{
    "AzureAD": {
        "TenantId": "12345678-1234-1234-1234-123456789abc",
        "ClientId": "87654321-4321-4321-4321-cba987654321",
        "ClientSecret": "your-actual-secret-here"
    },
    "OneDrive": {
        "SiteUrl": "https://bfc-my.sharepoint.com/personal/thang_bfc_com"
    },
    "LocalBackup": {
        "Path": "D:\\BFC\\BFC Information - Backup.SQL\\",
        "RetentionMinutes": 300,
        "Extensions": [".bak", ".zip", ".7z"]
    },
    "CloudRecycleBin": {
        "FirstStageRetentionDays": 3,
        "RowLimit": 5000
    }
}
```

---

## 🚀 Sử dụng

### Chạy thủ công

```powershell
pwsh -File .\src\AutoClean_SQL.ps1
```

### Kiểm tra cú pháp (không chạy)

```powershell
# Parse script để kiểm tra lỗi cú pháp
pwsh -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('.\src\AutoClean_SQL.ps1', [ref]$null, [ref]$null) }"
```

---

## ⏰ Thiết lập Task Scheduler

### 1. Mở Task Scheduler

```cmd
taskschd.msc
```

### 2. Tạo Basic Task

- **Name**: `Auto Backup SQL Cleanup`
- **Trigger**: Daily hoặc theo nhu cầu (ví dụ: mỗi 6 tiếng)
- **Action**: Start a program

### 3. Cấu hình Action

| Field | Value |
|-------|-------|
| Program/script | `pwsh.exe` |
| Add arguments | `-ExecutionPolicy Bypass -File "D:\path\to\src\AutoClean_SQL.ps1"` |
| Start in | `D:\path\to\01. AUTO CONTROL ONEDRIVE BACKUP SQL\` |

### 4. Cấu hình bổ sung

- ☑️ Run whether user is logged on or not
- ☑️ Run with highest privileges

---

## 📝 Hướng dẫn Git

### Khởi tạo repository mới

```bash
# Di chuyển vào thư mục dự án
cd "D:\OneDrive - BFC\Desktop\00.MeOnJobs\00. CODING\02. Auto\01. AUTO CONTROL ONEDRIVE BACKUP SQL"

# Khởi tạo Git repository
git init

# Thêm tất cả files (config.json sẽ bị ignore tự động)
git add .

# Kiểm tra status - ĐẢM BẢO config.json KHÔNG có trong danh sách
git status

# Commit lần đầu
git commit -m "Initial commit: Auto Backup SQL Cleanup script"

# Thêm remote repository
git remote add origin https://github.com/YOUR_USERNAME/auto-backup-sql-cleanup.git

# Push lên GitHub
git push -u origin main
```

### Kiểm tra bảo mật

```bash
# Đảm bảo config.json KHÔNG được track
git status --short
# Output mong đợi: config/config.json KHÔNG hiển thị (đã bị ignore)

# Xem danh sách files sẽ được commit
git ls-files
# Output mong đợi: KHÔNG có config/config.json
```

---

## 📁 Cấu trúc thư mục

```
📁 01. AUTO CONTROL ONEDRIVE BACKUP SQL/
├── 📁 src/
│   └── AutoClean_SQL.ps1      # Script logic chính
├── 📁 config/
│   ├── config.template.json   # Template (commit lên Git)
│   └── config.json            # Credentials thực (KHÔNG commit!)
├── .gitignore                  # Bảo vệ config.json
└── README.md                   # File này
```

---

## 🎨 Output Console

Script sử dụng màu sắc để dễ theo dõi:

| Màu | Ý nghĩa |
|-----|---------|
| 🟢 Xanh lá | Thành công |
| 🔴 Đỏ | Lỗi |
| 🟡 Vàng | Cảnh báo |
| 🔵 Cyan | Thông tin |

---

## 🔒 Bảo mật

> ⚠️ **CẢNH BÁO**: KHÔNG BAO GIỜ commit file `config.json` lên Git!

File `.gitignore` đã được cấu hình để bỏ qua file này. Nếu vô tình commit, hãy:

```bash
# Xóa file khỏi Git history (giữ lại file local)
git rm --cached config/config.json
git commit -m "Remove sensitive config from tracking"
```

---

## 📄 License

MIT License - Xem file [LICENSE](LICENSE) để biết thêm chi tiết.

---

**Developed by BFC DevOps Team** | 2026
