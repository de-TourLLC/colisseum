@echo off
setlocal
set "ROOT=%~dp0.."
set "BINARY=%ROOT%\build\luau\Release\luau-compile.exe"
if not exist "%BINARY%" set "BINARY=%ROOT%\build\luau\luau-compile.exe"
if not exist "%BINARY%" (
    call "%ROOT%\tools\build-luau.bat"
    set "BUILD_STATUS=%ERRORLEVEL%"
    if not "%BUILD_STATUS%"=="0" exit /b %BUILD_STATUS%
)
"%BINARY%" %*
