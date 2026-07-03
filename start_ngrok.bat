@echo off
echo =========================================
echo  Biznet Sync - Public URL via ngrok
echo =========================================
echo.

REM Cek apakah ngrok.exe sudah ada di folder ini
if not exist "%~dp0ngrok.exe" (
    echo [INFO] ngrok belum ada, mendownload...
    powershell -Command "Invoke-WebRequest -Uri 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip' -OutFile '%~dp0ngrok.zip'"
    powershell -Command "Expand-Archive -Path '%~dp0ngrok.zip' -DestinationPath '%~dp0' -Force"
    del "%~dp0ngrok.zip" 2>nul
    echo [OK] ngrok berhasil didownload.
    echo.
)

REM Cek apakah authtoken sudah disimpan
"%~dp0ngrok.exe" config check >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [SETUP] Authtoken ngrok belum dikonfigurasi.
    echo.
    echo Buka: https://dashboard.ngrok.com/get-started/your-authtoken
    echo Salin token kamu, lalu paste di bawah ini:
    echo.
    set /p NGROK_TOKEN="Masukkan authtoken ngrok: "
    "%~dp0ngrok.exe" config add-authtoken %NGROK_TOKEN%
    echo.
    echo [OK] Authtoken berhasil disimpan!
    echo.
)

echo [INFO] Pastikan start_server.bat sudah berjalan di window lain!
echo.
echo [INFO] Memulai tunnel ngrok ke localhost:3001...
echo.
echo =============================================
echo  Setelah muncul URL https://xxxx.ngrok-free.app
echo  Salin URL itu dan paste sebagai Embed di Notion
echo =============================================
echo.

"%~dp0ngrok.exe" http 3001

echo.
echo [INFO] ngrok dihentikan.
pause
