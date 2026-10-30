@echo off
rem Build native Flutter and the separate CLI/MCP tools on Windows.
setlocal
cd /d "%~dp0"
set PY=.venv\Scripts\python.exe
if not exist "%PY%" (
    echo error: create .venv first: python -m venv .venv 1>&2
    exit /b 1
)
"%PY%" -m pip install -e ".[build]" -e ./mcp
if errorlevel 1 exit /b 1
"%PY%" packaging\build.py
if errorlevel 1 exit /b 1
