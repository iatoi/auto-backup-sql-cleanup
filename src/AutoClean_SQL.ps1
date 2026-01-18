<#
.SYNOPSIS
    AutoClean_SQL.ps1 - Tự động hóa Vòng đời Backup SQL & Dọn dẹp OneDrive
    
.DESCRIPTION
    Script PowerShell Core (v7+) để quản lý backup SQL Server:
    - Nhiệm vụ A: Dọn dẹp file backup local cũ hơn 5 tiếng (300 phút)
    - Nhiệm vụ B: Quản lý thùng rác OneDrive qua Microsoft Graph API
        + Purge Second-Stage Recycle Bin
        + Dọn dẹp First-Stage items > 3 ngày
    
.NOTES
    Tác giả: BFC DevOps Team
    Phiên bản: 2.0.0
    Ngày tạo: 2026-01-04
    Yêu cầu: PowerShell 7+
    
.EXAMPLE
    pwsh -File .\AutoClean_SQL.ps1
    
    Chạy script với cấu hình mặc định từ config/config.json
#>

#Requires -Version 7.0

param (
    [Parameter(Mandatory = $false)]
    [switch]$SetupSecurity
)

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

# Đường dẫn file config và encrypted secrets
$ConfigDir = Join-Path (Split-Path $ScriptRoot -Parent) "config"
$ConfigPath = Join-Path $ConfigDir "config.json"
$ClientSecretPath = Join-Path $ConfigDir "client_secret.encrypted"
$BotTokenPath = Join-Path $ConfigDir "bot_token.encrypted"


# Đường dẫn file log - ghi vào thư mục logs cùng cấp với src
# File log được đặt tên theo ngày để dễ quản lý
$LogDirectory = Join-Path (Split-Path $ScriptRoot -Parent) "logs"
if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$LogFilePath = Join-Path $LogDirectory "cleanup_$(Get-Date -Format 'yyyyMMdd').log"

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
    Đồng thời ghi log vào file để debug
    
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
            $Prefix = "[OK]"
        }
        "Error" { 
            $Color = "Red"
            $Prefix = "[ERROR]"
        }
        "Warning" { 
            $Color = "Yellow"
            $Prefix = "[WARNING]"
        }
        "Info" { 
            $Color = "Cyan"
            $Prefix = "[INFO]"
        }
    }
    
    # Tạo dòng log
    $LogLine = "[$Timestamp] $Prefix $Message"
    
    # In ra console với màu sắc
    Write-Host $LogLine -ForegroundColor $Color
    
    # Ghi ra file log (append mode)
    try {
        Add-Content -Path $LogFilePath -Value $LogLine -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Ignore errors khi ghi file log
    }
}

# ============================================================
# HÀM BẢO MẬT (DPAPI)
# ============================================================

function Save-EncryptedSecret {
    param (
        [string]$Path,
        [SecureString]$Secret
    )
    $Secret | ConvertFrom-SecureString | Set-Content -Path $Path
    Write-Log -Message "Da luu encrypted secret vao: $Path" -Level Success
}

function Read-EncryptedSecret {
    param (
        [string]$Path
    )
    if (Test-Path $Path) {
        try {
            $EncryptedString = (Get-Content -Path $Path -Raw).Trim()
            if (-not [string]::IsNullOrWhiteSpace($EncryptedString)) {
                return $EncryptedString | ConvertTo-SecureString | ConvertFrom-SecureString -AsPlainText
            }
        }
        catch {
            Write-Log -Message "Loi decrypt file $Path (co the sai user/may): $($_.Exception.Message)" -Level Error
            return $null
        }
    }
    return $null
}

# ============================================================
# LOGIC SETUP SECURITY
# ============================================================

if ($SetupSecurity) {
    Write-Log -Message "=== CHE DO CAI DAT BAO MAT (DPAPI) ===" -Level Info
    Write-Host "Luu y: Du lieu duoc ma hoa theo User va May tinh hien tai." -ForegroundColor Yellow
    
    # 1. Nhập Client Secret
    $ClientInput = Read-Host -Prompt "Nhap Azure AD Client Secret (de trong de bo qua)" -AsSecureString
    if ($ClientInput) {
        Save-EncryptedSecret -Path $ClientSecretPath -Secret $ClientInput
    }
    
    # 2. Nhập Bot Token
    $BotInput = Read-Host -Prompt "Nhap Telegram Bot Token (de trong de bo qua)" -AsSecureString
    if ($BotInput) {
        Save-EncryptedSecret -Path $BotTokenPath -Secret $BotInput
    }
    
    Write-Log -Message "Cai dat hoan tat. Vui long xoa secret trong config.json (neu co) va chay lai script chinh." -Level Success
    exit
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
        
        # Override secrets nếu tìm thấy file encrypted (DPAPI)
        # Sử dụng $script: scope để truy cập biến global
        $EncClientSecret = Read-EncryptedSecret -Path $script:ClientSecretPath
        if ($EncClientSecret) { 
            $Config.AzureAD.ClientSecret = $EncClientSecret 
            Write-Log -Message "Su dung ClientSecret tu file ma hoa (DPAPI)" -Level Success
        }
        
        $EncBotToken = Read-EncryptedSecret -Path $script:BotTokenPath
        if ($EncBotToken) { 
            $Config.Telegram.BotToken = $EncBotToken 
            Write-Log -Message "Su dung BotToken tu file ma hoa (DPAPI)" -Level Success
        }
        
        # Validate các trường bắt buộc
        # Kiểm tra TenantId - rất quan trọng cho Graph API
        $RequiredFields = @(
            @{ Path = "AzureAD.TenantId"; Value = $Config.AzureAD.TenantId },
            @{ Path = "AzureAD.ClientId"; Value = $Config.AzureAD.ClientId },
            @{ Path = "AzureAD.ClientSecret"; Value = $Config.AzureAD.ClientSecret },
            @{ Path = "OneDrive.SiteUrl"; Value = $Config.OneDrive.SiteUrl },
            @{ Path = "LocalBackup.Path"; Value = $Config.LocalBackup.Path }
        )
        
        foreach ($Field in $RequiredFields) {
            if ([string]::IsNullOrWhiteSpace($Field.Value) -or $Field.Value -like "*xxxx*" -or $Field.Value -like "*your-*") {
                Write-Log -Message "Trường '$($Field.Path)' chưa được cấu hình (hoặc vẫn là giá trị mẫu) trong config.json" -Level Error
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
    $FilePatterns = $Extensions | ForEach-Object { "*$_" }
    
    # Quét và xử lý từng file
    foreach ($Pattern in $FilePatterns) {
        $Files = Get-ChildItem -Path $BackupPath -Filter $Pattern -File -ErrorAction SilentlyContinue
        
        foreach ($File in $Files) {
            # Kiểm tra tuổi file
            if ($File.LastWriteTime -lt $CutoffTime) {
                try {
                    # Xóa file với SilentlyContinue để bỏ qua nếu file đang bị khóa
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
# PHẦN 5: NHIỆM VỤ B - DỌN DẸP CLOUD (MICROSOFT GRAPH API)
# ============================================================

<#
.SYNOPSIS
    Lấy Access Token từ Azure AD
#>
function Get-GraphAccessToken {
    param (
        $TenantId,
        $ClientId,
        $ClientSecret
    )
    
    $TokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $Body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }
    
    try {
        Write-Log -Message "Đang lấy Access Token từ Azure AD..." -Level Info
        $Response = Invoke-RestMethod -Method Post -Uri $TokenUrl -Body $Body -ErrorAction Stop
        return $Response.access_token
    }
    catch {
        Write-Log -Message "Lỗi lấy Token: $($_.Exception.Message)" -Level Error
        if ($_.Exception.Message -match "client_secret") {
            Write-Log -Message "GỢI Ý: Client Secret có thể bị sai." -Level Warning
        }
        if ($_.Exception.Message -match "client_id") {
            Write-Log -Message "GỢI Ý: Client ID có thể bị sai." -Level Warning
        }
        return $null
    }
}

<#
.SYNOPSIS
    Lấy Site ID từ URL thông qua Graph API
#>
function Get-GraphSiteId {
    param (
        $SiteUrl,
        $AccessToken
    )
    
    # Phân tích URL để lấy Hostname và SitePath
    # Ví dụ: https://bfchem-my.sharepoint.com/personal/user_domain_com
    # Hostname: bfchem-my.sharepoint.com
    # Path: /personal/user_domain_com
    
    try {
        $Uri = [System.Uri]$SiteUrl
        $Hostname = $Uri.Host
        $SitePath = $Uri.AbsolutePath.TrimEnd('/') # Bỏ dấu / ở cuối nếu có
        
        Write-Log -Message "Đang tìm Site ID cho: $Hostname$SitePath" -Level Info
        
        $GraphUrl = "https://graph.microsoft.com/v1.0/sites/$Hostname`:$SitePath"
        $Headers = @{ Authorization = "Bearer $AccessToken" }
        
        $Response = Invoke-RestMethod -Method Get -Uri $GraphUrl -Headers $Headers -ErrorAction Stop
        return $Response.id
    }
    catch {
        Write-Log -Message "Lỗi lấy Site ID: $($_.Exception.Message)" -Level Error
        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            Write-Log -Message "GỢI Ý: App chưa có quyền 'Sites.FullControl.All' hoặc chưa Grant Admin Consent." -Level Warning
        }
        if ($_.Exception.Response.StatusCode -eq "NotFound") {
            Write-Log -Message "GỢI Ý: Site URL không đúng hoặc không tồn tại." -Level Warning
        }
        return $null
    }
}

<#
.SYNOPSIS
    Dọn dẹp Cloud Recycle Bin dùng Graph API
#>
function Invoke-CloudRecycleBinCleanup {
    [CmdletBinding()]
    param (
        $TenantId,
        $ClientId,
        $ClientSecret,
        $SiteUrl,
        $FirstStageRetentionDays = 3,
        $RowLimit = 5000
    )

    $Stats = @{ FirstStageDeleted = 0; FirstStageKept = 0; Errors = 0 }

    # 1. Lấy Token
    $Token = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    if (-not $Token) { return $Stats }
    $Headers = @{ Authorization = "Bearer $Token" }
    
    # 2. Lấy Site ID
    $SiteId = Get-GraphSiteId -SiteUrl $SiteUrl -AccessToken $Token
    if (-not $SiteId) { return $Stats }
    $SiteId = "$SiteId".Trim() # Clean SiteID
    Write-Log -Message "Site ID: $SiteId" -Level Info

    Write-Log -Message "========== BẮT ĐẦU NHIỆM VỤ B: DỌN DẸP CLOUD (GRAPH API) ==========" -Level Info
    
    # API Endpoint cho Recycle Bin (BETA endpoint - theo docs Microsoft)
    # Lưu ý: lowercase 'recyclebin', không phải 'recycleBin'
    $RecycleBinUrl = "https://graph.microsoft.com/beta/sites/$SiteId/recyclebin/items"
    Write-Log -Message "Debug RecycleBinUrl: [$RecycleBinUrl]" -Level Info
    
    # Dọn dẹp First-Stage
    try {
        # Đơn giản hóa query để debug lỗi 400: Bỏ orderby
        $QueryUrl = "{0}?`$top={1}" -f $RecycleBinUrl, $RowLimit
        Write-Log -Message "Query URL: [$QueryUrl]" -Level Info
        
        $Response = Invoke-RestMethod -Method Get -Uri $QueryUrl -Headers $Headers -ErrorAction Stop
        $Items = $Response.value
        
        $CutoffDate = (Get-Date).AddDays(-$FirstStageRetentionDays)
        Write-Log -Message "Ngưỡng xóa: Items xóa trước $CutoffDate" -Level Info
        
        if ($Items.Count -eq 0) {
            Write-Log -Message "Thùng rác trống." -Level Info
        }
        else {
            Write-Log -Message "Tìm thấy $($Items.Count) items trong thùng rác..." -Level Info
            
            # Thu thập IDs của items cần xóa (đã quá hạn retention)
            $IdsToDelete = @()
            $KeptItems = @()  # Thu thập thông tin items giữ lại
            
            foreach ($Item in $Items) {
                # Kiểm tra ngày xóa
                $DeletedDate = [DateTime]$Item.deletedDateTime
                
                if ($DeletedDate -lt $CutoffDate) {
                    $IdsToDelete += $Item.id
                }
                else {
                    $Stats.FirstStageKept++
                    # Lưu thông tin item giữ lại (tối đa 10 items để không spam)
                    if ($KeptItems.Count -lt 10) {
                        $KeptItems += @{
                            Name        = $Item.name
                            DeletedDate = $DeletedDate.ToString("dd/MM")
                        }
                    }
                }
            }
            
            # Lưu danh sách items giữ lại vào Stats
            $Stats.KeptItemsList = $KeptItems
            
            Write-Log -Message "Số items cần xóa (>$FirstStageRetentionDays ngày): $($IdsToDelete.Count)" -Level Info
            
            if ($IdsToDelete.Count -gt 0) {
                # Thử phương án 1: POST batch delete (theo format fileStorageContainer)
                try {
                    # URL delete endpoint
                    $DeleteUrl = "https://graph.microsoft.com/beta/sites/$SiteId/recyclebin/items/delete"
                    
                    # Body chứa mảng IDs
                    $DeleteBody = @{ ids = $IdsToDelete } | ConvertTo-Json -Compress
                    
                    # Headers với Content-Type
                    $DeleteHeaders = @{
                        Authorization  = "Bearer $Token"
                        "Content-Type" = "application/json"
                    }
                    
                    Write-Log -Message "Gọi POST $DeleteUrl với $($IdsToDelete.Count) IDs..." -Level Info
                    
                    Invoke-RestMethod -Method Post -Uri $DeleteUrl -Headers $DeleteHeaders -Body $DeleteBody -ErrorAction Stop
                    
                    Write-Log -Message "Đã xóa vĩnh viễn $($IdsToDelete.Count) items!" -Level Success
                    $Stats.FirstStageDeleted = $IdsToDelete.Count
                }
                catch {
                    Write-Log -Message "Lỗi batch delete: $($_.Exception.Message)" -Level Error
                    
                    # Nếu batch delete không hoạt động, thử DELETE từng item (fallback)
                    Write-Log -Message "Thử fallback: DELETE từng item..." -Level Warning
                    
                    foreach ($ItemId in $IdsToDelete) {
                        try {
                            # Thử format URL khác: /recyclebin/items/{id} (bỏ /items ở cuối RecycleBinUrl)
                            $SingleDeleteUrl = "https://graph.microsoft.com/beta/sites/$SiteId/recyclebin/items/$ItemId"
                            Invoke-RestMethod -Method Delete -Uri $SingleDeleteUrl -Headers $Headers -ErrorAction Stop
                            $Stats.FirstStageDeleted++
                        }
                        catch {
                            $Stats.Errors++
                        }
                    }
                }
            }
        }
        
    }
    catch {
        Write-Log -Message "Lỗi khi lấy danh sách Recycle Bin: $($_.Exception.Message)" -Level Error
        
        # Đọc chi tiết lỗi từ Response Stream (quan trọng cho Graph API)
        if ($_.Exception.Response) {
            try {
                $Reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $ErrorBody = $Reader.ReadToEnd()
                Write-Log -Message "CHI TIẾT LỖI TỪ API: $ErrorBody" -Level Error
            }
            catch {}
        }

        if ($_.Exception.Response.StatusCode -eq "Forbidden") {
            Write-Log -Message "GỢI Ý: Kiểm tra lại quyền API 'Sites.FullControl.All' trong Azure Portal (API Permissions)." -Level Warning
            Write-Log -Message "Lưu ý: User-delegated permissions không hoạt động ở đây, phải là APPLICATION permissions." -Level Info
        }
    }
    
    Write-Log -Message "Kết quả Cloud Cleanup:" -Level Info
    Write-Log -Message "  - Đã xóa vĩnh viễn: $($Stats.FirstStageDeleted) items" -Level Info
    Write-Log -Message "  - Giữ lại (an toàn): $($Stats.FirstStageKept) items" -Level Info
    Write-Log -Message "  - Lỗi: $($Stats.Errors) items" -Level Info
    Write-Log -Message "========== KẾT THÚC NHIỆM VỤ B ==========" -Level Info
    
    return $Stats
}

# ============================================================
# PHẦN 6: KIỂM TRA DUNG LƯỢNG ONEDRIVE
# ============================================================

<#
.SYNOPSIS
    Lấy thông tin dung lượng OneDrive qua Graph API
    
.DESCRIPTION
    Hàm này lấy ĐÚNG quota của OneDrive for Business personal site
    bằng cách sử dụng endpoint /users/{userPrincipalName}/drive
    
    UPDATE v2.2:
    - OneDrive Web UI hiển thị Used = Active Files + Recycle Bin (Deleted)
    - Graph API trả về riêng: quota.used (Active) và quota.deleted (Recycle Bin)
    - Cần cộng dồn để khớp với hiển thị 103.7GB của user
#>
function Get-OneDriveStorageQuota {
    param (
        $TenantId,
        $ClientId,
        $ClientSecret,
        $SiteUrl
    )
    
    try {
        # Lấy Token
        $Token = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        if (-not $Token) { return $null }
        
        $Headers = @{ Authorization = "Bearer $Token" }
        
        # QUAN TRỌNG: Trích xuất email từ SiteUrl của OneDrive for Business
        $UserPrincipalName = $null
        
        if ($SiteUrl -match "/personal/([^/]+)") {
            $PersonalPath = $Matches[1]
            $Parts = $PersonalPath -split "_"
            
            if ($Parts.Count -ge 3) {
                $User = $Parts[0..($Parts.Count - 3)] -join "_" 
                $Domain = $Parts[-2]
                $Tld = $Parts[-1]
                $UserPrincipalName = "$User@$Domain.$Tld"
            }
            elseif ($Parts.Count -eq 2) {
                $UserPrincipalName = $Parts[0] + "@" + $Parts[1]
            }
        }
        
        # Gọi API đúng endpoint
        if ($UserPrincipalName) {
            $DriveUrl = "https://graph.microsoft.com/v1.0/users/$UserPrincipalName/drive"
            Write-Log -Message "Checking Storage for User: $UserPrincipalName" -Level Info
        }
        else {
            $SiteId = Get-GraphSiteId -SiteUrl $SiteUrl -AccessToken $Token
            if (-not $SiteId) { return $null }
            $SiteId = "$SiteId".Trim()
            $DriveUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive"
        }
        
        $DriveInfo = Invoke-RestMethod -Method Get -Uri $DriveUrl -Headers $Headers -ErrorAction Stop
        
        if ($DriveInfo.quota) {
            # Tính toán lại theo logic OneDrive Web UI
            # Web UI Used = Used (Active) + Deleted (Recycle Bin)
            $ActiveUsed = $DriveInfo.quota.used
            $DeletedUsed = if ($DriveInfo.quota.deleted) { $DriveInfo.quota.deleted } else { 0 }
            
            $TotalUsed = $ActiveUsed + $DeletedUsed
            $Total = $DriveInfo.quota.total
            $Remaining = $DriveInfo.quota.remaining
            $UsedPercent = [math]::Round(($TotalUsed / $Total) * 100, 1)
            
            Write-Log -Message "STORAGE DETAIL:" -Level Info
            Write-Log -Message "  - Active Files: $([math]::Round($ActiveUsed/1GB, 2)) GB" -Level Info
            Write-Log -Message "  - Recycle Bin:  $([math]::Round($DeletedUsed/1GB, 2)) GB (Chiếm $([math]::Round(($DeletedUsed/$TotalUsed)*100,1))% dung lượng sử dụng)" -Level Info
            Write-Log -Message "  - TOTAL USED:   $([math]::Round($TotalUsed/1GB, 2)) GB (Khớp Web UI)" -Level Info
            
            return @{
                UsedBytes      = $TotalUsed
                ActiveBytes    = $ActiveUsed
                DeletedBytes   = $DeletedUsed
                TotalBytes     = $Total
                RemainingBytes = $Remaining
                UsedGB         = [math]::Round($TotalUsed / 1GB, 2)
                ActiveGB       = [math]::Round($ActiveUsed / 1GB, 2)
                DeletedGB      = [math]::Round($DeletedUsed / 1GB, 2)
                TotalGB        = [math]::Round($Total / 1GB, 2)
                RemainingGB    = [math]::Round($Remaining / 1GB, 2)
                UsedPercent    = $UsedPercent
            }
        }
    }
    catch {
        Write-Log -Message "Lỗi lấy thông tin dung lượng: $($_.Exception.Message)" -Level Warning
        if ($_.Exception.Response) {
            try {
                $Reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                Write-Log -Message "API Error: $($Reader.ReadToEnd())" -Level Warning
            }
            catch {}
        }
    }
    
    return $null
}

<#
.SYNOPSIS
    Lấy danh sách 10 files backup mới nhất trên OneDrive folder
#>
function Get-OneDriveBackupFiles {
    param (
        $TenantId,
        $ClientId,
        $ClientSecret,
        $SiteUrl,
        $BackupFolderPath = "Backup.SQL"
    )
    
    try {
        # Lấy Token
        $Token = Get-GraphAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
        if (-not $Token) { return $null }
        
        # Lấy Site ID
        $SiteId = Get-GraphSiteId -SiteUrl $SiteUrl -AccessToken $Token
        if (-not $SiteId) { return $null }
        $SiteId = "$SiteId".Trim()
        
        $Headers = @{ Authorization = "Bearer $Token" }
        
        # Lấy danh sách files trong folder (sắp xếp theo lastModifiedDateTime giảm dần)
        # Lấy top 30 files để đảm bảo quét đủ các unique DB (sắp xếp theo lastModifiedDateTime giảm dần)
        $FilesUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/$BackupFolderPath`:/children?`$top=30&`$orderby=lastModifiedDateTime%20desc&`$select=name,lastModifiedDateTime,size"
        
        Write-Log -Message "OneDrive Files URL: $FilesUrl" -Level Info
        
        $Response = Invoke-RestMethod -Method Get -Uri $FilesUrl -Headers $Headers -ErrorAction Stop
        
        Write-Log -Message "OneDrive: Tim thay $($Response.value.Count) files trong folder '$BackupFolderPath'" -Level Info
        
        $UniqueDBs = @{}
        $Files = @()
        
        foreach ($Item in $Response.value) {
            $Name = $Item.name
            
            # Extract DB Name logic (khá tương tự logic hiển thị nhưng đơn giản hơn để group)
            # Remove extension, date patterns, common keywords
            $DbName = $Name -replace '\.(bak|zip|7z)$', '' `
                -replace '_backup_\d{4}_\d{2}_\d{2}.*$', '' `
                -replace '_backup_\d{8}.*$', '' `
                -replace '_\d{8}', '' `
                -replace '_backup', '' `
                -replace 'backup', '' `
                -replace 'Full', '' 
            
            # Normalize: replace underscore with space only for display later, here keep simple
            $DbKey = $DbName.Trim().ToLower()
            
            if (-not $UniqueDBs.ContainsKey($DbKey)) {
                $UniqueDBs[$DbKey] = $true
                $Files += @{
                    Name   = $Name
                    Date   = ([DateTime]$Item.lastModifiedDateTime).ToLocalTime().ToString("dd/MM HH:mm")
                    SizeMB = [math]::Round($Item.size / 1MB, 1)
                }
            }
            
            # Chỉ lấy tối đa 10 unique files
            if ($Files.Count -ge 10) { break }
        }
        
        return $Files
    }
    catch {
        Write-Log -Message "Lỗi lấy danh sách files OneDrive: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# ============================================================
# PHẦN 7: THÔNG BÁO TELEGRAM
# ============================================================

<#
.SYNOPSIS
    Gửi thông báo qua Telegram Bot
#>
function Send-TelegramNotification {
    param (
        [string]$BotToken,
        [string]$ChatId,
        [string]$Message,
        [string]$ParseMode = "Markdown"
    )
    
    if ([string]::IsNullOrWhiteSpace($BotToken) -or $BotToken -like "*your-*") {
        Write-Log -Message "Telegram chưa được cấu hình, bỏ qua gửi thông báo" -Level Warning
        return $false
    }
    
    try {
        $TelegramUrl = "https://api.telegram.org/bot$BotToken/sendMessage"
        $Body = @{
            chat_id = $ChatId
            text    = $Message
        }
        
        $Response = Invoke-RestMethod -Method Post -Uri $TelegramUrl -Body $Body -ErrorAction Stop
        
        if ($Response.ok) {
            Write-Log -Message "Đã gửi thông báo Telegram thành công" -Level Success
            return $true
        }
    }
    catch {
        Write-Log -Message "Lỗi gửi Telegram: $($_.Exception.Message)" -Level Error
    }
    
    return $false
}

# ============================================================
# PHẦN 8: MAIN SCRIPT EXECUTION
# ============================================================

function Invoke-AutoCleanup {
    Write-Log -Message "╔════════════════════════════════════════════════════════════╗" -Level Info
    Write-Log -Message "║   AUTO BACKUP SQL CLEANUP - BFC SYSTEM (GRAPH API)       ║" -Level Info
    Write-Log -Message "║   Phiên bản: 2.1.0 | Ngày: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')    ║" -Level Info
    Write-Log -Message "╚════════════════════════════════════════════════════════════╝" -Level Info

    # Biến theo dõi trạng thái
    $ScriptStatus = "SUCCESS"
    $ErrorMessages = @()

    # Bước 1: Đọc Config
    Write-Log -Message "Bước 1: Đọc cấu hình..." -Level Info
    $Config = Read-Configuration -ConfigFilePath $ConfigPath
    if (-not $Config) { 
        $ScriptStatus = "FAILED"
        $ErrorMessages += "Không thể đọc config"
        return 
    }

    # Bước 2: Local Cleanup
    Write-Log -Message "`nBước 2: Thực hiện dọn dẹp Local..." -Level Info
    $LocalStats = Invoke-LocalBackupCleanup `
        -BackupPath $Config.LocalBackup.Path `
        -RetentionMinutes $Config.LocalBackup.RetentionMinutes `
        -Extensions $Config.LocalBackup.Extensions
        
    # Bước 3: Cloud Cleanup (Graph API)
    Write-Log -Message "`nBước 3: Thực hiện dọn dẹp Cloud (Microsoft Graph)..." -Level Info
    
    $CloudStats = Invoke-CloudRecycleBinCleanup `
        -TenantId $Config.AzureAD.TenantId `
        -ClientId $Config.AzureAD.ClientId `
        -ClientSecret $Config.AzureAD.ClientSecret `
        -SiteUrl $Config.OneDrive.SiteUrl `
        -FirstStageRetentionDays $Config.CloudRecycleBin.FirstStageRetentionDays `
        -RowLimit $Config.CloudRecycleBin.RowLimit
    
    if ($CloudStats.Errors -gt 0) {
        $ScriptStatus = "WARNING"
        $ErrorMessages += "Cloud cleanup có $($CloudStats.Errors) lỗi"
    }
    
    # Bước 4: Kiểm tra dung lượng OneDrive
    Write-Log -Message "`nBước 4: Kiểm tra dung lượng OneDrive..." -Level Info
    
    $StorageQuota = Get-OneDriveStorageQuota `
        -TenantId $Config.AzureAD.TenantId `
        -ClientId $Config.AzureAD.ClientId `
        -ClientSecret $Config.AzureAD.ClientSecret `
        -SiteUrl $Config.OneDrive.SiteUrl
    
    $StorageWarning = $false
    $WarningThreshold = 70
    if ($Config.StorageAlert -and $Config.StorageAlert.WarningThresholdPercent) {
        $WarningThreshold = $Config.StorageAlert.WarningThresholdPercent
    }
    
    if ($StorageQuota) {
        Write-Log -Message "Dung lượng: $($StorageQuota.UsedGB) GB / $($StorageQuota.TotalGB) GB ($($StorageQuota.UsedPercent)%)" -Level Info
        
        if ($StorageQuota.UsedPercent -ge $WarningThreshold) {
            $StorageWarning = $true
            $ScriptStatus = "WARNING"
            Write-Log -Message "⚠️ CẢNH BÁO: Dung lượng đã vượt $WarningThreshold%! Cần dọn Second-Stage Recycle Bin!" -Level Warning
        }
    }
    
    # Bước 5: Lấy danh sách files backup đang có trên OneDrive
    $BackupFolderPath = if ($Config.OneDrive.BackupFolderPath) { $Config.OneDrive.BackupFolderPath } else { "Backup.SQL" }
    $OneDriveFiles = Get-OneDriveBackupFiles `
        -TenantId $Config.AzureAD.TenantId `
        -ClientId $Config.AzureAD.ClientId `
        -ClientSecret $Config.AzureAD.ClientSecret `
        -SiteUrl $Config.OneDrive.SiteUrl `
        -BackupFolderPath $BackupFolderPath
        
    # Bước 6: Tổng kết
    Write-Log -Message "`n╔════════════════════════════════════════════════════════════╗" -Level Info
    Write-Log -Message "║                    TỔNG KẾT KẾT QUẢ                        ║" -Level Info
    Write-Log -Message "╠════════════════════════════════════════════════════════════╣" -Level Info
    Write-Log -Message "║ LOCAL CLEANUP:                                             ║" -Level Info
    Write-Log -Message "║   - Đã xóa: $($LocalStats.Deleted) files                   ║" -Level Info
    Write-Log -Message "║   - Giữ lại: $($LocalStats.Skipped) files                  ║" -Level Info
    Write-Log -Message "║   - Lỗi: $($LocalStats.Failed) files                       ║" -Level Info
    Write-Log -Message "╠════════════════════════════════════════════════════════════╣" -Level Info
    Write-Log -Message "║ CLOUD CLEANUP:                                             ║" -Level Info
    Write-Log -Message "║   - Đã xóa: $($CloudStats.FirstStageDeleted) items         ║" -Level Info
    Write-Log -Message "║   - Giữ lại: $($CloudStats.FirstStageKept) items           ║" -Level Info
    if ($StorageQuota) {
        Write-Log -Message "╠════════════════════════════════════════════════════════════╣" -Level Info
        Write-Log -Message "║ STORAGE: $($StorageQuota.UsedGB) GB / $($StorageQuota.TotalGB) GB ($($StorageQuota.UsedPercent)%)     ║" -Level Info
    }
    Write-Log -Message "╚════════════════════════════════════════════════════════════╝" -Level Info
    
    Write-Log -Message "`nScript hoàn thành lúc $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level Success
    
    # Bước 6: Gửi thông báo Telegram
    if ($Config.Telegram -and $Config.Telegram.BotToken) {
        Write-Log -Message "`nBước 5: Gửi thông báo Telegram..." -Level Info
        
        # Tạo nội dung thông báo
        $StatusEmoji = switch ($ScriptStatus) {
            "SUCCESS" { "✅" }
            "WARNING" { "⚠️" }
            "FAILED" { "❌" }
        }
        
        # Header
        $Header = "$StatusEmoji BFC SQL BACKUP"
        
        # Dòng 1: Dung lượng còn
        $StorageLine = ""
        if ($StorageQuota) {
            # Nếu dung lượng >= 80% -> CẢNH BÁO MẠNH (Hot Alert)
            if ($StorageQuota.UsedPercent -ge 80) {
                $Header = "🚨 STORAGE CRITICAL - BFC BACKUP"
                $StorageLine = "🔥 FULL: $($StorageQuota.UsedGB)/$($StorageQuota.TotalGB)GB ($($StorageQuota.UsedPercent)%)"
                $StorageLine += "`n⚠️ ACTION: SAP HET DUNG LUONG! CAN VAO XOA RECYCLE BIN THU CONG NGAY!"
            }
            else {
                # Bình thường
                $StorageIcon = if ($StorageQuota.UsedPercent -lt 50) { "🟢" } elseif ($StorageQuota.UsedPercent -lt 80) { "🟡" } else { "🔴" }
                $StorageLine = "$StorageIcon Used: $($StorageQuota.UsedGB)GB / $($StorageQuota.TotalGB)GB ($($StorageQuota.UsedPercent)%)"
            }
        }
        
        # Dòng 2+: Files trên OneDrive folder (chi tiết từng file)
        $OneDriveSection = ""
        if ($OneDriveFiles -and $OneDriveFiles.Count -gt 0) {
            $OneDriveSection = "📂 ONEDRIVE ($($OneDriveFiles.Count) files):"
            foreach ($File in $OneDriveFiles) {
                # Clean filename: bỏ extension, date format YYYY_MM_DD, backup keyword
                $CleanName = $File.Name -replace '\.(bak|zip|7z)$', '' `
                    -replace '_backup_\d{4}_\d{2}_\d{2}.*$', '' `
                    -replace '_backup_\d{8}.*$', '' `
                    -replace '_\d{8}', '' `
                    -replace '_backup', '' `
                    -replace 'backup', '' `
                    -replace 'Full', '' `
                    -replace '_', ' '
                
                $CleanName = $CleanName.Trim()
                if ($CleanName.Length -gt 25) {
                    $CleanName = $CleanName.Substring(0, 22) + ".."
                }
                
                $OneDriveSection += "`n  $($File.Date) $CleanName"
            }
        }
        else {
            $OneDriveSection = "📂 ONEDRIVE: N/A"
        }
        
        # Dòng cuối: Recycle bin status
        $RecycleLine = "🗑️ RECYCLE: $($CloudStats.FirstStageKept) items (3-day safe)"
        
        # Ghép message
        $TelegramMessage = @"
$Header
$StorageLine
$OneDriveSection
$RecycleLine
"@
        
        # Thêm cảnh báo nếu dung lượng cao
        if ($StorageWarning) {
            $TelegramMessage += "`n⚠️ Storage high! Clean 2nd-stage bin!"
        }
        
        Send-TelegramNotification `
            -BotToken $Config.Telegram.BotToken `
            -ChatId $Config.Telegram.ChatId `
            -Message $TelegramMessage
    }
}

# --- CHẠY MAIN FUNCTION ---
Invoke-AutoCleanup

