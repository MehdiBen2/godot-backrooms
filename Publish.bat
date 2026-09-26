@echo off
rem Double-click to open the one-click publisher window.
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\publish_gui.ps1"
