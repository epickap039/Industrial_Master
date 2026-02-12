import os
import shutil
import sys

def create_installer():
    # 1. Rutas
    VERSION = "11.0_ENTERPRISE"
    SOURCE_BIN = r"build\windows\x64\runner\Release"
    SOURCE_SCRIPTS = r"scripts"
    DEST_DIR = f"INSTALADOR_JAES_v{VERSION}"
    
    # 2. Limpieza y Creación de Carpeta Destino
    print(f"🧹 Limpiando {DEST_DIR}...")
    if os.path.exists(DEST_DIR):
        shutil.rmtree(DEST_DIR)
    os.makedirs(DEST_DIR, exist_ok=True)
    print(f"✅ Carpeta creada: {DEST_DIR}")

    # 3. Copiar Ejecutables de Flutter
    print("📦 Copiando ejecutables de Flutter y DLLs...")
    for item in os.listdir(SOURCE_BIN):
        s = os.path.join(SOURCE_BIN, item)
        d = os.path.join(DEST_DIR, item)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)

    # 4. Copiar Backend (data_bridge.exe)
    print("🐍 Configurando Backend Portátil (EXE)...")
    
    # Crear carpeta scripts en destino
    dest_scripts_dir = os.path.join(DEST_DIR, "scripts")
    os.makedirs(dest_scripts_dir, exist_ok=True)

    backend_exe = os.path.join(SOURCE_SCRIPTS, "data_bridge.exe")
    
    if os.path.exists(backend_exe):
        # Copia 1: En carpeta scripts (Estándar)
        shutil.copy2(backend_exe, os.path.join(dest_scripts_dir, "data_bridge.exe"))
        print("   - data_bridge.exe copiado a /scripts/ (Estándar).")
        
        # Copia 2: En raíz (Fallback)
        shutil.copy2(backend_exe, os.path.join(DEST_DIR, "data_bridge.exe"))
        print("   - data_bridge.exe copiado a RAÍZ (Fallback).")
    else:
        print("❌ ERROR CRÍTICO: No se encontró data_bridge.exe en scripts/")
        print("   Ejecute: pyinstaller scripts/data_bridge.py --onefile")
        return

    # 5. Copiar Recursos Adicionales
    # A) Copiar config.json
    config_src = os.path.join(SOURCE_SCRIPTS, "config.json")
    if os.path.exists(config_src):
        shutil.copy2(config_src, os.path.join(dest_scripts_dir, "config.json"))
        print("   - config.json copiado a /scripts/.")
        # También copiar config a raíz por si acaso
        shutil.copy2(config_src, os.path.join(DEST_DIR, "config.json"))
        print("   - config.json copiado a RAÍZ.")
    else:
        print("⚠️ Advertencia: No se encontró config.json en scripts/.")
        
    # B) Copiar diagnose.exe si existe (opcional)
    diagnose_exe = os.path.join(SOURCE_SCRIPTS, "diagnose.exe")
    if os.path.exists(diagnose_exe):
        shutil.copy2(diagnose_exe, os.path.join(dest_scripts_dir, "diagnose.exe"))
        print("   - diagnose.exe copiado a /scripts/.")
    
    # C) Copiar debug_sql_log.txt si existe
    log_src = "debug_sql_log.txt"
    if os.path.exists(log_src):
        shutil.copy(log_src, DEST_DIR)
        print("   - debug_sql_log.txt copiado.")

    # 5. Manual y Dependencias Extra
    # Copy Manual.pdf if exists
    if os.path.exists("Manual.pdf"):
        shutil.copy("Manual.pdf", DEST_DIR)
        print("✅ Manual copiado.")
        
    # Check for ODBC Driver installer
    odbc_msi = "msodbcsql.msi"
    if os.path.exists(odbc_msi):
        shutil.copy(odbc_msi, DEST_DIR)
        print("✅ Instalador ODBC copiado.")
    else:
        print("⚠️ Advertencia: No se encontró msodbcsql.msi en la raíz.")

    print(f"\n✨ ÉXITO: Instalador FINAL v{VERSION} listo en {os.path.abspath(DEST_DIR)}")
    print("🚀 La aplicación funcionará en clientes SIN Python instalado.")

if __name__ == "__main__":
    create_installer()
