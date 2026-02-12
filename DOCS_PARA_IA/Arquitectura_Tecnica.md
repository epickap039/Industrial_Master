# 🏗️ ARQUITECTURA TÉCNICA - INDUSTRIAL MASTER v6.1

Este documento detalla la infraestructura de software para facilitar el mantenimiento y escalabilidad futura.

## 🌉 El Puente Flutter-Python (Data Bridge)

El sistema utiliza una arquitectura híbrida donde Flutter gestiona la **Experiencia de Usuario (UX)** y Python gestiona la **Lógica de Datos y SQL**.

### Diagrama de Flujo de Datos

`Usuario (UI)` ➡️ `Acción (Click)` ➡️ `Dart (DatabaseHelper)` ➡️ `config.json` ➡️ `Python Script` ➡️ `SQL Server (PC08)`

## ⚙️ Gestión de Configuración FAIL-SAFE

Para habilitar el soporte Cliente-Servidor sin modificar código, se implementó un sistema de configuración externa:

1. **Persistencia:** La App escribe parámetros en `scripts/config.json`.
2. **Modularidad:** Tanto `data_bridge.py` como `carga_inicial.py` importan la función `load_config()`, garantizando que todos los procesos apunten al mismo servidor simultáneamente.
3. **Fail-Safe:** Al arrancar, `main.dart` ejecuta un "Health Check" vía `test_connection.py`. Si el JSON es inválido o el servidor está caído, la App intercepta el error y redirige a la pantalla de configuración en lugar de colapsar.

## 📂 Estructura de Scripts (Backend)

* `data_bridge.py`: El "middleware" principal. Todo lo que Flutter lee/escribe pasa por aquí. Ahora lee parámetros vía STDIN (Base64) para evitar límites de longitud.
* `test_connection.py`: Script ligero de diagnóstico (Python + SQLAlchemy).
* `carga_inicial.py`: Procesador masivo de archivos Excel con lógica de detección de encabezados inteligente.

## 🔐 Seguridad y Conectividad

* **Autenticación:** Soporta `Trusted_Connection=yes` (Windows) y `UID/PWD` (SQL Auth).
* **PC08:** Nombre de host por defecto para el servidor central de Ingeniería.

---
*Documentación técnica actualizada el 2026-02-06.*
