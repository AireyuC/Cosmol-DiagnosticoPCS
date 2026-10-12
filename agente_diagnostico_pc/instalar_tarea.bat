@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Instalador del Agente de Diagnóstico Cosmol
color 0A

:: -----------------------------------------------------------------------------
:: Verificación de permisos de Administrador
:: -----------------------------------------------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Este instalador requiere privilegios de Administrador.
    echo [*] Solicitando elevación de UAC...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo ===============================================================================
echo             INSTALADOR DEL AGENTE DE DIAGNÓSTICO PC - COSMOL
echo ===============================================================================
echo.

set "DESTINO=C:\ProgramData\CosmolAgente"
set "NOMBRE_TAREA=Cosmol_Diagnostico_PC"

echo [1/4] Creando directorio permanente en %DESTINO%...
if not exist "%DESTINO%" mkdir "%DESTINO%"

echo [2/4] Copiando scripts y archivos de configuración...
copy /Y "%~dp0config.json" "%DESTINO%\config.json" >nul
copy /Y "%~dp0recolector.ps1" "%DESTINO%\recolector.ps1" >nul
copy /Y "%~dp0enviar_reporte.ps1" "%DESTINO%\enviar_reporte.ps1" >nul

echo [3/4] Eliminando tarea programada previa (si existiese)...
schtasks /Delete /TN "%NOMBRE_TAREA%" /F >nul 2>&1

echo [4/4] Registrando nueva Tarea Programada de Windows...
echo       - Usuario ejecutor: NT AUTHORITY\SYSTEM (Segundo plano 100%% silencioso)
echo       - Frecuencia: Cada 2 horas durante la jornada laboral
echo.

set "ACCION=powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%DESTINO%\enviar_reporte.ps1\" -TipoEvento programado"

schtasks /Create /TN "%NOMBRE_TAREA%" /TR "%ACCION%" /SC HOURLY /MO 2 /RU "NT AUTHORITY\SYSTEM" /RL HIGHEST /F

if %errorlevel% equ 0 (
    echo.
    echo ===============================================================================
    echo [OK] Agente instalado y programado exitosamente.
    echo [*] La tarea '%NOMBRE_TAREA%' se ejecutará silenciosamente en segundo plano.
    echo ===============================================================================
) else (
    echo.
    echo [X] Hubo un inconveniente al registrar la tarea programada.
)

echo.
pause
