@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ===== Git Feature Branch Upload =====
echo.

set /p branchSuffix="Branch suffix 입력 (예: d005-log-report): "
set /p folderName="Folder name 입력 (예: D005): "
set /p commitMsg="Commit message 입력 (예: 웹 로그 파싱 및 트래픽 리포트): "

set branchName=feat/%branchSuffix%

echo.
echo Branch: %branchName%
echo Folder: %folderName%
echo Commit: %commitMsg%
echo.
echo 맞나요? (Y/N)
set /p confirm=
if /i not "%confirm%"=="Y" (
    echo 취소됨.
    pause
    exit /b
)

echo.
git checkout -b %branchName%
git add %folderName%/
git commit -m "%commitMsg%"
git push origin %branchName%

echo.
echo ===== 완료! =====
pause