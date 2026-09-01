@echo off
setlocal

set "ROOT=%~dp0.."
set "BUILD=%ROOT%\build\luau"
set "LUau="
if exist "%BUILD%\Release\luau.exe" set "LUau=%BUILD%\Release\luau.exe"
if not defined LUau if exist "%BUILD%\luau.exe" set "LUau=%BUILD%\luau.exe"

if not defined LUau (
    echo Luau has not been built. Run tools\build-luau.bat first. 1>&2
    exit /b 2
)

"%LUau%" "%ROOT%\tests\luau_smoke.luau"
