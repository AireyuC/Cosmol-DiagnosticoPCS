<#
================================================================================
SCRIPT: enviar_reporte.ps1
PROPÓSITO: Ejecuta la telemetría y envía el JSON vía HTTP POST al servidor central
COMPATIBILIDAD: Windows 10/11 - PowerShell 5.1+
================================================================================
#>

[CmdletBinding()]
param (
    [string]$TipoEvento = "programado"
)

$DirectorioScript = $PSScriptRoot
$RutaConfig = Join-Path $DirectorioScript "config.json"
$RutaRecolector = Join-Path $DirectorioScript "recolector.ps1"

# Cargar configuración
$UrlApi = "http://192.168.11.70:83/api/diagnostico/recibir.php"
$TimeoutSegundos = 15
$ReintentosMax = 2

if (Test-Path $RutaConfig) {
    try {
        $Config = Get-Content -Path $RutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Config.servidor.url_api) { $UrlApi = $Config.servidor.url_api }
        if ($Config.servidor.timeout_segundos) { $TimeoutSegundos = [int]$Config.servidor.timeout_segundos }
        if ($Config.servidor.reintentos_maximos) { $ReintentosMax = [int]$Config.servidor.reintentos_maximos }
    } catch {
        # Mantener valores predeterminados
    }
}

# 1. Ejecutar el recolector para obtener el JSON
if (-not (Test-Path $RutaRecolector)) {
    exit 1
}

$PayloadJson = & "$RutaRecolector" -TipoEvento $TipoEvento -RutaConfig $RutaConfig

if ([string]::IsNullOrWhiteSpace($PayloadJson)) {
    exit 1
}

# 2. Enviar por HTTP POST con reintentos
$Enviado = $false
$Intento = 0

while (-not $Enviado -and $Intento -lt $ReintentosMax) {
    $Intento++
    try {
        # Configurar TLS 1.2 por compatibilidad de red institucional
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

        $Respuesta = Invoke-RestMethod -Uri $UrlApi `
                                       -Method Post `
                                       -Body $PayloadJson `
                                       -ContentType "application/json; charset=utf-8" `
                                       -TimeoutSec $TimeoutSegundos `
                                       -ErrorAction Stop

        $Enviado = $true
    } catch {
        # Esperar 3 segundos antes del siguiente reintento en caso de corte transitorio de red
        Start-Sleep -Seconds 3
    }
}

if ($Enviado) {
    exit 0
} else {
    # Salida silenciosa si la red del servidor no responde para no molestar al usuario
    exit 2
}
