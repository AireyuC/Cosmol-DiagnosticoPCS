# AGENTS.md: Módulo de Agente y Script de Diagnóstico PC (Cosmol)

Este documento define la arquitectura, normas operativas, diseño técnico y contexto general para cualquier agente de inteligencia artificial o desarrollador que trabaje en el repositorio **Cosmol-DiagnosticoP**.

---

## 1. Propósito del Proyecto y Repositorio

El propósito de este repositorio es desarrollar, mantener y empaquetar el **Agente Colector de Telemetría y Diagnóstico de PCs** para los equipos del personal administrativo y operativo de **Cosmol**.

El agente funciona como un cliente ligero, silencioso y desatendido que audita el estado físico y lógico de las computadoras con Windows, generando un payload en formato JSON que es enviado periódicamente al servidor central (`Formulario_Registro`).

---

## 2. Componentes del Repositorio

```
Cosmol-DiagnosticoP/
├── AGENTS.md                          # Este archivo: reglas de contexto y lineamientos para agentes
│
└── agente_diagnostico_pc/             # El cliente independiente para las PCs de los usuarios
    ├── config.json                    # Configuración: URL de la API del servidor, frecuencia y timeout
    ├── recolector.ps1                 # Núcleo extractor de hardware, SMART, Prefetch y Defender
    ├── enviar_reporte.ps1             # Disparador de red: ejecuta recolector y envía HTTP POST
    ├── probar_diagnostico.bat         # Utilidad de prueba para el técnico en consola
    ├── instalar_tarea.bat             # Instalador silencioso de 1 clic (Tarea programada SYSTEM)
    └── desinstalar_tarea.bat          # Script de remoción limpia de la tarea
```

> **Nota de Centralización:** La base de datos (tablas `historial_diagnosticos`, vistas y esquemas) se administra exclusivamente en el servidor central dentro de `Formulario_Registro/database/diagnostico.sql`. Este repositorio contiene única y exclusivamente el cliente ligero para las PCs de los usuarios.

---

## 3. Principios de Arquitectura del Agente

### 3.1. Cero Falsos Positivos de Antivirus
* **Regla estricta:** No se compilan ejecutables utilizando librerías empaquetadoras genéricas como `PyInstaller`, `auto-py-to-exe` o wrappers no firmados, debido a que los motores heurísticos de Windows Defender suelen marcarlos erróneamente como troyanos.
* **Solución nativa:** El agente cliente de PC utiliza **PowerShell 5.1+ nativo de Windows**, ejecutado a través de una Tarea Programada de Windows (`schtasks`) bajo la cuenta del sistema local (`NT AUTHORITY\SYSTEM`).
* **Alcance Exclusivo:** Este requisito de PowerShell nativo aplica **única y exclusivamente a este cliente recolector de Windows**. No aplica a la plataforma central `Formulario_Registro`, donde se utiliza libremente el stack web completo (PHP, Apache, Docker, JavaScript, SQL) y cualquier herramienta óptima de desarrollo.

### 3.2. Cero Interrupción al Usuario
* No debe desplegarse ninguna ventana de consola negra, mensaje emergente ni diálogo que interrumpa al usuario mientras trabaja.
* La ejecución se realiza en segundo plano completo con parámetros:
  ```powershell
  powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "enviar_reporte.ps1"
  ```
* El consumo de CPU debe mantenerse por debajo del 1% y tomar entre 1 y 3 segundos como máximo por ejecución.

### 3.3. Estructura de Telemetría (JSON Contract)

El script `recolector.ps1` debe retornar obligatoriamente un objeto JSON con las siguientes secciones:

```json
{
  "metadatos": {
    "direccion_mac": "B4:2E:99:A1:B2:C3",
    "hostname": "ADM-CONTAB-01",
    "usuario_windows": "COSMOL\\carlos.mendoza",
    "ip_local": "192.168.11.45",
    "tipo_evento": "programado",
    "timestamp": "2026-10-12T16:00:00Z"
  },
  "resumen_salud": {
    "estado_salud_general": "optimo",
    "uso_cpu_porcentaje": 18.5,
    "temperatura_cpu": 45.0,
    "uso_ram_porcentaje": 62.4,
    "espacio_libre_c_gb": 85.3,
    "salud_disco_smart": "OK",
    "antivirus_activo": true,
    "amenazas_activas": 0
  },
  "hardware": {
    "cpu": { 
      "modelo": "Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz", 
      "nucleos": 6, 
      "hilos": 12, 
      "carga_porcentaje": 18.5, 
      "temperatura_c": 45.0, 
      "estado": "optimo", 
      "alerta": null 
    },
    "ram": { 
      "total_gb": 16.0, 
      "usado_gb": 9.98, 
      "libre_gb": 6.02, 
      "uso_porcentaje": 62.4, 
      "ranuras_usadas": 2, 
      "velocidad_mhz": 2666, 
      "estado": "optimo", 
      "alerta": null 
    },
    "almacenamiento": [
      { 
        "unidad": "C:", 
        "modelo": "KINGSTON SA400S37480G", 
        "tamano_gb": 447.1, 
        "libre_gb": 85.3, 
        "libre_porcentaje": 19.1, 
        "smart_status": "OK", 
        "estado": "bueno", 
        "alerta": null 
      }
    ],
    "placa_madre": { "fabricante": "ASUSTeK COMPUTER INC.", "modelo": "PRIME H410M-E", "serial": "20067182910" },
    "red": { 
      "adaptador": "Realtek PCIe GbE Family Controller", 
      "mac": "B4:2E:99:A1:B2:C3", 
      "ip": "192.168.11.45", 
      "gateway": "192.168.11.1", 
      "estado": "optimo", 
      "alerta": null 
    }
  },
  "software_y_seguridad": {
    "antivirus": { 
      "nombre": "Windows Defender", 
      "proteccion_tiempo_real": true, 
      "firmas_actualizadas": true, 
      "ultima_definicion": "2026-10-12", 
      "amenazas_activas": 0, 
      "estado": "optimo", 
      "alerta": null 
    },
    "apps_recientes_prefetch": [
      { "ejecutable": "EXCEL.EXE", "ultima_ejecucion": "2026-10-12 15:30:12", "tamano_kb": 35.2, "fuente": "Prefetch" },
      { "ejecutable": "CHROME.EXE", "ultima_ejecucion": "2026-10-12 15:45:00", "tamano_kb": 42.1, "fuente": "Prefetch" }
    ],
    "descargas_recientes": [
      { "archivo": "Reporte_Trimestral.xlsx", "tamano_kb": 320, "fecha": "2026-10-12 11:20:00", "riesgo_potencial": false }
    ],
    "alertas_detectadas": []
  }
}
```

---

## 4. Fuentes de Datos en Windows (Cómo se extraen)

1. **Hardware (CPU, RAM, Placa Madre):**
   * `Get-CimInstance -ClassName Win32_Processor`
   * `Get-CimInstance -ClassName Win32_PhysicalMemory`
   * `Get-CimInstance -ClassName Win32_BaseBoard`
2. **Almacenamiento y Salud SMART:**
   * `Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"`
   * `Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus` (predicción de fallos SMART).
3. **Red e Identificación (Dirección MAC):**
   * `Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=TRUE"`
4. **Seguridad y Antivirus:**
   * `Get-MpComputerStatus` (Windows Defender API)
5. **Auditoría Forense Ligera:**
   * **Últimas Apps:** Lectura de metadatos de archivos `.pf` en `C:\Windows\Prefetch` ordenados por `LastWriteTime`.
   * **Descargas:** Inspección de archivos recientes en `$env:USERPROFILE\Downloads`.

---

## 5. Reglas para Futuras Modificaciones por Agentes

1. **No tocar la interfaz gráfica del proyecto central:** El repositorio de interfaz (`Formulario_Registro`) está en pausa coordinada con el desarrollador encargado. La documentación respectiva vive en `D:\Formulario_Registro\Docs\diagnostico_pc\`.
2. **Tolerancia a Fallos:** Toda llamada a WMI/CIM o lectura de carpetas debe estar encapsulada en bloques `try { ... } catch { ... }` para evitar que un fallo en un sensor detenga el reporte del resto del equipo.
3. **Mantener UTF-8 sin BOM:** Todos los scripts `.ps1`, `.bat` y `.json` deben guardarse con codificación UTF-8 limpia para compatibilidad plena con el backend PHP y PostgreSQL.
