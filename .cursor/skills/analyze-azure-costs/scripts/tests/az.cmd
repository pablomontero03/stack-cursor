@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0az-stub.ps1" %*
exit /b %ERRORLEVEL%
