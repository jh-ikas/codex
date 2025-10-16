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

$script:DETECTION_PATTERNS = @{
    IDE_Executables = @(
        "devenv.exe", "Code.exe", "code.exe", "idea64.exe", "studio64.exe",
        "eclipse.exe", "pycharm64.exe", "webstorm64.exe", "rider64.exe", "clion64.exe"
    )
    Language_Executables = @(
        "java.exe", "javac.exe", "python.exe", "node.exe", "ruby.exe", "php.exe",
        "go.exe", "rustc.exe", "dotnet.exe", "gcc.exe", "g++.exe", "clang.exe"
    )
    Build_Executables = @(
        "mvn.cmd", "mvn.bat", "gradle.bat", "gradle.cmd", "ant.bat",
        "msbuild.exe", "make.exe", "cmake.exe", "ninja.exe"
    )
    VCS_Executables = @(
        "git.exe", "svn.exe", "hg.exe"
    )
    Database_Executables = @(
        "mysql.exe", "mysqld.exe", "psql.exe", "postgres.exe",
        "mongo.exe", "mongod.exe", "redis-server.exe", "sqlite3.exe"
    )
    Other_Executables = @(
        "docker.exe", "kubectl.exe", "terraform.exe", "vagrant.exe", "adb.exe", "anaconda.exe"
    )
}

$script:ENV_VAR_PATTERNS = @{
    "java.exe|javac.exe" = @{ VarName = "JAVA_HOME"; ParentLevel = 1; AddBinToPath = $true }
    "python.exe" = @{ VarName = "PYTHON_HOME"; ParentLevel = 0; AdditionalPaths = @("Scripts") }
    "node.exe" = @{ VarName = "NODE_HOME"; ParentLevel = 0; AddBinToPath = $true; CheckNpmGlobal = $true }
    "mvn.cmd|mvn.bat" = @{ VarName = "MAVEN_HOME"; ParentLevel = 1; AddBinToPath = $true }
    "gradle.bat|gradle.cmd" = @{ VarName = "GRADLE_HOME"; ParentLevel = 1; AddBinToPath = $true }
    "go.exe" = @{ VarName = "GOROOT"; ParentLevel = 1; AddBinToPath = $true }
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
            $normalized = $normalized.Replace('/', '\\').Trim('\')
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
        [string[]]$ExistingPaths
    )
    
    $normalizedNew = $NewPath.TrimEnd('\\').ToLower()
    
    foreach ($p in $PathList) { if ($p.TrimEnd('\\').ToLower() -eq $normalizedNew) { return $false } }
    foreach ($p in $ExistingPaths) { if ($p.TrimEnd('\\').ToLower() -eq $normalizedNew) { return $false } }
    
    $toRemove = @()
    foreach ($existing in $PathList) {
        $normalizedExisting = $existing.TrimEnd('\\').ToLower()
        if ($normalizedNew.StartsWith($normalizedExisting + '\\')) { return $false }
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
        
        Write-Log "Detecting npm global prefix..." "INFO"
        $npmPrefix = & $npmCmd config get prefix 2>$null
        
        if ($npmPrefix -and (Test-Path $npmPrefix)) {
            Write-Log "npm global prefix detected: $npmPrefix" "SUCCESS"
            return $npmPrefix
        } else {
            Write-Log "npm global prefix not configured or path does not exist" "WARN"
            return $null
        }
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

            $pathsToAdd = New-Object System.Collections.ArrayList
            $varsToSet = @{ 
                "OriginalPath" = $originalPath
                "DriveLetter" = $driveInfo.DriveLetter
                "SerialNumber" = $driveInfo.SerialNumber
                "Label" = $driveInfo.Label
            }
            
            $envVarsSet = @{}
            $toolStats = @{}

            foreach ($toolKey in $detectedTools.Keys) {
                $instances = $detectedTools[$toolKey]
                $instance = $instances[0]
                $category = $instance.Category
                
                if (-not $toolStats.ContainsKey($category)) { $toolStats[$category] = 0 }
                $toolStats[$category] += $instances.Count
                
                $exeDir = $instance.Directory
                $exeName = $instance.Name + $instance.ExecutablePath.Substring($instance.ExecutablePath.LastIndexOf('.'))
                
                $envConfig = Get-EnvironmentVarConfig -ExeName $exeName
                
                if ($envConfig -and $envConfig.VarName) {
                    if (-not $envVarsSet.ContainsKey($envConfig.VarName)) {
                        $varPath = $exeDir
                        for ($i = 0; $i -lt $envConfig.ParentLevel; $i++) { $varPath = Split-Path $varPath -Parent }
                        
                        Set-ItemProperty -Path $envRegPath -Name $envConfig.VarName -Value $varPath -ErrorAction Stop
                        
                        $varsToSet[$envConfig.VarName] = $varPath
                        $envVarsSet[$envConfig.VarName] = $varPath
                        Write-Log "Set $($envConfig.VarName) = $varPath" "SUCCESS"
                        
                        if ($envConfig.AddBinToPath) {
                            $binPath = Join-Path $varPath "bin"
                            if (Test-Path $binPath) {
                                Add-PathSafely -PathList $pathsToAdd -NewPath $binPath -ExistingPaths $originalPathArray | Out-Null
                            } else {
                                if (Test-Path $varPath) {
                                    Add-PathSafely -PathList $pathsToAdd -NewPath $varPath -ExistingPaths $originalPathArray | Out-Null
                                    Write-Log "Bin not found for $($envConfig.VarName). Added $varPath as fallback to PATH." "INFO"
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
                        
                        # Special: Node.js npm global path detection
                        if ($envConfig.CheckNpmGlobal) {
                            $npmGlobalPath = Get-NpmGlobalPath -NodeHomePath $varPath
                            if ($npmGlobalPath) {
                                if (Add-PathSafely -PathList $pathsToAdd -NewPath $npmGlobalPath -ExistingPaths $originalPathArray) {
                                    Write-Log "Added npm global path: $npmGlobalPath" "SUCCESS"
                                }
                            }
                        }
                    }
                }
                else {
                    Add-PathSafely -PathList $pathsToAdd -NewPath $exeDir -ExistingPaths $originalPathArray | Out-Null
                }
            }
            
            if ($pathsToAdd.Count -gt 0) {
                $newPath = (($pathsToAdd -join ';') + ";" + $originalPath).Trim(';')
                Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $newPath -ErrorAction Stop
                $varsToSet["AddedPaths"] = ($pathsToAdd -join ';')
            }

            Write-Log "=== Detection Summary ===" "SUCCESS"
            foreach ($cat in $toolStats.Keys | Sort-Object) { Write-Log "$cat : $($toolStats[$cat]) instances" "INFO" }
            Write-Log "HOME Variables Set: $($envVarsSet.Count)" "SUCCESS"
            Write-Log "PATH Entries Added: $($pathsToAdd.Count)" "SUCCESS"

            if (-not (Test-Path $script:REG_STATE_KEY)) { New-Item -Path $script:REG_STATE_KEY -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "DetectedToolsCount" -Value $detectedTools.Count -ErrorAction Stop
            foreach ($key in $varsToSet.Keys) {
                Set-ItemProperty -Path $script:REG_STATE_KEY -Name $key -Value $varsToSet[$key] -ErrorAction Stop
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

        $pathsToAdd = New-Object System.Collections.ArrayList
        $varsToUpdate = @{}
        $newToolsCount = 0

        foreach ($toolKey in $detectedTools.Keys) {
            $instance = $detectedTools[$toolKey][0]
            $exeName = $instance.Name + $instance.ExecutablePath.Substring($instance.ExecutablePath.LastIndexOf('.'))
            $exeDir = $instance.Directory
            
            $envConfig = Get-EnvironmentVarConfig -ExeName $exeName
            
            if ($envConfig -and $envConfig.VarName) {
                $varPath = $exeDir
                for ($i = 0; $i -lt $envConfig.ParentLevel; $i++) { $varPath = Split-Path $varPath -Parent }
                
                $currentVal = (Get-ItemProperty -Path $envRegPath -Name $envConfig.VarName -ErrorAction SilentlyContinue).($envConfig.VarName)
                
                if ($null -eq $currentVal -or $currentVal -ne $varPath) {
                    Set-ItemProperty -Path $envRegPath -Name $envConfig.VarName -Value $varPath -ErrorAction Stop
                    $varsToUpdate[$envConfig.VarName] = $varPath
                    Write-Log "[NEW] Set $($envConfig.VarName) = $varPath" "SUCCESS"
                    $newToolsCount++
                }
                
                $procPath = { param($p) 
                    if (Test-Path $p) {
                        if (Add-PathSafely -PathList $pathsToAdd -NewPath $p -ExistingPaths $currentPathArray) {
                            Write-Log "[NEW PATH] $p" "SUCCESS"
                            return 1
                        }
                    }
                    return 0
                }

                if ($envConfig.AddBinToPath) { 
                    $binPath = Join-Path $varPath "bin"
                    if (Test-Path $binPath) {
                        $newToolsCount += (& $procPath $binPath)
                    } else {
                        $newToolsCount += (& $procPath $varPath)
                    }
                }
                if ($envConfig.AdditionalPaths) { 
                    foreach ($ap in $envConfig.AdditionalPaths) { 
                        $newToolsCount += (& $procPath (Join-Path $varPath $ap)) 
                    } 
                }
                
                # Special: Node.js npm global path detection
                if ($envConfig.CheckNpmGlobal) {
                    $npmGlobalPath = Get-NpmGlobalPath -NodeHomePath $varPath
                    if ($npmGlobalPath) {
                        if (Add-PathSafely -PathList $pathsToAdd -NewPath $npmGlobalPath -ExistingPaths $currentPathArray) {
                            Write-Log "[NEW PATH] npm global: $npmGlobalPath" "SUCCESS"
                            $newToolsCount++
                        }
                    }
                }
            }
            else {
                if (Add-PathSafely -PathList $pathsToAdd -NewPath $exeDir -ExistingPaths $currentPathArray) {
                    Write-Log "[NEW PATH] $exeDir" "SUCCESS"
                    $newToolsCount++
                }
            }
        }
        
        if ($pathsToAdd.Count -gt 0) {
            $newPath = (($pathsToAdd -join ';') + ";" + $currentSystemPath).Trim(';')
            Set-ItemProperty -Path $envRegPath -Name "PATH" -Value $newPath -ErrorAction Stop
            
            $prevAdded = if ($state.AddedPaths) { $state.AddedPaths } else { "" }
            $combinedAdded = (($pathsToAdd -join ';') + ";" + $prevAdded).Trim(';')
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name "AddedPaths" -Value $combinedAdded -ErrorAction Stop
        }

        foreach ($key in $varsToUpdate.Keys) {
            Set-ItemProperty -Path $script:REG_STATE_KEY -Name $key -Value $varsToUpdate[$key] -ErrorAction Stop
        }
        Set-ItemProperty -Path $script:REG_STATE_KEY -Name "DetectedToolsCount" -Value $detectedTools.Count -ErrorAction Stop
        Set-ItemProperty -Path $script:REG_STATE_KEY -Name "LastScanTimestamp" -Value $scanTimestamp.ToString("o") -ErrorAction Stop

        if ($newToolsCount -gt 0) {
            if (Send-SettingChangeNotification) { 
                Write-Log "Update complete. Added $newToolsCount new configurations." "SUCCESS" 
            } else { Write-Log "Update complete (restart needed)." "SUCCESS" }
        } else {
            Write-Log "No new tools or paths to add." "INFO"
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
