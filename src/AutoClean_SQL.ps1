<#
.SYNOPSIS
    AutoClean_SQL.ps1 - Tự động hóa Vòng đời Backup SQL & Dọn dẹp OneDrive
    
.DESCRIPTION
    Script PowerShell Core (v7+) để quản lý backup SQL Server:
    - Nhiệm vụ A: Dọn dẹp file backup local cũ hơn 5 tiếng (300 phút)
    - Nhiệm vụ B: Quản lý thùng rác OneDrive qua PnP.PowerShell API
        + Purge Second-Stage Recycle Bin (xóa sạch ngay lập tức)
        + Dọn dẹp First-Stage items > 3 ngày
    
.NOTES
    Tác giả: BFC DevOps Team
    Phiên bản: 1.0.0
    Ngày tạo: 2026-01-04
    Yêu cầu: PowerShell 7+, Module PnP.PowerShell
    
.EXAMPLE
    pwsh -File .\AutoClean_SQL.ps1
    
    Chạy script với cấu hình mặc định từ config/config.json
#>

#Requires -Version 7.0

# ============================================================
# PHẦN 1: KHỞI TẠO VÀ CẤU HÌNH
# ============================================================

# Lấy đường dẫn thư mục chứa script để xác định vị trí config
# Sử dụng $PSScriptRoot để đảm bảo hoạt động đúng khi chạy từ Task Scheduler
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) {
    # Fallback nếu chạy từ interactive console
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Đường dẫn tuyệt đối đến file config.json
# File này PHẢI được tạo từ config.template.json và KHÔNG được commit lên Git
$ConfigPath = Join-Path (Split-Path $ScriptRoot -Parent) "config\config.json"

# ============================================================
# PHẦN 2: HÀM TIỆN ÍCH - LOGGING
# ============================================================

<#
.SYNOPSIS
    Ghi log với màu sắc và timestamp
    
.DESCRIPTION
    Hàm này in thông báo ra console với màu sắc phân biệt:
    - Success (Xanh lá): Thành công
    - Error (Đỏ): Lỗi
    - Warning (Vàng): Cảnh báo  
    - Info (Cyan): Thông tin
    
.PARAMETER Message
    Nội dung thông báo cần ghi

.PARAMETER Level
    Mức độ log: Success, Error, Warning, Info
#>
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Success", "Error", "Warning", "Info")]
        [string]$Level = "Info"
    )
    
    # Tạo timestamp theo định dạng Việt Nam
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Xác định màu sắc và prefix dựa trên mức độ log
    switch ($Level) {
        "Success" { 
            $Color = "Green"
            $Prefix = "[✓ OK]"
        }
        "Error" { 
            $Color = "Red"
            $Prefix = "[✗ LỖI]"
        }
        "Warning" { 
            $Color = "Yellow"
            $Prefix = "[⚠ CẢNH BÁO]"
        }
        "Info" { 
            $Color = "Cyan"
            $Prefix = "[ℹ INFO]"
        }
    }
    
    # In ra console với màu sắc
    Write-Host "[$Timestamp] $Prefix $Message" -ForegroundColor $Color
}

# ============================================================
# PHẦN 3: HÀM ĐỌC CẤU HÌNH
# ============================================================

<#
.SYNOPSIS
    Đọc và parse file cấu hình JSON
    
.DESCRIPTION
    Hàm này thực hiện:
    1. Kiểm tra file config.json tồn tại
    2. Parse nội dung JSON thành object PowerShell
    3. Validate các trường bắt buộc
    4. Trả về object cấu hình hoặc $null nếu lỗi
    
.PARAMETER ConfigFilePath
    Đường dẫn tuyệt đối đến file config.json
#>
function Read-Configuration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigFilePath
    )
    
    # Kiểm tra file cấu hình tồn tại
    if (-not (Test-Path $ConfigFilePath)) {
        Write-Log -Message "Không tìm thấy file cấu hình: $ConfigFilePath" -Level Error
        Write-Log -Message "Vui lòng copy file 'config.template.json' thành 'config.json' và điền thông tin" -Level Warning
        return $null
    }
    
    try {
        # Đọc và parse JSON
        # Sử dụng -Raw để đọc toàn bộ file thành một string
        $ConfigContent = Get-Content -Path $ConfigFilePath -Raw -Encoding UTF8
        $Config = $ConfigContent | ConvertFrom-Json
        
        # Validate các trường bắt buộc
        $RequiredFields = @(
            @{ Path = "AzureAD.TenantId"; Value = $Config.AzureAD.TenantId },
            @{ Path = "AzureAD.ClientId"; Value = $Config.AzureAD.ClientId },
            @{ Path = "AzureAD.ClientSecret"; Value = $Config.AzureAD.ClientSecret },
            @{ Path = "OneDrive.SiteUrl"; Value = $Config.OneDrive.SiteUrl },
            @{ Path = "LocalBackup.Path"; Value = $Config.LocalBackup.Path }
        )
        
        foreach ($Field in $RequiredFields) {
            if ([string]::IsNullOrWhiteSpace($Field.Value) -or $Field.Value -like "*xxxx*" -or $Field.Value -like "*your-*") {
                Write-Log -Message "Trường '$($Field.Path)' chưa được cấu hình trong config.json" -Level Error
                return $null
            }
        }
        
        Write-Log -Message "Đã load cấu hình thành công từ: $ConfigFilePath" -Level Success
        return $Config
        
    }
    catch {
        Write-Log -Message "Lỗi parse file JSON: $($_.Exception.Message)" -Level Error
        return $null
    }
}

# ============================================================
# PHẦN 4: NHIỆM VỤ A - DỌN DẸP LOCAL BACKUP
# ============================================================

<#
.SYNOPSIS
    Xóa các file backup cũ trên ổ đĩa local
    
.DESCRIPTION
    Hàm này thực hiện:
    1. Quét thư mục backup theo các extension được cấu hình (.bak, .zip, .7z)
    2. So sánh LastWriteTime với thời điểm hiện tại
    3. Xóa các file cũ hơn ngưỡng retention (mặc định 300 phút = 5 tiếng)
    4. Sử dụng SilentlyContinue để bỏ qua file đang bị SQL Server khóa
    
.PARAMETER BackupPath
    Đường dẫn thư mục chứa file backup

.PARAMETER RetentionMinutes  
    Số phút giữ lại file (mặc định 300 = 5 tiếng)

.PARAMETER Extensions
    Mảng các extension cần xử lý (mặc định: .bak, .zip, .7z)
#>
function Invoke-LocalBackupCleanup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        
        [Parameter(Mandatory = $false)]
        [int]$RetentionMinutes = 300,
        
        [Parameter(Mandatory = $false)]
        [string[]]$Extensions = @(".bak", ".zip", ".7z")
    )
    
    Write-Log -Message "========== BẮT ĐẦU NHIỆM VỤ A: DỌN DẸP LOCAL ==========" -Level Info
    Write-Log -Message "Thư mục mục tiêu: $BackupPath" -Level Info
    Write-Log -Message "Ngưỡng retention: $RetentionMinutes phút (~$([math]::Round($RetentionMinutes/60, 1)) tiếng)" -Level Info
    
    # Kiểm tra thư mục tồn tại
    if (-not (Test-Path $BackupPath)) {
        Write-Log -Message "Thư mục backup không tồn tại: $BackupPath" -Level Warning
        return @{ Deleted = 0; Failed = 0; Skipped = 0 }
    }
    
    # Tính toán thời điểm ngưỡng (cutoff time)
    # Các file có LastWriteTime trước thời điểm này sẽ bị xóa
    $CutoffTime = (Get-Date).AddMinutes(-$RetentionMinutes)
    Write-Log -Message "Xóa các file cũ hơn: $($CutoffTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Level Info
    
    # Thống kê kết quả
    $Stats = @{ Deleted = 0; Failed = 0; Skipped = 0 }
    
    # Tạo filter pattern từ danh sách extension
    # Ví dụ: *.bak, *.zip, *.7z
    $FilePatterns = $Extensions | ForEach-Object { "*$_" }
    
    # Quét và xử lý từng file
    foreach ($Pattern in $FilePatterns) {
        $Files = Get-ChildItem -Path $BackupPath -Filter $Pattern -File -ErrorAction SilentlyContinue
        
        foreach ($File in $Files) {
            # Kiểm tra tuổi file
            if ($File.LastWriteTime -lt $CutoffTime) {
                try {
                    # Xóa file với SilentlyContinue để bỏ qua nếu file đang bị khóa
                    # Điều này xảy ra khi SQL Server đang ghi vào file backup
                    Remove-Item -Path $File.FullName -Force -ErrorAction Stop
                    Write-Log -Message "Đã xóa: $($File.Name) (Tuổi: $([math]::Round(((Get-Date) - $File.LastWriteTime).TotalMinutes)) phút)" -Level Success
                    $Stats.Deleted++
                    
                }
                catch {
                    # File có thể đang bị khóa bởi SQL Server hoặc process khác
                    Write-Log -Message "Không thể xóa (có thể đang bị khóa): $($File.Name)" -Level Warning
                    $Stats.Failed++
                }
            }
            else {
                # File còn mới, giữ lại
                $Stats.Skipped++
            }
        }
    }
    
    # Tổng kết
    Write-Log -Message "Kết quả Local Cleanup: Xóa=$($Stats.Deleted), Lỗi=$($Stats.Failed), Giữ lại=$($Stats.Skipped)" -Level Info
    Write-Log -Message "========== KẾT THÚC NHIỆM VỤ A ==========" -Level Info
    
    return $Stats
}

# ============================================================
# PHẦN 5: NHIỆM VỤ B - DỌN DẸP CLOUD (ONEDRIVE API)
# ============================================================

<#
.SYNOPSIS
    Kết nối đến OneDrive sử dụng Azure AD App Registration
    
.DESCRIPTION
    Sử dụng PnP.PowerShell module để kết nối đến SharePoint/OneDrive
    với xác thực Client Credentials (không cần interactive login)
    Phù hợp để chạy trên Task Scheduler
    
.PARAMETER TenantId
    Azure AD Tenant ID (GUID hoặc domain)

.PARAMETER ClientId
    Client ID của Azure AD App Registration

.PARAMETER ClientSecret
    Client Secret của Azure AD App Registration

.PARAMETER SiteUrl
    URL của OneDrive site (personal site)
#>
function Connect-OneDriveService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        
        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,
        
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )
    
    Write-Log -Message "Đang kết nối đến OneDrive..." -Level Info
    Write-Log -Message "Site URL: $SiteUrl" -Level Info
    # KHÔNG log ClientSecret vì lý do bảo mật!
    
    try {
        # Kiểm tra module PnP.PowerShell đã được cài đặt chưa
        if (-not (Get-Module -ListAvailable -Name "PnP.PowerShell")) {
            Write-Log -Message "Module PnP.PowerShell chưa được cài đặt" -Level Error
            Write-Log -Message "Chạy lệnh: Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force" -Level Warning
            return $false
        }
        
        # Import module
        Import-Module PnP.PowerShell -ErrorAction Stop
        
        # Kết nối sử dụng Client Credentials flow (ACS Authentication)
        # LƯU Ý: Đây là legacy ACS authentication, chỉ hoạt động với SharePoint API
        # Không cần interactive login - phù hợp cho Task Scheduler
        # ClientSecret được truyền trực tiếp dạng plain string
        Connect-PnPOnline -Url $SiteUrl `
            -ClientId $ClientId `
            -ClientSecret $ClientSecret `
            -ErrorAction Stop
        
        Write-Log -Message "Kết nối OneDrive thành công!" -Level Success
        return $true
        
    }
    catch {
        Write-Log -Message "Lỗi kết nối OneDrive: $($_.Exception.Message)" -Level Error
        return $false
    }
}

<#
.SYNOPSIS
    Dọn dẹp thùng rác OneDrive (Second-Stage và First-Stage)
    
.DESCRIPTION
    Thực hiện 2 nhiệm vụ:
    1. Purge Second-Stage Recycle Bin: Xóa sạch ngay lập tức để giải phóng dung lượng
    2. Dọn dẹp First-Stage: Chỉ xóa các items đã nằm trong thùng rác > 3 ngày
    
.PARAMETER FirstStageRetentionDays
    Số ngày giữ lại items trong First-Stage (mặc định 3)

.PARAMETER RowLimit
    Số lượng items tối đa xử lý mỗi lần (mặc định 5000)
#>
function Invoke-CloudRecycleBinCleanup {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [int]$FirstStageRetentionDays = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$RowLimit = 5000
    )
    
    Write-Log -Message "========== BẮT ĐẦU NHIỆM VỤ B: DỌN DẸP CLOUD ==========" -Level Info
    
    $Stats = @{
        SecondStagePurged = $false
        FirstStageDeleted = 0
        FirstStageSkipped = 0
        Errors            = 0
    }
    
    # ---------------------------------------------------------
    # LOGIC 1: PURGE SECOND-STAGE RECYCLE BIN
    # Second-Stage là thùng rác cấp 2 (Site Collection Recycle Bin)
    # Xóa sạch để giải phóng dung lượng 1TB
    # ---------------------------------------------------------
    
    Write-Log -Message "--- Logic 1: Purge Second-Stage Recycle Bin ---" -Level Info
    
    try {
        # Lấy danh sách items trong Second-Stage (thùng rác cấp 2)
        # Second-Stage items có ItemState = 'SecondStageRecycleBin'
        $SecondStageItems = Get-PnPRecycleBinItem -RowLimit $RowLimit -ErrorAction Stop | 
        Where-Object { $_.ItemState -eq 'SecondStageRecycleBin' }
        $SecondStageCount = ($SecondStageItems | Measure-Object).Count
        
        if ($SecondStageCount -gt 0) {
            Write-Log -Message "Tìm thấy $SecondStageCount items trong Second-Stage Recycle Bin" -Level Info
            
            # Xóa từng item trong Second-Stage
            foreach ($Item in $SecondStageItems) {
                try {
                    Clear-PnPRecycleBinItem -Identity $Item.Id -Force -ErrorAction Stop
                }
                catch {
                    # Ignore individual item errors, count at the end
                }
            }
            
            Write-Log -Message "Đã purge $SecondStageCount items từ Second-Stage" -Level Success
            $Stats.SecondStagePurged = $true
        }
        else {
            Write-Log -Message "Second-Stage Recycle Bin đã trống" -Level Info
        }
        
    }
    catch {
        Write-Log -Message "Lỗi xử lý Second-Stage: $($_.Exception.Message)" -Level Error
        $Stats.Errors++
    }
    
    # ---------------------------------------------------------
    # LOGIC 2: DỌN DẸP FIRST-STAGE RECYCLE BIN
    # Chỉ xóa các items đã nằm trong thùng rác > 3 ngày
    # Giữ lại items mới xóa (< 3 ngày) để an toàn
    # ---------------------------------------------------------
    
    Write-Log -Message "--- Logic 2: Dọn dẹp First-Stage (items > $FirstStageRetentionDays ngày) ---" -Level Info
    
    try {
        # Lấy danh sách items trong First-Stage (thùng rác thông thường)
        # First-Stage items có ItemState = 'FirstStageRecycleBin'
        $FirstStageItems = Get-PnPRecycleBinItem -RowLimit $RowLimit -ErrorAction Stop | 
        Where-Object { $_.ItemState -eq 'FirstStageRecycleBin' }
        $FirstStageCount = ($FirstStageItems | Measure-Object).Count
        
        if ($FirstStageCount -eq 0) {
            Write-Log -Message "First-Stage Recycle Bin đã trống" -Level Info
        }
        else {
            Write-Log -Message "Tìm thấy $FirstStageCount items trong First-Stage Recycle Bin" -Level Info
            
            # Tính thời điểm ngưỡng: items xóa trước thời điểm này sẽ bị purge
            $CutoffDate = (Get-Date).AddDays(-$FirstStageRetentionDays)
            Write-Log -Message "Xóa các items bị xóa trước: $($CutoffDate.ToString('yyyy-MM-dd HH:mm:ss'))" -Level Info
            
            # Xử lý từng item
            foreach ($Item in $FirstStageItems) {
                # DeletedDate là thời điểm item bị đưa vào thùng rác
                if ($Item.DeletedDate -lt $CutoffDate) {
                    try {
                        # Xóa vĩnh viễn item này
                        # Item sẽ không thể khôi phục sau bước này
                        Clear-PnPRecycleBinItem -Identity $Item.Id -Force -ErrorAction Stop
                        Write-Log -Message "Đã xóa: $($Item.Title) (Trong thùng rác: $([math]::Round(((Get-Date) - $Item.DeletedDate).TotalDays, 1)) ngày)" -Level Success
                        $Stats.FirstStageDeleted++
                        
                    }
                    catch {
                        Write-Log -Message "Không thể xóa: $($Item.Title) - $($_.Exception.Message)" -Level Warning
                        $Stats.Errors++
                    }
                }
                else {
                    # Item còn mới (< 3 ngày), giữ lại để an toàn
                    $Stats.FirstStageSkipped++
                }
            }
        }
        
    }
    catch {
        Write-Log -Message "Lỗi xử lý First-Stage: $($_.Exception.Message)" -Level Error
        $Stats.Errors++
    }
    
    # Tổng kết
    Write-Log -Message "Kết quả Cloud Cleanup:" -Level Info
    Write-Log -Message "  - Second-Stage: $(if($Stats.SecondStagePurged){'Đã purge'}else{'Không có thay đổi'})" -Level Info
    Write-Log -Message "  - First-Stage: Xóa=$($Stats.FirstStageDeleted), Giữ lại=$($Stats.FirstStageSkipped), Lỗi=$($Stats.Errors)" -Level Info
    Write-Log -Message "========== KẾT THÚC NHIỆM VỤ B ==========" -Level Info
    
    return $Stats
}

<#
.SYNOPSIS
    Ngắt kết nối OneDrive
    
.DESCRIPTION
    Đóng connection đến SharePoint/OneDrive
    Nên gọi sau khi hoàn thành công việc để giải phóng tài nguyên
#>
function Disconnect-OneDriveService {
    try {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
        Write-Log -Message "Đã ngắt kết nối OneDrive" -Level Info
    }
    catch {
        # Ignore errors khi disconnect
    }
}

# ============================================================
# PHẦN 6: MAIN - ĐIỂM KHỞI CHẠY CHÍNH
# ============================================================

<#
.SYNOPSIS
    Hàm chính điều phối toàn bộ workflow
    
.DESCRIPTION
    Thực hiện tuần tự:
    1. Đọc cấu hình từ config.json
    2. Chạy Nhiệm vụ A: Dọn dẹp Local Backup
    3. Chạy Nhiệm vụ B: Dọn dẹp Cloud Recycle Bin
    4. Tổng kết và cleanup
#>
function Invoke-AutoCleanup {
    Write-Log -Message "╔════════════════════════════════════════════════════════════╗" -Level Info
    Write-Log -Message "║   AUTO BACKUP SQL CLEANUP - BFC SYSTEM                    ║" -Level Info
    Write-Log -Message "║   Phiên bản: 1.0.0 | Ngày: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')    ║" -Level Info
    Write-Log -Message "╚════════════════════════════════════════════════════════════╝" -Level Info
    
    # Bước 1: Load cấu hình
    Write-Log -Message "Bước 1: Đọc cấu hình..." -Level Info
    $Config = Read-Configuration -ConfigFilePath $ConfigPath
    
    if ($null -eq $Config) {
        Write-Log -Message "Không thể tiếp tục do lỗi cấu hình. Dừng script." -Level Error
        exit 1
    }
    
    # Bước 2: Chạy Nhiệm vụ A - Dọn dẹp Local
    Write-Log -Message "`nBước 2: Thực hiện dọn dẹp Local..." -Level Info
    $LocalStats = Invoke-LocalBackupCleanup `
        -BackupPath $Config.LocalBackup.Path `
        -RetentionMinutes $Config.LocalBackup.RetentionMinutes `
        -Extensions $Config.LocalBackup.Extensions
    
    # Bước 3: Chạy Nhiệm vụ B - Dọn dẹp Cloud
    Write-Log -Message "`nBước 3: Thực hiện dọn dẹp Cloud..." -Level Info
    
    $Connected = Connect-OneDriveService `
        -ClientId $Config.AzureAD.ClientId `
        -ClientSecret $Config.AzureAD.ClientSecret `
        -SiteUrl $Config.OneDrive.SiteUrl
    
    if ($Connected) {
        $CloudStats = Invoke-CloudRecycleBinCleanup `
            -FirstStageRetentionDays $Config.CloudRecycleBin.FirstStageRetentionDays `
            -RowLimit $Config.CloudRecycleBin.RowLimit
        
        # Đóng kết nối
        Disconnect-OneDriveService
    }
    else {
        Write-Log -Message "Bỏ qua dọn dẹp Cloud do không thể kết nối" -Level Warning
        $CloudStats = @{ SecondStagePurged = $false; FirstStageDeleted = 0; FirstStageSkipped = 0; Errors = 1 }
    }
    
    # Bước 4: Tổng kết
    Write-Log -Message "`n╔════════════════════════════════════════════════════════════╗" -Level Info
    Write-Log -Message "║                    TỔNG KẾT KẾT QUẢ                        ║" -Level Info
    Write-Log -Message "╠════════════════════════════════════════════════════════════╣" -Level Info
    Write-Log -Message "║ LOCAL CLEANUP:                                             ║" -Level Info
    Write-Log -Message "║   - Đã xóa: $($LocalStats.Deleted) files                   ║" -Level Info
    Write-Log -Message "║   - Giữ lại: $($LocalStats.Skipped) files                  ║" -Level Info
    Write-Log -Message "║   - Lỗi: $($LocalStats.Failed) files                       ║" -Level Info
    Write-Log -Message "╠════════════════════════════════════════════════════════════╣" -Level Info
    Write-Log -Message "║ CLOUD CLEANUP:                                             ║" -Level Info
    Write-Log -Message "║   - Second-Stage: $(if($CloudStats.SecondStagePurged){'Đã purge'}else{'Không thay đổi'})                              ║" -Level Info
    Write-Log -Message "║   - First-Stage xóa: $($CloudStats.FirstStageDeleted) items║" -Level Info
    Write-Log -Message "║   - First-Stage giữ: $($CloudStats.FirstStageSkipped) items║" -Level Info
    Write-Log -Message "╚════════════════════════════════════════════════════════════╝" -Level Info
    
    Write-Log -Message "Script hoàn thành lúc $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Success
}

# ============================================================
# ĐIỂM KHỞI CHẠY
# ============================================================
# Chỉ chạy khi script được gọi trực tiếp (không phải import)
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AutoCleanup
}
