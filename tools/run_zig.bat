@echo off
setlocal

REM 1. Check if 'zig' is available in system PATH
where zig >nul 2>&1
if not errorlevel 1 (
    zig %*
    exit /b %ERRORLEVEL%
)

REM 2. Locate project root directory
set "SCRIPT_DIR=%~dp0"
for %%i in ("%SCRIPT_DIR%..") do set "ROOT_DIR=%%~fi"
set "LOCAL_ZIG=%ROOT_DIR%\.zig\zig-x86_64-windows-0.17.1\zig.exe"

REM 3. Check if already downloaded in project root .zig folder
if exist "%LOCAL_ZIG%" (
    "%LOCAL_ZIG%" %*
    exit /b %ERRORLEVEL%
)

REM 4. Auto-download Zig 0.17.1 for Windows x86_64
set "ZIG_URL=https://ziglang.org/download/0.17.1/zig-x86_64-windows-0.17.1.zip"
set "ZIP_FILE=%ROOT_DIR%\.zig\zig-windows-0.17.1.zip"

echo ======================================================================
echo [Zig Bootstrap] 'zig' was not found in PATH or in %LOCAL_ZIG%
echo [Zig Bootstrap] Downloading Zig 0.17.1 for Windows x86_64...
echo [Zig Bootstrap] URL: %ZIG_URL%
echo ======================================================================

if not exist "%ROOT_DIR%\.zig" mkdir "%ROOT_DIR%\.zig"

REM Try curl first (standard on Windows 10/11) to display a live progress bar
set "DOWNLOADED=0"
where curl >nul 2>&1
if not errorlevel 1 echo [Zig Bootstrap] Downloading via curl...
if not errorlevel 1 curl -# -fSL "%ZIG_URL%" -o "%ZIP_FILE%"
if not errorlevel 1 if exist "%ZIP_FILE%" set "DOWNLOADED=1"

if "%DOWNLOADED%"=="0" (
    echo [Zig Bootstrap] Downloading via PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%download_zig.ps1" -Url "%ZIG_URL%" -OutFile "%ZIP_FILE%"
)

if not exist "%ZIP_FILE%" (
    echo [Zig Bootstrap] ERROR: Download failed! %ZIP_FILE% not found.
    exit /b 1
)

echo [Zig Bootstrap] Extracting archive - please wait...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%ZIP_FILE%' -DestinationPath '%ROOT_DIR%\.zig' -Force; Remove-Item -Path '%ZIP_FILE%' -Force"

if not exist "%LOCAL_ZIG%" (
    echo [Zig Bootstrap] ERROR: Extraction completed but %LOCAL_ZIG% was not found!
    exit /b 1
)

echo [Zig Bootstrap] Extraction complete.
echo [Zig Bootstrap] Zig 0.17.1 ready at: %LOCAL_ZIG%
echo ======================================================================

"%LOCAL_ZIG%" %*
exit /b %ERRORLEVEL%
