<#
.SYNOPSIS
Universal portable development environment manager with AUTO-CLEANUP on USB removal.

.DESCRIPTION
Automatically detects development tools and CLEANS UP when USB is removed.
The cleanup monitor is installed to the computer and runs independently.
#>
param(
    [ValidateSet('Install', 'Uninstall', 'Update')]
    [string]$Mode,
    
    [switch]$Force,
    [switch]$EnableAutoCleanup,
    
    [int]$ScanDepth = 4,
    [string]$ExcludePaths = ""
)

# --- Global Configuration ---
$script:REG_STATE_KEY = "HKCU:\Software\PortableT7Environment"
$script:MUTEX_NAME = "Global\PortableT7EnvironmentMutex_vFinal"
$script:LOG_FILE = Join-Path $env:TEMP "PortableT7_$(Get-Date -Format 'yyyyMMdd').log"

$script:MONITOR_SCRIPT_PATH = Join-Path $env:LOCALAPPDATA "PortableEnvMonitor\cleanup-monitor.ps1"
$script:MONITOR_TASK_NAME = "PortableEnvAutoCleanup"

$script:DETECTION_PATTERNS = $null
$script:ENV_VAR_PATTERNS = $null

# --- Default Configuration (used to bootstrap config.json if missing) ---
$script:DEFAULT_CONFIG = [ordered]@{
    DETECTION_PATTERNS = [ordered]@{
        IDE_Executables      = @(
            "devenv.exe", "Code.exe", "code.exe", "idea64.exe", "studio64.exe",
            "eclipse.exe", "pycharm64.exe", "webstorm64.exe", "rider64.exe", "clion64.exe"
        )
        Language_Executables = @(
            "java.exe", "javac.exe", "python.exe", "node.exe", "ruby.exe",
            "php.exe", "go.exe", "rustc.exe", "dotnet.exe", "gcc.exe",
            "g++.exe", "clang.exe"
        )
        Build_Executables    = @(
            "mvn.cmd", "mvn.bat", "gradle.bat", "gradle.cmd", "ant.bat",
            "msbuild.exe", "make.exe", "cmake.exe", "ninja.exe"
        )
        VCS_Executables      = @("git.exe", "svn.exe", "hg.exe")
        Database_Executables = @(
            "mysql.exe", "mysqld.exe", "psql.exe", "postgres.exe", "mongo.exe",
            "mongod.exe", "redis-server.exe", "sqlite3.exe"
        )
        Other_Executables    = @(
            "docker.exe", "kubectl.exe", "terraform.exe", "vagrant.exe", "adb.exe",
            "anaconda.exe"
        )
    }
    ENV_VAR_PATTERNS = [ordered]@{
        "java.exe|javac.exe" = [ordered]@{
            VarName       = "JAVA_HOME"
            ParentLevel   = 1
            AddBinToPath  = $true
        }
        "python.exe" = [ordered]@{
            VarName          = "PYTHON_HOME"
            ParentLevel      = 0
            AdditionalPaths  = @("Scripts")
        }
        "node.exe" = [ordered]@{
            VarName        = "NODE_HOME"
            ParentLevel    = 0
            AddBinToPath   = $true
            CheckNpmGlobal = $true
        }
        "mvn.cmd|mvn.bat" = [ordered]@{
            VarName       = "MAVEN_HOME"
            ParentLevel   = 1
            AddBinToPath  = $true
        }
        "gradle.bat|gradle.cmd" = [ordered]@{
            VarName       = "GRADLE_HOME"
            ParentLevel   = 1
            AddBinToPath  = $true
        }
        "go.exe" = [ordered]@{
            VarName       = "GOROOT"
            ParentLevel   = 1
            AddBinToPath  = $true
        }
    }
}

$script:EXECUTABLE_EXTENSIONS = @(".exe", ".bat", ".cmd")

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@

function Write-Log { 
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    try { Add-Content -Path $script:LOG_FILE -Value $logMessage -ErrorAction SilentlyContinue } catch {}
    switch ($Level) { 
        "ERROR" { Write-Host $logMessage -ForegroundColor Red } 
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow } 
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green } 
        default { Write-Host $logMessage } 
    } 
}

function Initialize-PortableConfiguration {
    $configPath = Join-Path $PSScriptRoot "config.json"
    $configObject = $null
    $configLoadedFromFile = $false
    $shouldWriteDefault = $false

    if (Test-Path $configPath) {
        try {
            $configContent = Get-Content -Path $configPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($configContent)) {
                $configObject = $configContent | ConvertFrom-Json -ErrorAction Stop
                $configLoadedFromFile = $true
            } else {
                Write-Log "config.json is empty. Falling back to defaults." "WARN"
            }
        } catch {
            Write-Log "Failed to load config.json. Falling back to defaults. Error: $_" "WARN"
        }
    } else {
        Write-Log "config.json not found. Generating default configuration..." "WARN"
        $shouldWriteDefault = $true
    }

    if (-not $configObject -or (-not $configObject.DETECTION_PATTERNS) -or (-not $configObject.ENV_VAR_PATTERNS)) {
        if ($configLoadedFromFile) {
            Write-Log "config.json is missing required keys. Using built-in defaults." "WARN"
        }
        $configObject = ($script:DEFAULT_CONFIG | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    }

    if ($shouldWriteDefault) {
        try {
            $defaultJson = $script:DEFAULT_CONFIG | ConvertTo-Json -Depth 5
            Set-Content -Path $configPath -Value $defaultJson -Encoding UTF8 -Force
            Write-Log "Default config.json created at $configPath" "INFO"
        } catch {
            Write-Log "Failed to write default config.json: $_" "WARN"
        }
    }

    $script:DETECTION_PATTERNS = $configObject.DETECTION_PATTERNS
    $script:ENV_VAR_PATTERNS = @{}

    if ($configObject.ENV_VAR_PATTERNS -is [hashtable]) {
        foreach ($key in $configObject.ENV_VAR_PATTERNS.Keys) {
            $script:ENV_VAR_PATTERNS[$key] = $configObject.ENV_VAR_PATTERNS[$key]
        }
    } else {
        $configObject.ENV_VAR_PATTERNS.PSObject.Properties | ForEach-Object {
            $script:ENV_VAR_PATTERNS[$_.Name] = $_.Value
        }
    }

    if (-not $script:DETECTION_PATTERNS -or $script:ENV_VAR_PATTERNS.Count -eq 0) {
        Write-Log "FATAL: Unable to initialize configuration state." "ERROR"
        exit 1
    }

    if ($configLoadedFromFile -and -not $shouldWriteDefault) {
        Write-Log "Successfully loaded configuration from config.json" "INFO"
    } else {
        Write-Log "Using built-in default configuration." "INFO"
    }
}

Initialize-PortableConfiguration

function Send-SettingChangeNotification { 
    try { 
        $result = [UIntPtr]::Zero
        $sendResult = [Win32]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result)
        return ($sendResult -ne [IntPtr]::Zero)
    } catch { 
        Write-Log "Broadcast failed: $_" "WARN"
        return $false 
    } 
}

function Test-RegistryWritePermission { 
    try { 
        $testKey = "HKCU:\Software\PortableT7Test_$(Get-Random)"
        New-Item $testKey -Force -EA Stop | Out-Null
        Remove-Item $testKey -Force -EA Stop
        return $true 
    } catch { return $false } 
}

function Get-MaskedSerial { 
    param([string]$Serial)
    if ([string]::IsNullOrWhiteSpace($Serial) -or $Serial -eq "UNKNOWN") { return "UNKNOWN" }
    if ($Serial.Length -le 4) { return "****" }
    return "****" + $Serial.Substring($Serial.Length - 4) 
}

function Get-PortableDriveInfo {
    Write-Log "Auto-detecting drive..."
    if (-not $PSCommandPath) {
        Write-Log "PSCommandPath not available (Running from ISE?)." "WARN"
        $driveLetter = (Get-Location).Drive.Name + ":"
    } else {
        $driveLetter = Split-Path $PSCommandPath -Qualifier
    }
    
    try {
        $volume = Get-Volume -DriveLetter ($driveLetter.TrimEnd(':')) -ErrorAction Stop
        $disk = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        
        $serial = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { "UNKNOWN" }
        $label = if ($volume.FileSystemLabel) { $volume.FileSystemLabel } else { "NO LABEL" }
        
        return @{ DriveLetter = $driveLetter; SerialNumber = $serial; Label = $label }
    } catch {
        Write-Log "Failed to detect drive info: $_" "ERROR"
        return $null
    }
}

function Test-DirectoryExcluded {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string[]]$ExcludePatterns
    )

    if (-not $Directory) { return $false }

    $dirName = $Directory.Name.ToLowerInvariant()
    $dirFull = $Directory.FullName.TrimEnd('\').ToLowerInvariant()

    foreach ($pattern in $ExcludePatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $normalized = $pattern.Trim().ToLowerInvariant()
        if ($normalized -eq "") { continue }

        if ($normalized -match "[\\/]") {
            $normalized = $normalized.Replace('/', '\\').Trim('\\')
            if ($dirFull.Contains($normalized)) {
                return $true
            }
        } else {
            if ($dirName -eq $normalized) {
                return $true
            }
        }
    }

    return $false
}

function Find-AllDevelopmentTools {
    param([string]$BasePath, [int]$MaxDepth, [string[]]$ExcludePaths, [Nullable[datetime]]$SinceTime)

    Write-Log "Starting comprehensive tool scan..." "INFO"
    $sinceUtc = $null
    if ($SinceTime) {
        $sinceUtc = $SinceTime.Value.ToUniversalTime()
        Write-Log "Incremental mode: skipping directories whose last modification is on or before $($sinceUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC." "INFO"
    }
    
    $excludeDirs = @(
        '$Recycle.Bin', 'System Volume Information', 'Recovery', 
        'Windows', 'ProgramData', 'AppData', '.git', 'node_modules',
        'temp', 'tmp', 'cache', 'backup', '__pycache__', '.vscode',
        'obj', 'bin\\Debug', 'bin\\Release'
    )
    
    if ($ExcludePaths) { $excludeDirs += $ExcludePaths }
    
    $priorityDirs = @("Programs", "PortableApps", "Tools", "Dev", "Development", "SDK")
    $searchRoots = @()
    
    foreach ($dir in $priorityDirs) {
        $path = Join-Path $BasePath $dir
        if (Test-Path $path) {
            $searchRoots += $path
            Write-Log "Found priority directory: $path" "INFO"
        }
    }
    
    if ($searchRoots.Count -eq 0) { $searchRoots = @($BasePath) }
    
    $allPatterns = @()
    foreach ($category in $script:DETECTION_PATTERNS.Values) { $allPatterns += $category }
    
    $detectedTools = @{}
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($root in $searchRoots) {
        Write-Log "Scanning: $root (depth: $MaxDepth)" "INFO"

        try {
            $rootDir = Get-Item -LiteralPath $root -ErrorAction Stop
        } catch {
            Write-Log "Error accessing $root : $_" "WARN"
            continue
        }

        $stack = New-Object System.Collections.Generic.Stack[hashtable]
        $stack.Push(@{ Directory = $rootDir; Depth = 0 })

        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $dirInfo = $frame.Directory
            $depth = $frame.Depth

            if (Test-DirectoryExcluded -Directory $dirInfo -ExcludePatterns $excludeDirs) { continue }

            if ($sinceUtc -and $depth -gt 0) {
                $lastChangeUtc = $dirInfo.LastWriteTimeUtc
                if ($dirInfo.CreationTimeUtc -gt $lastChangeUtc) {
                    $lastChangeUtc = $dirInfo.CreationTimeUtc
                }

                if ($lastChangeUtc -le $sinceUtc) {
                    Write-Log "[Skip] $($dirInfo.FullName) unchanged since last scan (LastWrite: $($dirInfo.LastWriteTimeUtc.ToString('u')))." "INFO"
                    continue
                }
            }

            $files = @()
            try {
                $files = $dirInfo.GetFiles('*', [System.IO.SearchOption]::TopDirectoryOnly) |
                    Where-Object { $script:EXECUTABLE_EXTENSIONS -contains $_.Extension.ToLowerInvariant() }
            } catch {
                Write-Log "Error enumerating files in $($dirInfo.FullName): $_" "WARN"
            }

            foreach ($exe in $files) {
                $exeName = $exe.Name

                foreach ($pattern in $allPatterns) {
                    if ($exeName -like $pattern -or $exeName -eq $pattern) {
                        $toolKey = $exeName.ToLower()

                        if (-not $detectedTools.ContainsKey($toolKey)) {
                            $detectedTools[$toolKey] = @()
                        }

                        $toolInfo = @{
                            ExecutablePath = $exe.FullName
                            Directory = $exe.DirectoryName
                            Name = $exe.BaseName
                            Category = Get-ToolCategory -ExeName $exeName
                        }

                        $detectedTools[$toolKey] += $toolInfo
                        Write-Log "Detected: $($toolInfo.Category) - $($exe.FullName)" "INFO"
                        break
                    }
                }
            }

            if ($depth -lt $MaxDepth) {
                try {
                    foreach ($subDir in $dirInfo.GetDirectories()) {
                        if (Test-DirectoryExcluded -Directory $subDir -ExcludePatterns $excludeDirs) { continue }
                        $stack.Push(@{ Directory = $subDir; Depth = $depth + 1 })
                    }
                } catch {
                    Write-Log "Error enumerating directories in $($dirInfo.FullName): $_" "WARN"
                }
            }
        }
    }
    
    $stopwatch.Stop()
    Write-Log "Scan completed in $($stopwatch.Elapsed.TotalSeconds.ToString('N2'))s, found $($detectedTools.Count) unique tools" "SUCCESS"
    
    return $detectedTools
}

function Get-ToolCategory {
    param([string]$ExeName)
    foreach ($categoryName in $script:DETECTION_PATTERNS.Keys) {
        if ($script:DETECTION_PATTERNS[$categoryName] -contains $ExeName) {
            return $categoryName -replace '_Executables', ''
        }
    }
    return "Unknown"
}

function Get-EnvironmentVarConfig {
    param([string]$ExeName)
    foreach ($pattern in $script:ENV_VAR_PATTERNS.Keys) {
        $patterns = $pattern -split '\|'
        if ($patterns -contains $ExeName) {
            return $script:ENV_VAR_PATTERNS[$pattern]
        }
    }
    return $null
}

function Add-PathSafely {
    param(
        [System.Collections.ArrayList]$PathList,
        [string]$NewPath,
        [string[]]$ExistingPaths,
        [switch]$AllowNested
    )

    $normalizedNew = $NewPath.TrimEnd('\\').ToLower()

    foreach ($p in $PathList) { if ($p.TrimEnd('\\').ToLower() -eq $normalizedNew) { return $false } }
    foreach ($p in $ExistingPaths) { if ($p.TrimEnd('\\').ToLower() -eq $normalizedNew) { return $false } }

    $toRemove = @()
    foreach ($existing in $PathList) {
        $normalizedExisting = $existing.TrimEnd('\\').ToLower()
        if (-not $AllowNested -and $normalizedNew.StartsWith($normalizedExisting + '\\')) { return $false }
        if ($normalizedExisting.StartsWith($normalizedNew + '\\')) { $toRemove += $existing }
    }
    foreach ($item in $toRemove) { $PathList.Remove($item) }
    
    $null = $PathList.Add($NewPath.TrimEnd('\\'))
    return $true
}

function Get-NpmGlobalPath {
    param([string]$NodeHomePath)
    
    try {
        $npmCmd = Join-Path $NodeHomePath "npm.cmd"
        if (-not (Test-Path $npmCmd)) {
            $npmCmd = Join-Path $NodeHomePath "npm"
            if (-not (Test-Path $npmCmd)) {
                Write-Log "npm not found in $NodeHomePath" "WARN"
                return $null
            }
        }

        $driveRoot = [System.IO.Path]::GetPathRoot($NodeHomePath)
        $portableDefault = Join-Path $NodeHomePath "npm-global"

        Write-Log "Detecting npm global prefix..." "INFO"
        $npmPrefix = & $npmCmd config get prefix 2>$null
        if ($npmPrefix) { $npmPrefix = $npmPrefix.Trim() }

        if ($npmPrefix) {
            $resolvedPrefix = $null
            try {
                $resolvedPrefix = Resolve-Path -LiteralPath $npmPrefix -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Path
            } catch {
                Write-Log "npm prefix path could not be resolved: $npmPrefix" "WARN"
            }

            if ($resolvedPrefix) {
                if ($driveRoot -and $resolvedPrefix.StartsWith($driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-Log "npm global prefix detected: $resolvedPrefix" "SUCCESS"
                    return [pscustomobject]@{ Path = $resolvedPrefix; Managed = $false }
                } else {
                    Write-Log "npm prefix is outside the portable drive. Using portable override." "WARN"
                }
            }
        } else {
            Write-Log "npm global prefix not configured. Using portable default." "WARN"
        }

        try {
            if (-not (Test-Path $portableDefault)) {
                New-Item -Path $portableDefault -ItemType Directory -Force | Out-Null
            }
        } catch {
            Write-Log "Failed to prepare portable npm prefix directory: $_" "WARN"
        }

        Write-Log "Using portable npm prefix: $portableDefault" "INFO"
        return [pscustomobject]@{ Path = $portableDefault; Managed = $true }
    } catch {
        Write-Log "Failed to detect npm global path: $_" "WARN"
        return $null
    }
}

function Install-AutoCleanupMonitor {
    Write-Log "Installing auto-cleanup monitor..." "INFO"

    try {
        # --- 필수 전역 변수 확인 ---
        if (-not $script:MONITOR_SCRIPT_PATH) {
            throw "MONITOR_SCRIPT_PATH is not defined."
        }
        if (-not $script:MONITOR_TASK_NAME) {
            throw "MONITOR_TASK_NAME is not defined."
        }

        $monitorDir = Split-Path $script:MONITOR_SCRIPT_PATH -Parent
        if (-not (Test-Path $monitorDir)) {
            New-Item -Path $monitorDir -ItemType Directory -Force | Out-Null
        }

        # --- 내부 모니터 스크립트 내용 ---
        $monitorScriptContent = @'
param([switch]$Check)

$REG_STATE_KEY = "HKCU:\Software\PortableT7Environment"
$LOG_FILE = Join-Path $env:TEMP "PortableEnvMonitor_$(Get-Date -Format 'yyyyMMdd').log"

function Write-MonitorLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path $LOG_FILE -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
    } catch {}
}

function Test-DriveConnected {
    param([string]$DriveLetter, [string]$SerialNumber)

    if ([string]::IsNullOrEmpty($DriveLetter)) { return $false }

    $drive = $DriveLetter.TrimEnd(':')
    if (-not (Test-Path ("{0}:" -f $drive))) {
        Write-MonitorLog "Drive $DriveLetter not found"
        return $false
    }

    if ($SerialNumber -and $SerialNumber -ne "UNKNOWN") {
        try {
            Get-Item ("{0}:" -f $drive) -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-MonitorLog "Error checking drive: $_"
            return $false
        }
    }

    return $true
}

function Remove-PortableEnvironment {
    Write-MonitorLog "=== Auto-Cleanup Triggered ==="

    try {
        $envRegPath = "HKCU:\Environment"
        if (-not (Test-Path $REG_STATE_KEY)) { return }

        $state = Get-ItemProperty -Path $REG_STATE_KEY -ErrorAction Stop

        if ($state.PSObject.Properties.Name -contains "OriginalPath") {
            Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $state.OriginalPath -ErrorAction Stop
            Write-MonitorLog "PATH restored"
        }

        $excludedProps = @(
            "OriginalPath", "AddedPaths", "DriveLetter", "SerialNumber",
            "Label", "DetectedToolsCount", "PSPath", "PSParentPath",
            "PSChildName", "PSDrive", "PSProvider"
        )

        $removedCount = 0
        $state.PSObject.Properties | Where-Object { $_.Name -notin $excludedProps } | ForEach-Object {
            Remove-ItemProperty -Path $envRegPath -Name $_.Name -Force -ErrorAction SilentlyContinue
            $removedCount++
            Write-MonitorLog "Removed: $($_.Name)"
        }

        Remove-Item -Path $REG_STATE_KEY -Recurse -Force -ErrorAction Stop

        # --- Here-String 중첩 오류 수정 ---
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@

        $result = [UIntPtr]::Zero
        [Win32]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, "Environment",
            2, 5000, [ref]$result
        ) | Out-Null

        Write-MonitorLog "Auto-cleanup completed successfully."
    } catch {
        Write-MonitorLog "Auto-cleanup error: $_"
    }
}

if ($Check) {
    if (-not (Test-Path $REG_STATE_KEY)) {
        exit 0
    }

    try {
        $state = Get-ItemProperty -Path $REG_STATE_KEY -ErrorAction Stop
        $driveLetter = $state.DriveLetter
        $serialNumber = $state.SerialNumber

        if (-not (Test-DriveConnected -DriveLetter $driveLetter -SerialNumber $serialNumber)) {
            Write-MonitorLog "USB disconnected! Starting auto-cleanup..."
            Remove-PortableEnvironment
        }
    } catch {
        Write-MonitorLog "Error during check: $_"
    }
}
'@

        # --- 모니터 스크립트 저장 ---
        Set-Content -Path $script:MONITOR_SCRIPT_PATH -Value $monitorScriptContent -Encoding UTF8 -Force
        Write-Log "Monitor script created: $script:MONITOR_SCRIPT_PATH" "SUCCESS"

        # --- 기존 태스크 제거 ---
        $existingTask = Get-ScheduledTask -TaskName $script:MONITOR_TASK_NAME -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $script:MONITOR_TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
        }

        # --- 스케줄러 등록 ---
        $escapedPath = $script:MONITOR_SCRIPT_PATH.Replace('"', '""')
        $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$escapedPath`" -Check"

        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) `
            -RepetitionDuration ([TimeSpan]::MaxValue)

        $currentUser = "$env:UserDomain\$env:UserName"
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel LeastPrivilege

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable:$false `
            -Hidden `
            -ExecutionTimeLimit (New-TimeSpan -Seconds 30)

        Register-ScheduledTask `
            -TaskName $script:MONITOR_TASK_NAME `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Portable Environment Auto-Cleanup" `
            -ErrorAction Stop | Out-Null

        Write-Log "Auto-cleanup monitor installed!" "SUCCESS"
        Write-Log "  Monitors USB every 1 minute." "INFO"

        return $true
    } catch {
        Write-Log "Failed to install monitor: $_" "ERROR"
        return $false
    }
}

function Uninstall-AutoCleanupMonitor {
    Write-Log "Removing auto-cleanup monitor..." "INFO"
    
    try {
        $existingTask = Get-ScheduledTask -TaskName $script:MONITOR_TASK_NAME -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $script:MONITOR_TASK_NAME -Confirm:$false -ErrorAction Stop
            Write-Log "Scheduled task removed" "INFO"
        }
        
        if (Test-Path $script:MONITOR_SCRIPT_PATH) {
            Remove-Item -Path $script:MONITOR_SCRIPT_PATH -Force -ErrorAction Stop
            Write-Log "Monitor script removed" "INFO"
        }
        
        $monitorDir = Split-Path $script:MONITOR_SCRIPT_PATH -Parent
        if ((Test-Path $monitorDir) -and ((Get-ChildItem $monitorDir).Count -eq 0)) {
            Remove-Item -Path $monitorDir -Force -ErrorAction SilentlyContinue
        }
        
        Write-Log "Auto-cleanup monitor uninstalled" "SUCCESS"
    } catch {
        Write-Log "Error removing monitor: $_" "WARN"
    }
}

function Get-ProposedEnvironmentChanges {
    param(
        $DetectedTools,
        $OriginalPathArray
    )

    $pathsToAdd = New-Object System.Collections.ArrayList
    $pathsToEnsure = New-Object System.Collections.ArrayList
    $envVarsToSet = @{}
    $toolStats = @{}

    foreach ($toolKey in $DetectedTools.Keys) {
        $instances = $DetectedTools[$toolKey]
        $instance = $instances[0]
        $category = $instance.Category
        
        if (-not $toolStats.ContainsKey($category)) { $toolStats[$category] = 0 }
        $toolStats[$category] += $instances.Count
        
        $exeDir = $instance.Directory
        $exeName = $instance.Name + $instance.ExecutablePath.Substring($instance.ExecutablePath.LastIndexOf('.'))
        
        $envConfig = Get-EnvironmentVarConfig -ExeName $exeName
        
        if ($envConfig -and $envConfig.VarName) {
            if (-not $envVarsToSet.ContainsKey($envConfig.VarName)) {
                $varPath = $exeDir
                for ($i = 0; $i -lt $envConfig.ParentLevel; $i++) { $varPath = Split-Path $varPath -Parent }
                
                $envVarsToSet[$envConfig.VarName] = $varPath
                
                if ($envConfig.AddBinToPath) {
                    $binPath = Join-Path $varPath "bin"
                    if (Test-Path $binPath) {
                        Add-PathSafely -PathList $pathsToAdd -NewPath $binPath -ExistingPaths $originalPathArray | Out-Null
                    } else {
                        if (Test-Path $varPath) {
                            Add-PathSafely -PathList $pathsToAdd -NewPath $varPath -ExistingPaths $originalPathArray | Out-Null
                        }
                    }
                }
                
                if ($envConfig.AdditionalPaths) {
                    foreach ($addPath in $envConfig.AdditionalPaths) {
                        $fullPath = Join-Path $varPath $addPath
                        if (Test-Path $fullPath) {
                            Add-PathSafely -PathList $pathsToAdd -NewPath $fullPath -ExistingPaths $originalPathArray | Out-Null
                        }
                    }
                }
                
                if ($envConfig.CheckNpmGlobal) {
                    $npmGlobalInfo = Get-NpmGlobalPath -NodeHomePath $varPath
                    if ($npmGlobalInfo -and $npmGlobalInfo.Path) {
                        $npmPrefixPath = $npmGlobalInfo.Path
                        Add-PathSafely -PathList $pathsToAdd -NewPath $npmPrefixPath -ExistingPaths $originalPathArray | Out-Null

                        $npmBinPath = Join-Path $npmPrefixPath "node_modules\.bin"
                        Add-PathSafely -PathList $pathsToAdd -NewPath $npmBinPath -ExistingPaths $originalPathArray -AllowNested:$true | Out-Null

                        if (-not $envVarsToSet.ContainsKey('NPM_CONFIG_PREFIX')) {
                            $envVarsToSet['NPM_CONFIG_PREFIX'] = $npmPrefixPath
                        }

                        if ($npmGlobalInfo.Managed) {
                            foreach ($ensure in @($npmPrefixPath, (Join-Path $npmPrefixPath "node_modules"), $npmBinPath)) {
                                if ($ensure) { $null = $pathsToEnsure.Add($ensure) }
                            }
                        }
                    }
                }
            }
        }
        else {
            Add-PathSafely -PathList $pathsToAdd -NewPath $exeDir -ExistingPaths $originalPathArray | Out-Null
        }
    }

    return @{
        PathsToAdd = $pathsToAdd
        PathsToEnsure = $pathsToEnsure
        EnvVarsToSet = $envVarsToSet
        ToolStats = $toolStats
    }
}

function Register-Environment {
    param([switch]$Force)
    $mutex = $null
    $lockAcquired = $false
    
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:MUTEX_NAME)
        $lockAcquired = $mutex.WaitOne(5000)
        if (-not $lockAcquired) { 
            Write-Log "Could not acquire lock." "WARN"
            return 
        }

        if (Test-Path $script:REG_STATE_KEY) {
            if ($Force) {
                Write-Log "Force flag: unregistering existing..." "INFO"
                Unregister-Environment -SkipLock -Mutex $mutex
            } else {
                Write-Log "Already registered. Use Update or Uninstall, or Force Install." "WARN"
                return
            }
        }

        $driveInfo = Get-PortableDriveInfo
        if (-not $driveInfo) { return }

        $maskedSerial = Get-MaskedSerial $driveInfo.SerialNumber
        Write-Log "Drive: $($driveInfo.DriveLetter) (Label: $($driveInfo.Label), S/N: $maskedSerial)" "INFO"
        
        $excludeList = if ($ExcludePaths) { $ExcludePaths -split ',' | ForEach-Object { $_.Trim() } } else { @() }
        
        $detectedTools = Find-AllDevelopmentTools -BasePath $driveInfo.DriveLetter `
            -MaxDepth $ScanDepth -ExcludePaths $excludeList -SinceTime $null
        
        if ($detectedTools.Count -eq 0) {
            Write-Log "No development tools detected!" "WARN"
            return
        }
        
        try {
            $envRegPath = "HKCU:\Environment"
            $originalPath = (Get-ItemProperty -Path $envRegPath -Name PATH -ErrorAction SilentlyContinue).PATH
            if (-not $originalPath) { $originalPath = "" }
            
            $originalPathArray = @()
            if ($originalPath -ne "") {
                $originalPathArray = $originalPath -split ';' | Where-Object { $_ -ne '' }
            }

            $changes = Get-ProposedEnvironmentChanges -DetectedTools $detectedTools -OriginalPathArray $originalPathArray
            $pathsToAdd = $changes.PathsToAdd
            $pathsToEnsure = $changes.PathsToEnsure
            $envVarsToSet = $changes.EnvVarsToSet
            $toolStats = $changes.ToolStats

            # --- Display Summary and Ask for Confirmation ---
            Write-Log "================== Proposed Changes ==================" "INFO"
            Write-Log "The following changes will be made to your environment:" "INFO"
            
            $envVarsToSet.Keys | ForEach-Object {
                Write-Log "[SET VAR]  $($_) = $($envVarsToSet[$_])"
            }
            $pathsToAdd | ForEach-Object {
                Write-Log "[ADD PATH] $_"
            }

            if (($envVarsToSet.Count -eq 0) -and ($pathsToAdd.Count -eq 0)) {
                Write-Log "No new environment changes are needed." "INFO"
            } else {
                Write-Log "======================================================" "INFO"
                $confirmation = Read-Host "Do you want to apply these changes? [Y/N]"
                if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
                    Write-Log "Operation cancelled by user." "WARN"
                    return
                }
            }

            # --- Apply Confirmed Changes ---
            Write-Log "Applying changes..." "INFO"

            if ($pathsToEnsure -and $pathsToEnsure.Count -gt 0) {
                foreach ($ensurePath in ($pathsToEnsure | Where-Object { $_ } | Sort-Object -Unique)) {
                    try {
                        if (-not (Test-Path $ensurePath)) {
                            New-Item -Path $ensurePath -ItemType Directory -Force | Out-Null
                            Write-Log "Prepared directory: $ensurePath" "INFO"
                        }
                    } catch {
                        Write-Log "Failed to prepare directory $ensurePath : $_" "WARN"
                    }
                }
            }

            $stateBackup = @{ 
                "OriginalPath" = $originalPath
                "DriveLetter" = $driveInfo.DriveLetter
                "SerialNumber" = $driveInfo.SerialNumber
                "Label" = $driveInfo.Label
            }

            foreach ($varName in $envVarsToSet.Keys) {
                $varValue = $envVarsToSet[$varName]
                Set-ItemProperty -Path $envRegPath -Name $varName -Value $varValue -ErrorAction Stop
                $stateBackup[$varName] = $varValue
                Write-Log "Set $($varName) = $varValue" "SUCCESS"
            }
            
            if ($pathsToAdd.Count -gt 0) {
                $newPath = (($pathsToAdd -join ';') + ";" + $originalPath).Trim(';')
                Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $newPath -ErrorAction Stop
                $stateBackup["AddedPaths"] = ($pathsToAdd -join ';')
                Write-Log "Updated PATH with $($pathsToAdd.Count) new entries." "SUCCESS"
            }

            Write-Log "=== Detection Summary ===" "SUCCESS"
            foreach ($cat in $toolStats.Keys | Sort-Object) { Write-Log "$cat : $($toolStats[$cat]) instances" "INFO" }
            Write-Log "HOME Variables Set: $($envVarsToSet.Count)" "SUCCESS"
            Write-Log "PATH Entries Added: $($pathsToAdd.Count)" "SUCCESS"

            if (-not (Test-Path $script:REG_STATE_KEY)) { New-Item -Path $script:REG_STATE_KEY -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "DetectedToolsCount" -Value $detectedTools.Count -ErrorAction Stop
            foreach ($key in $stateBackup.Keys) {
                Set-ItemProperty -Path $script:REG_STATE_KEY -Name $key -Value $stateBackup[$key] -ErrorAction Stop
            }
            $installScanTimestamp = [datetime]::UtcNow
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "LastScanTimestamp" -Value $installScanTimestamp.ToString("o") -ErrorAction Stop

            if ($EnableAutoCleanup) {
                Write-Log "" "INFO"
                if (Install-AutoCleanupMonitor) {
                    # OK
                } else {
                    Write-Log "Auto-cleanup installation failed." "WARN"
                }
            }

            if (Send-SettingChangeNotification) { 
                Write-Log "" "INFO"
                Write-Log "Environment registered successfully!" "SUCCESS" 
            } else { 
                Write-Log "Registered (Explorer restart may be needed)" "SUCCESS" 
            }

        } catch {
            Write-Log "Fatal error during registration: $_" "ERROR"
            Write-Log "Rolling back changes..." "INFO"
            Unregister-Environment -SkipLock -Mutex $mutex
            throw
        }
    } finally {
        if ($lockAcquired -and $mutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Update-Environment {
    Write-Log "=== Incremental Update Mode ===" "INFO"
    $mutex = $null
    $lockAcquired = $false
    
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:MUTEX_NAME)
        $lockAcquired = $mutex.WaitOne(5000)
        if (-not $lockAcquired) { Write-Log "Could not acquire lock." "WARN"; return }

        if (-not (Test-Path $script:REG_STATE_KEY)) {
            Write-Log "No existing registration found. Running Install..." "WARN"
            Register-Environment
            return
        }

        $driveInfo = Get-PortableDriveInfo
        if (-not $driveInfo) { return }

        $state = Get-ItemProperty -Path $script:REG_STATE_KEY -ErrorAction Stop
        $envRegPath = "HKCU:\Environment"
        
        $currentSystemPath = (Get-ItemProperty -Path $envRegPath -Name PATH -ErrorAction SilentlyContinue).PATH
        if (-not $currentSystemPath) { $currentSystemPath = "" }
        $currentPathArray = $currentSystemPath -split ';' | Where-Object { $_ -ne '' }

        $lastScanTime = $null
        if ($state.PSObject.Properties.Name -contains "LastScanTimestamp") {
            try {
                $lastScanTime = [datetime]::Parse($state.LastScanTimestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            } catch {}
        }

        $excludeList = if ($ExcludePaths) { $ExcludePaths -split ',' | ForEach-Object { $_.Trim() } } else { @() }
        $scanTimestamp = [datetime]::UtcNow
        $detectedTools = Find-AllDevelopmentTools -BasePath $driveInfo.DriveLetter `
            -MaxDepth $ScanDepth -ExcludePaths $excludeList -SinceTime $lastScanTime

        if ($detectedTools.Count -eq 0) {
            Write-Log "No new tools detected since last scan." "INFO"
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "LastScanTimestamp" -Value $scanTimestamp.ToString("o") -ErrorAction SilentlyContinue
            return
        }

        $changes = Get-ProposedEnvironmentChanges -DetectedTools $detectedTools -OriginalPathArray $currentPathArray
        $pathsToAdd = $changes.PathsToAdd
        $pathsToEnsure = $changes.PathsToEnsure
        $envVarsToSet = $changes.EnvVarsToSet

        # In Update mode, only set variables that are new or have changed.
        $varsToUpdate = @{}
        foreach ($varName in $envVarsToSet.Keys) {
            $currentValue = (Get-ItemProperty -Path $envRegPath -Name $varName -ErrorAction SilentlyContinue).($varName)
            $newValue = $envVarsToSet[$varName]
            if ($null -eq $currentValue -or $currentValue -ne $newValue) {
                $varsToUpdate[$varName] = $newValue
            }
        }

        $newToolsCount = $pathsToAdd.Count + $varsToUpdate.Count

        # --- Display Summary and Ask for Confirmation ---
        Write-Log "================== Proposed Changes (Update) ==================" "INFO"
        $varsToUpdate.Keys | ForEach-Object {
            Write-Log "[SET VAR]  $($_) = $($varsToUpdate[$_])"
        }
        $pathsToAdd | ForEach-Object {
            Write-Log "[ADD PATH] $_"
        }

        if ($newToolsCount -eq 0) {
            Write-Log "No new environment changes are needed." "INFO"
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "LastScanTimestamp" -Value $scanTimestamp.ToString("o") -ErrorAction SilentlyContinue
            return
        } 
        
        Write-Log "===========================================================" "INFO"
        $confirmation = Read-Host "Do you want to apply these $newToolsCount updates? [Y/N]"
        if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
            Write-Log "Update cancelled by user." "WARN"
            return
        }

        # --- Apply Confirmed Changes ---
        Write-Log "Applying updates..." "INFO"

        if ($pathsToEnsure -and $pathsToEnsure.Count -gt 0) {
            foreach ($ensurePath in ($pathsToEnsure | Where-Object { $_ } | Sort-Object -Unique)) {
                try {
                    if (-not (Test-Path $ensurePath)) {
                        New-Item -Path $ensurePath -ItemType Directory -Force | Out-Null
                        Write-Log "Prepared directory: $ensurePath" "INFO"
                    }
                } catch {
                    Write-Log "Failed to prepare directory $ensurePath : $_" "WARN"
                }
            }
        }

        foreach ($varName in $varsToUpdate.Keys) {
            $varValue = $varsToUpdate[$varName]
            Set-ItemProperty -Path $envRegPath -Name $varName -Value $varValue -ErrorAction Stop
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name $varName -Value $varValue -ErrorAction Stop
            Write-Log "[NEW] Set $($varName) = $varValue" "SUCCESS"
        }
        
        if ($pathsToAdd.Count -gt 0) {
            $newPath = (($pathsToAdd -join ';') + ";" + $currentSystemPath).Trim(';')
            Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $newPath -ErrorAction Stop
            
            $prevAdded = if ($state.AddedPaths) { $state.AddedPaths } else { "" }
            $combinedAdded = (($pathsToAdd -join ';') + ";" + $prevAdded).Trim(';')
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "AddedPaths" -Value $combinedAdded -ErrorAction Stop
        }

        $newDetectedCount = $state.DetectedToolsCount + $detectedTools.Count
        Set-ItemProperty -Path $script:REG_STATE_KEY -Name "DetectedToolsCount" -Value $newDetectedCount -ErrorAction Stop
        Set-ItemProperty -Path $script:REG_STATE_KEY -Name "LastScanTimestamp" -Value $scanTimestamp.ToString("o") -ErrorAction Stop

        if ($newToolsCount -gt 0) {
            if (Send-SettingChangeNotification) { 
                Write-Log "Update complete. Added $newToolsCount new configurations." "SUCCESS" 
            } else { Write-Log "Update complete (restart needed)." "SUCCESS" }
        }
        
    } catch {
        Write-Log "Update failed: $_" "ERROR"
    } finally {
        if ($lockAcquired -and $mutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Unregister-Environment {
    param([switch]$SkipLock, [System.Threading.Mutex]$Mutex)
    $localMutex = $null
    $lockAcquired = $false
    
    try {
        if (-not ($SkipLock -and $Mutex)) {
            $localMutex = New-Object System.Threading.Mutex($false, $script:MUTEX_NAME)
            $lockAcquired = $localMutex.WaitOne(5000)
            if (-not $lockAcquired) { 
                Write-Log "Could not acquire lock for unregister." "WARN"
                return 
            }
        }

        Uninstall-AutoCleanupMonitor

        if (-not (Test-Path $script:REG_STATE_KEY)) { 
            Write-Log "No environment registration found to remove." "INFO"
            return 
        }

        Write-Log "Restoring original environment..." "INFO"
        $envRegPath = "HKCU:\Environment"
        $state = Get-ItemProperty -Path $script:REG_STATE_KEY -ErrorAction SilentlyContinue
        
        if (-not $state) {
            Remove-Item -Path $script:REG_STATE_KEY -Recurse -Force -EA SilentlyContinue
            return 
        }

        if ($state.PSObject.Properties.Name -contains "OriginalPath") { 
            Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $state.OriginalPath -ErrorAction SilentlyContinue
            Write-Log "Original PATH restored." "SUCCESS"
        }
        
        $metaProps = @("OriginalPath", "AddedPaths", "DriveLetter", "SerialNumber", 
                      "Label", "DetectedToolsCount", "LastScanTimestamp", "PSPath", "PSParentPath",
                      "PSChildName", "PSDrive", "PSProvider")
        
        $varsToRemove = $state.psobject.Properties | Where-Object { $_.Name -notin $metaProps }
        foreach ($prop in $varsToRemove) {
            Remove-ItemProperty -Path $envRegPath -Name $prop.Name -Force -ErrorAction SilentlyContinue
            Write-Log "Removed variable: $($prop.Name)" "INFO"
        }
        
        Remove-Item -Path $script:REG_STATE_KEY -Recurse -Force -ErrorAction Stop
        
        Send-SettingChangeNotification | Out-Null
        Write-Log "Unregistration complete." "SUCCESS"

    } catch {
        Write-Log "Unregistration error: $_" "ERROR"
    } finally {
        if ($lockAcquired -and $localMutex) { $localMutex.ReleaseMutex() }
        if ($localMutex) { $localMutex.Dispose() }
    }
}

# --- Main Execution ---

if (-not (Test-RegistryWritePermission)) { 
    Write-Log "FATAL: Cannot write to Registry (HKCU). Check permissions or antivirus." "ERROR"
    exit 1 
}

Write-Log "=== Universal Portable Environment Manager | Mode: $Mode ===" "INFO"

try {
    switch ($Mode) {
        'Install'   { Register-Environment -Force:$Force }
        'Update'    { Update-Environment }
        'Uninstall' { Unregister-Environment }
        default     { Write-Log "Invalid mode selected." "ERROR"; exit 1 }
    }
} catch {
    Write-Log "Unhandled exception in main block: $_" "ERROR"
    Write-Log $($_.ScriptStackTrace) "ERROR"
    exit 1
}
