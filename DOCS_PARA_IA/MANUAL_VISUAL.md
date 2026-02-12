# 🏭 INDUSTRIAL MASTER - GUÍA DE INICIO RÁPIDO

Bienvenido al ecosistema **INTEGRITY SUITE v6.1**. Siga estos pasos para configurar su estación de trabajo en menos de 2 minutos.

---

## 🚦 Pre-Requisitos (Semáforo de Instalación)

| Estado | Acción Requerida |
| :--- | :--- |
| 🔴 **OBLIGATORIO** | **Instalar Driver ODBC 17:** [Descargar aquí (Microsoft)](https://www.microsoft.com/en-us/download/details.aspx?id=56567). Sin esto, no hay conexión. |
| 🟡 **IMPORTANTE** | **Red Local:** Asegúrese de estar conectado a la red de la empresa (Vía Cable o VPN). |
| 🟢 **LISTO** | **Despliegue:** Copie la carpeta `Release` completa a su Escritorio y ejecute `industrial_manager.exe`. |

---

## 🛡️ Conexión al Servidor Central (Paso a Paso)

Al iniciar por primera vez, o si la conexión falla, la App le llevará automáticamente a la pantalla de **Configuración de Servidor**.

### Configuración Sugerida para Ingeniería

> **Nota:** El servidor principal de la base de datos es el equipo **PC08**.

1. **Dirección del Servidor:** Escriba ➡️ `PC08\SQLEXPRESS`
    * *Tip:* Si no funciona, intente con la IP fija del servidor.
2. **Base de Datos:** Déjelo como está ➡️ `DB_Materiales_Industrial`
3. **Autenticación:**
    * ✅ **Windows Auth (Switch ACTIVADO):** Si su usuario de Windows tiene permisos en el servidor. (Recomendado).
    * ❌ **SQL Auth (Switch DESACTIVADO):** Si está en una PC de otra área. Pida su *Usuario* y *Contraseña* al administrador de base de datos.

---

## ⌨️ Uso de la Interfaz

* **Pulsar "Probar Conexión":** Antes de guardar, verifique que aparezca el check verde ✅ de éxito.
* **Pulsar "Guardar":** Esto reiniciará la conexión y le llevará a la pantalla principal (**JAES**).

---

## 🛠️ Solución de Problemas (Troubleshooting)

**¿La pantalla se queda cargando eternamente?**

* Verifique que el servidor **PC08** esté encendido y conectado a la red.
* Asegúrese de que el Driver ODBC 17 esté instalado.

**¿Ves una pantalla roja de error?**

* Haga clic en el icono del engrane ⚙️ en el menú lateral y revise que el nombre del servidor sea exactamente `PC08\SQLEXPRESS`.

---

*© 2026 JAES - Departamento de Ingeniería Industrial*
