# 📘 TÀI LIỆU HƯỚNG DẪN CHI TIẾT: AUTO BACKUP SQL & ONEDRIVE CLEANUP

**Phiên bản:** 2.3.0
**Ngày cập nhật:** 11/01/2026
**Tác giả:** BFC DevOps Team

---

## 1. 🌟 Giới thiệu tổng quan

Công cụ **AutoBackupSQL-Cleanup** là giải pháp tự động hóa giúp quản lý vòng đời file backup của SQL Server, đảm bảo dung lượng lưu trữ luôn được tối ưu trên cả Local Server và OneDrive Cloud.

### Các tính năng chính:
*   **Dọn dẹp Local (Local Cleanup)**: Tự động xóa các file backup cũ trên ổ cứng server (mặc định > 5 giờ) để giải phóng không gian.
*   **Dọn dẹp Cloud (Cloud Cleanup)**: Sử dụng Microsoft Graph API để xóa vĩnh viễn các file trong thùng rác OneDrive (Second-Stage Recycle Bin) và các file cũ quá hạn (mặc định > 3 ngày).
*   **Giám sát dung lượng (Storage Monitor)**: Cảnh báo khi dung lượng OneDrive vượt ngưỡng cho phép (mặc định 70%).
*   **Thông báo thông minh (Telegram Alert)**: Gửi báo cáo chi tiết về tình trạng backup, danh sách file mới nhất và trạng thái dọn dẹp qua Telegram ngay sau khi chạy.
*   **Bảo mật nâng cao (Security)**: Hỗ trợ mã hóa thông tin nhạy cảm (Client Secret, Bot Token) theo chuẩn DPAPI, tránh lưu trữ dạng văn bản thuần.

---

## 2. 📋 Yêu cầu hệ thống

Trước khi cài đặt, hãy đảm bảo server đáp ứng các yêu cầu sau:

| Thành phần | Yêu cầu |
|------------|---------|
| **Hệ điều hành** | Windows Server 2016/2019/2022 hoặc Windows 10/11 |
| **PowerShell** | Phiên bản **7.0 trở lên** (PowerShell Core) |
| **Kết nối mạng** | Cần Internet để truy cập Microsoft Graph API và Telegram API |
| **Tài khoản Azure** | Cần quyền tạo **App Registration** trên Azure AD (Entra ID) |

---

## 3. 🚀 Hướng dẫn cài đặt

### Bước 1: Chuẩn bị mã nguồn
Clone repository về thư mục trên server (ví dụ: `D:\Scripts\AutoBackup`):
```powershell
git clone https://github.com/iatoi/auto-backup-sql-cleanup.git .
```

### Bước 2: Chuẩn bị file cấu hình
Copy file mẫu để tạo file cấu hình chính thức:
```powershell
Copy-Item "config\config.template.json" "config\config.json"
```

### Bước 3: Cấu hình Azure AD App
1.  Truy cập **Azure Portal** > **App registrations**.
2.  Tạo App mới (New registration).
3.  Vào **API Permissions** > **Add a permission** > **Microsoft Graph**.
4.  Chọn **Application permissions** (chạy ngầm không cần user login).
5.  Tìm và check quyền: `Sites.FullControl.All`.
6.  Bấm **Grant admin consent** để cấp quyền.
7.  Vào **Certificates & secrets** > Tạo **New client secret** > Copy giá trị `Value` (đây là Client Secret).
8.  Vào **Overview** > Copy `Application (client) ID` và `Directory (tenant) ID`.

---

## 4. ⚙️ Hướng dẫn Cấu hình (config.json)

Mở file `config\config.json` và điền các thông tin:

```json
{
    "AzureAD": {
        "TenantId": "điền-tenant-id-vào-đây",
        "ClientId": "điền-client-id-vào-đây",
        "ClientSecret": "" // ĐỂ TRỐNG nếu dùng chế độ bảo mật (xem mục 5)
    },
    "OneDrive": {
        "SiteUrl": "https://tenant-my.sharepoint.com/personal/user_domain",
        "BackupFolderPath": "Backup.SQL" // Thư mục chứa backup trên OneDrive
    },
    "LocalBackup": {
        "Path": "D:\\Backup\\SQL\\", // Thư mục backup trên server
        "RetentionMinutes": 300,      // Số phút giữ file (300 = 5 tiếng)
        "Extensions": [".bak", ".zip"]
    },
    "CloudRecycleBin": {
        "FirstStageRetentionDays": 3, // Giữ file trong thùng rác 3 ngày
        "RowLimit": 5000              // Số lượng item xử lý mỗi lần
    },
    "Telegram": {
        "BotToken": "", // ĐỂ TRỐNG nếu dùng chế độ bảo mật
        "ChatId": "-123456789" // Chat ID nhóm hoặc cá nhân nhận tin
    }
}
```

---

## 5. 🔒 Thiết lập Bảo mật (Quan trọng)

Để tránh lộ thông tin nhạy cảm trong file text, sử dụng chế độ **Setup Security** (chỉ cần làm 1 lần lúc cài đặt).

**Cách thực hiện:**
1.  Mở PowerShell (Run as Administrator).
2.  Chạy lệnh setup:
    ```powershell
    pwsh -ExecutionPolicy Bypass -File src\AutoClean_SQL.ps1 -SetupSecurity
    ```
3.  Khi được hỏi, nhập/paste **Client Secret** và nhấn Enter.
4.  Tiếp tục nhập/paste **Telegram Bot Token** và nhấn Enter.

Script sẽ tạo ra 2 file mã hóa `.encrypted` trong thư mục `config/`. Kể từ giờ, script sẽ tự động đọc mật khẩu từ các file này. Bạn có thể xóa `ClientSecret` và `BotToken` trong `config.json` để bảo mật tuyệt đối.

---

## 6. 📖 Hướng dẫn sử dụng & Vận hành

### Chạy thủ công (Manual Run)
Để kiểm tra script hoạt động:
```powershell
pwsh -ExecutionPolicy Bypass -File src\AutoClean_SQL.ps1
```

### Lên lịch chạy tự động (Task Scheduler)
Để script chạy định kỳ (ví dụ: mỗi 1 tiếng/lần):

1.  Mở **Task Scheduler**.
2.  Create Task > Tab **General**:
    *   Name: `BFC_AutoBackup_Cleanup`
    *   User account: Chọn user đã thực hiện bước Setup Bảo mật (bắt buộc do cơ chế DPAPI).
    *   Chọn "Run whether user is logged on or not" và "Run with highest privileges".
3.  Tab **Triggers**: New > Daily/Hourly theo nhu cầu.
4.  Tab **Actions**: New > Start a program:
    *   **Program/script**: `pwsh.exe`
    *   **Add arguments**: `-ExecutionPolicy Bypass -File "D:\Scripts\AutoBackup\src\AutoClean_SQL.ps1"`
    *   **Start in**: `D:\Scripts\AutoBackup\` (Rất quan trọng để script tìm thấy config).

---

## 7. 📱 Giải thích thông báo Telegram

Script sẽ gửi thông báo với 2 cấp độ cảnh báo:

### A. Trạng thái Bình thường (Normal)
Dung lượng sử dụng < 80%. Giao diện xanh/vàng thân thiện.

```text
✅ BFC SQL BACKUP
🟢 Used: 103.5GB / 1024GB (10%)
📂 ONEDRIVE (10 files):
  04/01 10:30 BFCHEM APP
  04/01 10:30 BFCHEM SYS
🗑️ RECYCLE: 134 items (3-day safe)
```

### B. Trạng thái Cảnh báo Nóng (Critical)
Dung lượng sử dụng ≥ 80%. Giao diện chuyển sang chế độ báo động (Fire/Siren).

```text
🚨 STORAGE CRITICAL - BFC BACKUP [CRITICAL]
🔥 FULL: 850GB/1024GB (83%)
⚠️ ACTION: SAP HET DUNG LUONG! CAN VAO XOA RECYCLE BIN THU CONG NGAY!
📂 ONEDRIVE (10 files):
  ...
🗑️ RECYCLE: 5000+ items
```

---

## 8. ❓ Xử lý sự cố thường gặp (Troubleshooting)

**Q: Script báo lỗi "401 Unauthorized" khi kết nối OneDrive?**
*   A: Kiểm tra lại `ClientId`, `TenantId` trong config.json. Nếu dùng bảo mật, hãy chạy lại lệnh `-SetupSecurity` để nhập lại Client Secret cho đúng. Đảm bảo App trên Azure đã được cấp quyền `Sites.FullControl.All` và đã nhấn "Grant admin consent".

**Q: Script báo lỗi "400 Bad Request" khi gửi Telegram?**
*   A: Kiểm tra `ChatId` có đúng không. Đảm bảo Bot đã được thêm vào nhóm chat.

**Q: Script không tìm thấy file config?**
*   A: Kiểm tra tham số "Start in" trong Task Scheduler đã trỏ đúng vào thư mục gốc của dự án chưa.

**Q: Lỗi "Secret decrypt failed" khi chạy bằng Task Scheduler?**
*   A: Task Scheduler PHẢI chạy dưới quyền Account cùng với Account bạn đã dùng để chạy lệnh `-SetupSecurity`. Cơ chế mã hóa DPAPI gắn liền với User Account của Windows.

---
**Hỗ trợ:** Liên hệ BFC IT Team nếu cần trợ giúp thêm.
