@echo off
setlocal

set "ROOT=%~dp0.."
set "SOURCE=%ROOT%\vendor\Luau"
set "BUILD=%ROOT%\build\luau"

if not exist "%SOURCE%\CMakeLists.txt" (
    echo Luau submodule is missing. Run: git submodule update --init --recursive 1>&2
    exit /b 2
)

set "CMAKE=cmake"
where cmake >nul 2>nul
if errorlevel 1 if exist "%ProgramFiles%\CMake\bin\cmake.exe" set "CMAKE=%ProgramFiles%\CMake\bin\cmake.exe"
if "%CMAKE%"=="cmake" goto :cmake_missing
goto :cmake_ready

:cmake_missing
    echo CMake is required to build the pinned Luau tools. 1>&2
    exit /b 2

:cmake_ready

"%CMAKE%" -S "%SOURCE%" -B "%BUILD%" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DLUAU_BUILD_CLI=ON -DLUAU_BUILD_TESTS=ON
if errorlevel 1 exit /b %errorlevel%
"%CMAKE%" --build "%BUILD%" --config Release --parallel 2
if errorlevel 1 exit /b %errorlevel%

echo Luau tools built under "%BUILD%".
exit /b 0
