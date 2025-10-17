@echo off
chcp 65001 > nul
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT_PATH=%SCRIPT_DIR%portable.ps1"

:: PowerShell 스크립트 존재 확인
if not exist "%PS_SCRIPT_PATH%" (
    echo.
    echo [ERROR] portable.ps1 not found!
    echo Expected location: %PS_SCRIPT_PATH%
    echo.
    echo Please make sure portable.ps1 is in the same folder as this batch file.
    echo.
    pause
    goto :eof
)

:: 인자가 없으면 대화형 모드
if /i "%~1"=="" (
    title Portable Environment Manager
    echo.
    echo ================================================
    echo    Portable Environment Manager
    echo ================================================
    echo.
    echo  Select an option:
    echo.
    echo  [1] Install   - Register the portable environment
    echo  [2] Update    - Add newly installed programs (keep existing)
    echo  [3] Install (Force) - Force re-register everything
    echo  [4] Uninstall - Remove the portable environment
    echo  [5] Exit
    echo.
    echo ================================================
    echo.
    
    choice /C 12345 /N /M "Enter your choice (1-5): "
    set CHOICE_RESULT=%ERRORLEVEL%
    
    echo.
    
    if "%CHOICE_RESULT%"=="1" (
        set "MODE=Install"
        set "FORCE_SWITCH="
    ) else if "%CHOICE_RESULT%"=="2" (
        set "MODE=Update"
        set "FORCE_SWITCH="
    ) else if "%CHOICE_RESULT%"=="3" (
        set "MODE=Install"
        set "FORCE_SWITCH=-Force"
    ) else if "%CHOICE_RESULT%"=="4" (
        set "MODE=Uninstall"
        set "FORCE_SWITCH="
    ) else (
        echo Exiting...
        timeout /t 2 >nul
        goto :eof
    )
    
    echo [Portable ENV] Starting Mode: %MODE% %FORCE_SWITCH%
    echo.
    
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT_PATH%" -Mode %MODE% %FORCE_SWITCH% -EnableAutoCleanup
    
    set PS_EXIT_CODE=%ERRORLEVEL%
    
    echo.
    if %PS_EXIT_CODE% EQU 0 (
        echo ================================================
        echo  Operation completed successfully!
        echo ================================================
    ) else (
        echo ================================================
        echo  Operation failed with error code: %PS_EXIT_CODE%
        echo ================================================
        echo.
        echo Check the log file for details:
        echo %TEMP%\PortableT7_*.log
    )
    echo.
    pause
    goto :eof
)

:: 명령줄 인자가 있으면 기존 방식으로 실행
set "MODE=%~1"
set "FORCE_SWITCH="
if /i "%~2"=="-Force" set "FORCE_SWITCH=-Force"

echo [Portable ENV] Starting Mode: %MODE% %FORCE_SWITCH%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT_PATH%" -Mode %MODE% %FORCE_SWITCH%

set PS_EXIT_CODE=%ERRORLEVEL%
if %PS_EXIT_CODE% NEQ 0 (
    echo.
    echo [ERROR] Operation failed with error code: %PS_EXIT_CODE%
    echo Check log: %TEMP%\PortableT7_*.log
    pause
)

:eof
endlocal
