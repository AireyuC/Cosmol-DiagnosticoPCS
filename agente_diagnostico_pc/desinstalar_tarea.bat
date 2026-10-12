@echo off
chcp 65001 >nul
title Desinstalador del Agente de Diagnóstico Cosmol
color 0C

:: Verificación de permisos de Administrador
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Este desinstalador requiere privilegios de Administrador.
    echo [*] Solicitando elevación de UAC...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo ===============================================================================
echo            DESINSTALADOR DEL AGENTE DE DIAGNÓSTICO PC - COSMOL
echo ===============================================================================
echo.

set "DESTINO=C:\ProgramData\CosmolAgente"
set "NOMBRE_TAREA=Cosmol_Diagnostico_PC"

echo [1/2] Eliminando la Tarea Programada de Windows '%NOMBRE_TAREA%'...
schtasks /Delete /TN "%NOMBRE_TAREA%" /F >nul 2>&1
if %errorlevel% equ 0 (
    echo       - Tarea eliminada correctamente.
) else (
    echo       - La tarea no estaba registrada o ya fue eliminada.
)

echo [2/2] Eliminando archivos instalados en %DESTINO%...
if exist "%DESTINO%" (
    rmdir /S /Q "%DESTINO%"
    echo       - Archivos eliminados.
) else (
    echo       - El directorio ya no existe.
)

echo.
echo ===============================================================================
echo [OK] Agente desinstalado limpiamente del equipo.
echo ===============================================================================
echo.
pause
