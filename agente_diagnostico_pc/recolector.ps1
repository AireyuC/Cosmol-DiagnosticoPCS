<#
================================================================================
SCRIPT: recolector.ps1
PROPÓSITO: Extracción nativa de telemetría de hardware, SMART, Prefetch y Defender
COMPATIBILIDAD: Windows 10/11 - PowerShell 5.1+
AUTOR: Cosmol - Soporte y Diagnóstico TI
================================================================================
#>

[CmdletBinding()]
param (
    [string]$TipoEvento = "programado",
    [string]$RutaConfig = "$PSScriptRoot\config.json"
)

# Configuración por defecto en caso de ausencia de config.json
$MaxPrefetch = 15
$MaxDescargas = 10
$DiasDescargas = 7
$UmbralDiscoCriticoGB = 10
$UmbralDiscoAdvGB = 25
$UmbralRamAdvPct = 88

if (Test-Path -Path $RutaConfig) {
    try {
        $ConfigRaw = Get-Content -Path $RutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ConfigRaw.politica_auditoria) {
            $MaxPrefetch = [int]$ConfigRaw.politica_auditoria.max_apps_prefetch
            $MaxDescargas = [int]$ConfigRaw.politica_auditoria.max_descargas_recientes
            $DiasDescargas = [int]$ConfigRaw.politica_auditoria.dias_descargas_recientes
            $UmbralDiscoCriticoGB = [double]$ConfigRaw.politica_auditoria.umbral_disco_critico_gb
            $UmbralDiscoAdvGB = [double]$ConfigRaw.politica_auditoria.umbral_disco_advertencia_gb
            $UmbralRamAdvPct = [double]$ConfigRaw.politica_auditoria.umbral_ram_advertencia_pct
        }
    } catch {
        # Continúa con valores predeterminados
    }
}

$AlertasDetectadas = [System.Collections.Generic.List[string]]::new()

# ------------------------------------------------------------------------------
# 1. METADATOS Y RED
# ------------------------------------------------------------------------------
$Hostname = $env:COMPUTERNAME
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Obtener usuario activo real en sesión
$UsuarioSesion = ""
try {
    $CompSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($CompSystem -and $CompSystem.UserName) {
        $UsuarioSesion = $CompSystem.UserName
    } else {
        $UsuarioSesion = "$env:USERDOMAIN\$env:USERNAME"
    }
} catch {
    $UsuarioSesion = "$env:USERDOMAIN\$env:USERNAME"
}

# Red: Adaptador activo con IP
$MacPrincipal = "00:00:00:00:00:00"
$IpPrincipal = "127.0.0.1"
$GatewayPrincipal = ""
$AdaptadorNombre = ""
$DnsPrincipal = @()

try {
    $Adaptadores = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE" -ErrorAction SilentlyContinue
    $AdaptadorActivo = $Adaptadores | Where-Object { $_.DefaultIPGateway -ne $null } | Select-Object -First 1
    if (-not $AdaptadorActivo -and $Adaptadores) {
        $AdaptadorActivo = $Adaptadores | Select-Object -First 1
    }

    if ($AdaptadorActivo) {
        $MacPrincipal = $AdaptadorActivo.MACAddress
        $IpPrincipal = ($AdaptadorActivo.IPAddress | Select-Object -First 1)
        if ($AdaptadorActivo.DefaultIPGateway) {
            $GatewayPrincipal = ($AdaptadorActivo.DefaultIPGateway | Select-Object -First 1)
        }
        $AdaptadorNombre = $AdaptadorActivo.Description
        if ($AdaptadorActivo.DNSServerSearchOrder) {
            $DnsPrincipal = @($AdaptadorActivo.DNSServerSearchOrder)
        }
    }
} catch {
    $AlertasDetectadas.Add("No se pudo obtener información completa de red: $($_.Exception.Message)")
}

# ------------------------------------------------------------------------------
# 2. HARDWARE: CPU, RAM Y PLACA MADRE
# ------------------------------------------------------------------------------
$CpuModelo = "Desconocido"
$CpuNucleos = 1
$CpuHilos = 1
$CpuCarga = 0.0

try {
    $Cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Cpu) {
        $CpuModelo = ($Cpu.Name -replace '\s+', ' ').Trim()
        $CpuNucleos = [int]$Cpu.NumberOfCores
        $CpuHilos = [int]$Cpu.NumberOfLogicalProcessors
        if ($Cpu.LoadPercentage -ne $null) {
            $CpuCarga = [double]$Cpu.LoadPercentage
        }
    }
} catch {
    $AlertasDetectadas.Add("Fallo en sensor de procesador: $($_.Exception.Message)")
}

# Temperatura de CPU (si el sensor ACPI está expuesto)
$TemperaturaCpu = $null
try {
    $Thermal = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Thermal -and $Thermal.CurrentTemperature) {
        $TempCelsius = ($Thermal.CurrentTemperature - 2732) / 10.0
        if ($TempCelsius -gt 0 -and $TempCelsius -lt 120) {
            $TemperaturaCpu = [math]::Round($TempCelsius, 1)
        }
    }
} catch {
    # La mayoría de PCs de escritorio no exponen ACPI térmico a WMI básico sin drivers dedicados
}

# Evaluación de estado individual de la CPU
$EstadoCpu = "optimo"
$AlertaCpu = $null
if (($TemperaturaCpu -ne $null -and $TemperaturaCpu -ge 85) -or $CpuCarga -ge 95) {
    $EstadoCpu = "critico"
    $AlertaCpu = "Carga o temperatura crítica en CPU ($CpuCarga% carga, ${TemperaturaCpu}°C)"
    $AlertasDetectadas.Add($AlertaCpu)
} elseif (($TemperaturaCpu -ne $null -and $TemperaturaCpu -ge 75) -or $CpuCarga -ge 85) {
    $EstadoCpu = "advertencia"
    $AlertaCpu = "Carga o temperatura elevada en CPU ($CpuCarga% carga, ${TemperaturaCpu}°C)"
    $AlertasDetectadas.Add($AlertaCpu)
} elseif ($CpuCarga -ge 65) {
    $EstadoCpu = "bueno"
}

# RAM
$RamTotalGB = 0.0
$RamUsadaGB = 0.0
$RamLibreGB = 0.0
$RamUsoPct = 0.0
$RamRanurasUsadas = 0
$RamVelocidadMHz = 0

try {
    $ModulosRam = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($ModulosRam) {
        $RamRanurasUsadas = ($ModulosRam | Measure-Object).Count
        $CapacidadTotalBytes = ($ModulosRam | Measure-Object -Property Capacity -Sum).Sum
        $RamTotalGB = [math]::Round($CapacidadTotalBytes / 1GB, 2)
        $PrimerModulo = $ModulosRam | Select-Object -First 1
        if ($PrimerModulo.Speed) {
            $RamVelocidadMHz = [int]$PrimerModulo.Speed
        }
    }

    $SO = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($SO) {
        $MemTotalKB = [double]$SO.TotalVisibleMemorySize
        $MemLibreKB = [double]$SO.FreePhysicalMemory
        $MemUsadaKB = $MemTotalKB - $MemLibreKB
        $RamUsadaGB = [math]::Round($MemUsadaKB / 1MB, 2)
        $RamLibreGB = [math]::Round($MemLibreKB / 1MB, 2)
        if ($MemTotalKB -gt 0) {
            $RamUsoPct = [math]::Round(($MemUsadaKB / $MemTotalKB) * 100, 1)
        }
    }
} catch {
    $AlertasDetectadas.Add("Fallo al medir consumo de memoria RAM: $($_.Exception.Message)")
}

# Evaluación de estado individual de la RAM
$EstadoRam = "optimo"
$AlertaRam = $null
if ($RamUsoPct -ge 95 -or ($RamLibreGB -gt 0 -and $RamLibreGB -lt 0.5)) {
    $EstadoRam = "critico"
    $AlertaRam = "Memoria RAM saturada: $RamUsoPct% en uso ($RamLibreGB GB libres)"
    $AlertasDetectadas.Add($AlertaRam)
} elseif ($RamUsoPct -ge $UmbralRamAdvPct) {
    $EstadoRam = "advertencia"
    $AlertaRam = "Consumo elevado de memoria RAM: $RamUsoPct% en uso"
    $AlertasDetectadas.Add($AlertaRam)
} elseif ($RamUsoPct -ge 70) {
    $EstadoRam = "bueno"
}

# Placa Madre
$PlacaFabricante = "Desconocido"
$PlacaModelo = "Desconocido"
$PlacaSerial = "Desconocido"
try {
    $Board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Board) {
        $PlacaFabricante = $Board.Manufacturer
        $PlacaModelo = $Board.Product
        $PlacaSerial = $Board.SerialNumber
    }
} catch {}

# ------------------------------------------------------------------------------
# 3. ALMACENAMIENTO Y SALUD SMART (EVALUACIÓN POR UNIDAD)
# ------------------------------------------------------------------------------
$ListaDiscos = [System.Collections.Generic.List[PSObject]]::new()
$EspacioLibreC = 0.0
$SmartGlobal = "OK"

try {
    # Predicción SMART
    $FalloSmart = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
    if ($FalloSmart) {
        foreach ($f in $FalloSmart) {
            if ($f.PredictFailure -eq $true) {
                $SmartGlobal = "FALLA_PREDICHA"
                $AlertasDetectadas.Add("ALERTA CRÍTICA: Sensor SMART predice fallo inminente en unidad de disco físico")
            }
        }
    }

    # Modelos de discos físicos
    $DiscosFisicos = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue

    # Particiones lógicas
    $DiscosLogicos = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    foreach ($d in $DiscosLogicos) {
        $TamanoGB = [math]::Round($d.Size / 1GB, 1)
        $LibreGB = [math]::Round($d.FreeSpace / 1GB, 1)
        $PctLibre = if ($TamanoGB -gt 0) { [math]::Round(($LibreGB / $TamanoGB) * 100, 1) } else { 0 }
        
        # Evaluación de salud individual de ESTA unidad de disco
        $EstadoUnidad = "optimo"
        $AlertaUnidad = $null

        if ($SmartGlobal -eq "FALLA_PREDICHA") {
            $EstadoUnidad = "critico"
            $AlertaUnidad = "Falla física predicha por sensor SMART"
        } elseif ($LibreGB -lt $UmbralDiscoCriticoGB -or $PctLibre -lt 5.0) {
            $EstadoUnidad = "critico"
            $AlertaUnidad = "Espacio crítico: solo $LibreGB GB libres ($PctLibre%)"
            $AlertasDetectadas.Add("ALERTA CRÍTICA [$($d.DeviceID)]: $AlertaUnidad")
        } elseif ($LibreGB -lt $UmbralDiscoAdvGB -or $PctLibre -lt 12.0) {
            $EstadoUnidad = "advertencia"
            $AlertaUnidad = "Espacio bajo: $LibreGB GB libres ($PctLibre%)"
            $AlertasDetectadas.Add("ADVERTENCIA [$($d.DeviceID)]: $AlertaUnidad")
        } elseif ($PctLibre -lt 25.0) {
            $EstadoUnidad = "bueno"
        }

        if ($d.DeviceID -eq "C:") {
            $EspacioLibreC = $LibreGB
        }

        # Asociar modelo físico si es posible
        $ModeloFisico = "Disco Local"
        if ($DiscosFisicos) {
            $ModeloFisico = ($DiscosFisicos | Select-Object -First 1).Model
        }

        $ListaDiscos.Add([PSCustomObject]@{
            unidad           = $d.DeviceID
            modelo           = $ModeloFisico
            tamano_gb        = $TamanoGB
            libre_gb         = $LibreGB
            libre_porcentaje = $PctLibre
            smart_status     = $SmartGlobal
            estado           = $EstadoUnidad
            alerta           = $AlertaUnidad
        })
    }
} catch {
    $AlertasDetectadas.Add("Error al auditar discos y SMART: $($_.Exception.Message)")
}

# ------------------------------------------------------------------------------
# 4. SEGURIDAD: WINDOWS DEFENDER Y AMENAZAS
# ------------------------------------------------------------------------------
$AntivirusNombre = "Windows Defender"
$ProteccionTiempoReal = $false
$FirmasActualizadas = $false
$FechaFirmas = ""
$AmenazasActivas = 0

try {
    $MpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($MpStatus) {
        $ProteccionTiempoReal = [bool]$MpStatus.RealTimeProtectionEnabled
        $FirmasActualizadas = ($MpStatus.AntivirusSignatureAge -le 7)
        if ($MpStatus.AntivirusSignatureLastUpdated) {
            $FechaFirmas = $MpStatus.AntivirusSignatureLastUpdated.ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    $Threats = Get-MpThreatDetection -ErrorAction SilentlyContinue
    if ($Threats) {
        $Recientes = $Threats | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-3) }
        $AmenazasActivas = ($Recientes | Measure-Object).Count
    }
} catch {
    # Antivirus de terceros o permisos
}

# Evaluación individual del Antivirus
$EstadoAv = "optimo"
$AlertaAv = $null

if ($AmenazasActivas -gt 0) {
    $EstadoAv = "critico"
    $AlertaAv = "Se detectaron $AmenazasActivas amenazas de seguridad en el equipo"
    $AlertasDetectadas.Add("ALERTA CRÍTICA: $AlertaAv")
} elseif (-not $ProteccionTiempoReal) {
    $EstadoAv = "critico"
    $AlertaAv = "La protección en tiempo real está desactivada"
    $AlertasDetectadas.Add("ALERTA CRÍTICA: $AlertaAv")
} elseif (-not $FirmasActualizadas) {
    $EstadoAv = "advertencia"
    $AlertaAv = "Las firmas de antivirus tienen más de 7 días sin actualizar"
    $AlertasDetectadas.Add("ADVERTENCIA: $AlertaAv")
}

# Evaluación de red individual
$EstadoRed = "optimo"
$AlertaRed = $null
if ([string]::IsNullOrWhiteSpace($GatewayPrincipal) -or $IpPrincipal.StartsWith("169.254")) {
    $EstadoRed = "advertencia"
    $AlertaRed = "Conectividad de red limitada (sin puerta de enlace o IP APIPA)"
    $AlertasDetectadas.Add("ADVERTENCIA DE RED: $AlertaRed")
}

# ------------------------------------------------------------------------------
# 5. AUDITORÍA FORENSE: APPS RECIENTES Y DESCARGAS
# ------------------------------------------------------------------------------
$AppsPrefetch = [System.Collections.Generic.List[PSObject]]::new()
try {
    # 5.1 Intentar lectura de Prefetch (requiere elevación o SYSTEM)
    $RutaPrefetch = "C:\Windows\Prefetch"
    if (Test-Path -Path $RutaPrefetch) {
        $ArchivosPf = Get-ChildItem -Path "$RutaPrefetch\*.pf" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $MaxPrefetch

        foreach ($pf in $ArchivosPf) {
            $NombreLimpio = ($pf.Name -replace '-[A-F0-9]{8}\.pf$', '') -replace '\.pf$', ''
            $AppsPrefetch.Add([PSCustomObject]@{
                ejecutable        = $NombreLimpio
                ultima_ejecucion  = $pf.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                tamano_kb         = [math]::Round($pf.Length / 1KB, 1)
                fuente            = "Prefetch"
            })
        }
    }

    # 5.2 Fallback si Prefetch está restringido (ej. prueba como usuario estándar)
    if ($AppsPrefetch.Count -eq 0) {
        $RutaRecent = "$env:APPDATA\Microsoft\Windows\Recent"
        if (Test-Path $RutaRecent) {
            $RecientesLnk = Get-ChildItem -Path "$RutaRecent\*.lnk" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First $MaxPrefetch

            foreach ($lnk in $RecientesLnk) {
                $NombreLimpio = $lnk.BaseName
                $AppsPrefetch.Add([PSCustomObject]@{
                    ejecutable        = $NombreLimpio
                    ultima_ejecucion  = $lnk.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                    tamano_kb         = [math]::Round($lnk.Length / 1KB, 1)
                    fuente            = "UserRecent"
                })
            }
        }
    }
} catch {
    # Manejo silencioso tolerante a fallos
}

# Descargas recientes del usuario
$DescargasRecientes = [System.Collections.Generic.List[PSObject]]::new()
try {
    $ExtensionesRiesgo = @(".exe", ".bat", ".cmd", ".vbs", ".ps1", ".iso", ".scr", ".msi", ".jar", ".js", ".apk")
    $RutasDescargas = @()
    
    if (Test-Path "$env:USERPROFILE\Downloads") {
        $RutasDescargas += "$env:USERPROFILE\Downloads"
    }
    
    # En caso de ejecutarse bajo SYSTEM, recorrer carpetas Downloads de usuarios reales
    $Perfiles = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }
    
    foreach ($p in $Perfiles) {
        $DPath = Join-Path $p.FullName "Downloads"
        if ((Test-Path $DPath) -and ($RutasDescargas -notcontains $DPath)) {
            $RutasDescargas += $DPath
        }
    }

    $ArchivosDescargados = @()
    foreach ($rd in $RutasDescargas) {
        $Encontrados = Get-ChildItem -Path $rd -File -ErrorAction SilentlyContinue
        if ($Encontrados) { $ArchivosDescargados += $Encontrados }
    }

    $DescargasOrdenadas = $ArchivosDescargados | 
        Sort-Object LastWriteTime -Descending | 
        Select-Object -First $MaxDescargas

    foreach ($f in $DescargasOrdenadas) {
        $EsRiesgo = $ExtensionesRiesgo -contains $f.Extension.ToLower()
        $DescargasRecientes.Add([PSCustomObject]@{
            archivo          = $f.Name
            tamano_kb        = [math]::Round($f.Length / 1KB, 1)
            fecha            = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
            riesgo_potencial = $EsRiesgo
        })
        if ($EsRiesgo) {
            $AlertasDetectadas.Add("Descarga de archivo ejecutable/instalador detectada: $($f.Name)")
        }
    }
} catch {}

# ------------------------------------------------------------------------------
# 6. EVALUACIÓN DEL ESTADO DE SALUD GENERAL (COMBINADA)
# ------------------------------------------------------------------------------
$TodosLosEstados = @($EstadoCpu, $EstadoRam, $EstadoAv, $EstadoRed)
foreach ($disco in $ListaDiscos) {
    if ($disco.estado) { $TodosLosEstados += $disco.estado }
}

$EstadoSalud = "optimo"
if ($TodosLosEstados -contains "critico") {
    $EstadoSalud = "critico"
} elseif ($TodosLosEstados -contains "advertencia") {
    $EstadoSalud = "advertencia"
} elseif ($TodosLosEstados -contains "bueno") {
    $EstadoSalud = "bueno"
}

# ------------------------------------------------------------------------------
# 7. CONSTRUCCIÓN DEL PAYLOAD FINAL
# ------------------------------------------------------------------------------
$Reporte = [PSCustomObject]@{
    metadatos = [PSCustomObject]@{
        direccion_mac    = $MacPrincipal
        hostname         = $Hostname
        usuario_windows  = $UsuarioSesion
        ip_local         = $IpPrincipal
        tipo_evento      = $TipoEvento
        timestamp        = $Timestamp
    }
    resumen_salud = [PSCustomObject]@{
        estado_salud_general = $EstadoSalud
        uso_cpu_porcentaje   = $CpuCarga
        temperatura_cpu      = $TemperaturaCpu
        uso_ram_porcentaje   = $RamUsoPct
        espacio_libre_c_gb   = $EspacioLibreC
        salud_disco_smart    = $SmartGlobal
        antivirus_activo     = $ProteccionTiempoReal
        amenazas_activas     = $AmenazasActivas
    }
    hardware = [PSCustomObject]@{
        cpu = [PSCustomObject]@{
            modelo           = $CpuModelo
            nucleos          = $CpuNucleos
            hilos            = $CpuHilos
            carga_porcentaje = $CpuCarga
            temperatura_c    = $TemperaturaCpu
            estado           = $EstadoCpu
            alerta           = $AlertaCpu
        }
        ram = [PSCustomObject]@{
            total_gb         = $RamTotalGB
            usado_gb         = $RamUsadaGB
            libre_gb         = $RamLibreGB
            uso_porcentaje   = $RamUsoPct
            ranuras_usadas   = $RamRanurasUsadas
            velocidad_mhz    = $RamVelocidadMHz
            estado           = $EstadoRam
            alerta           = $AlertaRam
        }
        almacenamiento = $ListaDiscos
        placa_madre = [PSCustomObject]@{
            fabricante       = $PlacaFabricante
            modelo           = $PlacaModelo
            serial           = $PlacaSerial
        }
        red = [PSCustomObject]@{
            adaptador        = $AdaptadorNombre
            mac              = $MacPrincipal
            ip               = $IpPrincipal
            gateway          = $GatewayPrincipal
            dns              = $DnsPrincipal
            estado           = $EstadoRed
            alerta           = $AlertaRed
        }
    }
    software_y_seguridad = [PSCustomObject]@{
        antivirus = [PSCustomObject]@{
            nombre                 = $AntivirusNombre
            proteccion_tiempo_real = $ProteccionTiempoReal
            firmas_actualizadas    = $FirmasActualizadas
            ultima_definicion      = $FechaFirmas
            amenazas_activas       = $AmenazasActivas
            estado                 = $EstadoAv
            alerta                 = $AlertaAv
        }
        apps_recientes_prefetch = $AppsPrefetch
        descargas_recientes     = $DescargasRecientes
        alertas_detectadas      = $AlertasDetectadas
    }
}

# Convertir a JSON
$JsonOutput = $Reporte | ConvertTo-Json -Depth 6

# Guardar copia local si está habilitado en config
if ($ConfigRaw -and $ConfigRaw.debug -and $ConfigRaw.debug.guardar_ultimo_json_local) {
    try {
        $RutaGuardado = Join-Path $PSScriptRoot $ConfigRaw.debug.ruta_json_local
        $JsonOutput | Set-Content -Path $RutaGuardado -Encoding UTF8 -Force
    } catch {}
}

return $JsonOutput
