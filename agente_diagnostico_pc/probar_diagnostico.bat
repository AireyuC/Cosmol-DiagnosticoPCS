@echo off
chcp 65001 >nul
title Cosmol - Prueba de Diagnóstico de Equipo
color 0B

echo ===============================================================================
echo            COSMOL - DIAGNÓSTICO Y TELEMETRÍA DE EQUIPO (TEST EN VIVO)
echo ===============================================================================
echo.
echo [*] Extrayendo hardware, salud SMART, Prefetch y estado del antivirus...
echo [*] Por favor espera unos segundos...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%~dp0recolector.ps1' -TipoEvento 'manual'"

echo.
echo ===============================================================================
echo [*] Diagnóstico completado.
echo [*] Si la opción de debug está activa, se guardó 'ultimo_diagnostico.json'.
echo ===============================================================================
echo.
pause
