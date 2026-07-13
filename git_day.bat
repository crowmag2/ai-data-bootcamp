@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ===== Git Auto Upload =====
set /p num="D 뒤의 숫자 입력 (예: 5): "

set folder=D%num%

echo.
echo 폴더: %folder%
echo 맞나요? (Y/N)
set /p confirm=
if /i not "%confirm%"=="Y" (
    echo 취소됨.
    pause
    exit /b
)

echo.
git pull origin main
git add %folder%/
git commit -m "%folder%"
git push origin main

echo.
echo ===== 완료! =====
pause