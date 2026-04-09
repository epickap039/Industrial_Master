#!/usr/bin/env python3
"""
Script de prueba para verificar que crear_tarea_manual guarda minutos_estimados correctamente
"""

import json
import requests
import pyodbc

# Configuración
API_URL = "http://localhost:8001"
DB_SERVER = "192.168.1.73"
DB_NAME = "DB_Materiales_Industrial"

def get_available_driver():
    """Obtiene el driver SQL Server disponible"""
    available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
    return available_drivers[0] if available_drivers else None

def test_create_mission_with_time():
    """Prueba creando una misión manual con tiempo estimado"""

    # Datos de prueba
    test_payload = {
        "titulo": "PRUEBA_TIEMPO_ESTIMADO_" + str(int(__import__('time').time())),
        "descripcion": "Misión de prueba para verificar que se guarda el tiempo estimado",
        "responsable": "DESARROLLADOR",  # Debe ser un usuario válido
        "categoria": "INGENIERIA",
        "minutos_estimados": 120,  # 2 hora
        "sin_tiempo_estimado": False,
        "checklist": []
    }

    print(">>> Creando misión de prueba con 120 minutos estimados...")
    print(f"Payload: {json.dumps(test_payload, indent=2)}")

    try:
        # Hacer POST al endpoint
        headers = {
            "Content-Type": "application/json",
            "X-Usuario": "TEST_USER"
        }
        response = requests.post(
            f"{API_URL}/api/tareas/crear_manual",
            json=test_payload,
            headers=headers,
            timeout=10
        )

        print(f"\nRespuesta del servidor: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            task_id = data.get("id_tarea") or data.get("id") or "desconocido"
            print(f"✓ Misión creada con ID: {task_id}\n")
            return task_id
        else:
            print(f"✗ Error: {response.text}")
            return None

    except Exception as e:
        print(f"✗ Error al conectar con el servidor: {e}")
        print("¿Está el servidor ejecutándose en http://localhost:8001?")
        return None

def verify_in_database(task_id):
    """Verifica que el tiempo se guardó en la base de datos"""

    driver = get_available_driver()
    if not driver:
        print("ERROR: No se encontró ODBC Driver para SQL Server")
        return False

    try:
        conn = pyodbc.connect(
            f'Driver={driver};'
            f'Server={DB_SERVER};'
            f'Database={DB_NAME};'
            f'Trusted_Connection=yes;'
        )
        cursor = conn.cursor()

        print(f">>> Buscando la tarea {task_id} en la base de datos...")

        # Consultar la tarea
        cursor.execute("""
            SELECT TOP 1
                ID_Tarea,
                Duracion_Minutos,
                Tiempo_Total_Estimado,
                Titulo_Cambio,
                Meta_JSON
            FROM Tbl_Gestor_Tareas
            WHERE ID_Tarea = ?
            ORDER BY ID_Tarea DESC
        """, (task_id,))

        row = cursor.fetchone()
        if row:
            id_tarea, duracion, tiempo_total, titulo, meta_json = row
            print(f"✓ Tarea encontrada:")
            print(f"  ID: {id_tarea}")
            print(f"  Duracion_Minutos: {duracion}")
            print(f"  Tiempo_Total_Estimado: {tiempo_total}")
            print(f"  Titulo_Cambio: {titulo}")

            if meta_json:
                try:
                    meta = json.loads(meta_json)
                    print(f"  Meta JSON: {json.dumps(meta, indent=4, ensure_ascii=False)}")
                except:
                    print(f"  Meta JSON (raw): {meta_json}")

            # Verificar si el tiempo se guardó
            if duracion == 120 or tiempo_total == 120:
                print("\n✓✓✓ ¡ÉXITO! El tiempo estimado se guardó correctamente en la base de datos")
                return True
            else:
                print(f"\n✗ PROBLEMA: Se esperaba 120 minutos pero se guardó: {duracion or tiempo_total}")
                return False
        else:
            print(f"✗ Tarea {task_id} NO encontrada en la base de datos")
            return False

        cursor.close()
        conn.close()

    except Exception as e:
        print(f"✗ Error al consultar la base de datos: {e}")
        import traceback
        traceback.print_exc()
        return False

def main():
    print("=" * 70)
    print("PRUEBA: Verificar que los minutos estimados se guardan correctamente")
    print("=" * 70 + "\n")

    # Crear misión
    task_id = test_create_mission_with_time()

    if task_id and task_id != "desconocido":
        # Esperar un momento
        import time
        time.sleep(1)

        # Verificar en base de datos
        verify_in_database(task_id)
    else:
        print("\n✗ No se pudo crear la misión de prueba")

if __name__ == '__main__':
    main()
