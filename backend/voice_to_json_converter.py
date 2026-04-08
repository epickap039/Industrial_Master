"""Convertidor de transcripción de voz → JSON para Tbl_Gestor_Tareas.

Usa Whisper (faster-whisper) para transcripción en GPU (CUDA).
Mapea texto a campos de tarea siguiendo reglas de extracción de entidades.
"""

import json
import re
from typing import Any, Dict, Optional, Tuple

# Para transcripción de audio (opcional detectar si tenemos GPU)
try:
    from faster_whisper import WhisperModel
    WHISPER_AVAILABLE = True
except ImportError:
    WHISPER_AVAILABLE = False


# ============================================================================
# DICCIONARIOS DE PLANTA (NER - Named Entity Recognition)
# ============================================================================

AREAS_PLANTA = {
    "cnc": "CNC",
    "maquinado": "CNC",
    "torno": "CNC",
    "fresadora": "CNC",
    "ensamble": "Ensamble",
    "armado": "Ensamble",
    "montaje": "Ensamble",
    "almacén": "Almacén",
    "bodega": "Almacén",
    "prototipado": "Prototipado",
    "desarrollo": "Prototipado",
    "lab": "Prototipado",
    "laboratorio": "Prototipado",
}

PIEZAS_PLANTA = {
    "nema": "NEMA",
    "motor": "NEMA",
    "rodamiento": "Rodamientos",
    "bearing": "Rodamientos",
    "sensor": "Sensores ESP8266",
    "esp8266": "Sensores ESP8266",
    "plc": "PLC",
    "controlador": "PLC",
}

# Palabras clave para prioridades
PRIORIDAD_URGENTE = ["urgente", "crítico", "ya", "paro", "paro de línea", "crítica", "emerencia", "emergencia"]
PRIORIDAD_IMPORTANTE = ["importante", "pronto", "mañana", "para mañana", "luego", "dentro de poco"]

# Palabras clave para usuarios (reconocimiento de nombres comunes)
USUARIOS_CONOCIDOS = {
    "juan": "Juan",
    "pedro": "Pedro",
    "carlos": "Carlos",
    "maria": "María",
    "luis": "Luis",
    "javier": "Javier",
    "sergio": "Sergio",
    "ana": "Ana",
    "jorge": "Jorge",
    "manuel": "Manuel",
}


# ============================================================================
# FUNCIONES DE EXTRACCIÓN DE DATOS (NER)
# ============================================================================

def normalizar_texto(texto: str) -> str:
    """Normaliza texto para búsqueda (minúsculas, sin acentos básicos)."""
    return texto.lower().strip()


def extraer_prioridad(transcripcion: str) -> int:
    """
    Extrae prioridad (PriorityRank) de la transcripción.

    Retorna:
        0: Urgente/Crítico
        1: Importante/Pronto
        2: Por defecto
    """
    texto_norm = normalizar_texto(transcripcion)

    # Buscar palabras urgentes
    for palabra in PRIORIDAD_URGENTE:
        if palabra in texto_norm:
            return 0

    # Buscar palabras importantes
    for palabra in PRIORIDAD_IMPORTANTE:
        if palabra in texto_norm:
            return 1

    return 2  # Por defecto


def extraer_usuario(transcripcion: str) -> str:
    """
    Extrae nombre de usuario asignado.

    Busca patrones como "para Juan", "asignado a Maria", "responsable Pedro".
    También busca nombres del diccionario en contexto.
    Retorna nombre si lo encuentra, sino "PENDIENTE".
    """
    texto_norm = normalizar_texto(transcripcion)

    # Patrones explícitos de asignación
    patrones = [
        r"para\s+(\w+)",
        r"asignado\s+a(?:\s|l)?\s+(\w+)",
        r"responsable\s+(\w+)",
        r"a\s+(\w+)\s+le",
    ]

    for patron in patrones:
        match = re.search(patron, texto_norm)
        if match:
            nombre_encontrado = match.group(1).lower()
            # Evitar palabras comunes que no son nombres
            palabras_evitar = ["mañana", "luego", "tiempo", "momento", "urgente",
                               "rápido", "lento", "importante", "análisis", "completo",
                               "revisión", "revisar", "dentro", "hoy", "ayer", "hecho",
                               "largo", "corto", "simple", "difícil"]

            if nombre_encontrado not in palabras_evitar:
                # Intentar hacer match con usuarios conocidos
                if nombre_encontrado in USUARIOS_CONOCIDOS:
                    return USUARIOS_CONOCIDOS[nombre_encontrado]
                # Si es un nombre potencial, retornar
                if len(nombre_encontrado) >= 3:
                    return nombre_encontrado.capitalize()

    # Búsqueda adicional: nombres conocidos en cualquier contexto
    # (úseful para "Necesito que Juan calibre...")
    for alias, nombre_oficial in USUARIOS_CONOCIDOS.items():
        if f" {alias} " in f" {texto_norm} ":  # Buscar con límites de palabra
            return nombre_oficial

    return "PENDIENTE"


def extraer_area(transcripcion: str) -> Optional[str]:
    """Extrae área de planta mencionada."""
    texto_norm = normalizar_texto(transcripcion)

    for clave, area in AREAS_PLANTA.items():
        if clave in texto_norm:
            return area

    return None


def extraer_pieza(transcripcion: str) -> Optional[str]:
    """Extrae pieza/componente mencionado."""
    texto_norm = normalizar_texto(transcripcion)

    for clave, pieza in PIEZAS_PLANTA.items():
        if clave in texto_norm:
            return pieza

    return None


def calcular_minutos_estimados(transcripcion: str, complejidad_base: int = 30) -> int:
    """
    Calcula minutos estimados según complejidad percibida.

    Heurística simple:
    - Base: 30 minutos
    - Si menciona urgencia o "rápido": -50%
    - Si menciona "complejo", "difícil", "revisión": +50%
    - Si menciona cantidad o múltiples items: +25-50%
    """
    texto_norm = normalizar_texto(transcripcion)
    minutos = complejidad_base

    # Reducir por urgencia/rapidez
    palabras_rapido = ["rápido", "rapido", "urgente", "ya", "pronto"]
    if any(palabra in texto_norm for palabra in palabras_rapido):
        minutos = int(minutos * 0.5)

    # Aumentar por complejidad
    palabras_complejo = ["complejo", "compleja", "difícil", "dificil", "revisión", "revision", "análisis", "analisis"]
    if any(palabra in texto_norm for palabra in palabras_complejo):
        minutos = int(minutos * 1.5)

    # Aumentar si menciona múltiples cosas
    cantidad_matches = len(re.findall(r"\sy\s|\,\s|\;", texto_norm))
    if cantidad_matches >= 2:
        minutos = int(minutos * 1.25)

    return max(5, minutos)  # Mínimo 5 minutos


def generar_titulo_tecnico(transcripcion: str, area: Optional[str] = None, pieza: Optional[str] = None) -> str:
    """
    Genera un título técnico corto (máx 50 caracteres).

    Intenta extraer sustantivos clave de la transcripción o usar área/pieza.
    """
    texto_norm = normalizar_texto(transcripcion)

    # Limitar palabras válidas (filtrar artículos, preposiciones)
    articulos = {"el", "la", "de", "del", "en", "para", "con", "sin", "por", "está", "son", "es"}
    palabras = [p for p in texto_norm.split() if p not in articulos and len(p) > 3]

    # Construir título con prioridad: pieza + área o primeras palabras
    titulo_partes = []

    if pieza:
        titulo_partes.append(pieza)
    if area:
        titulo_partes.append(area)

    # Agregar hasta 2 palabras adicionales si hay espacio
    for palabra in palabras[:2]:
        if len(" ".join(titulo_partes + [palabra])) <= 50:
            titulo_partes.append(palabra.capitalize())

    titulo = " ".join(titulo_partes)

    if not titulo:
        titulo = "Tarea Manual"

    return titulo[:50]  # Máximo 50 caracteres


# ============================================================================
# TRANSCRIPTOR DE VOZ (WHISPER)
# ============================================================================

_WHISPER_MODEL = None  # Singleton para evitar cargar modelo múltiples veces


def inicializar_whisper_gpu() -> bool:
    """
    Inicializa Whisper con GPU o CPU como fallback.

    Re-intenta el import en cada llamada para que funcione aunque faster-whisper
    haya sido instalado despues de arrancar el servidor.
    Retorna True si fue exitoso, False si hay error.
    """
    global _WHISPER_MODEL, WHISPER_AVAILABLE

    # Si ya esta inicializado, reutilizar
    if _WHISPER_MODEL is not None:
        return True

    # Re-intentar import por si fue instalado despues del arranque
    if not WHISPER_AVAILABLE:
        try:
            from faster_whisper import WhisperModel as _WM  # noqa: F401
            WHISPER_AVAILABLE = True
        except ImportError:
            print("[WARN] faster-whisper no está instalado. Solo soporta transcripción de texto.")
            return False

    try:
        # Preferir GPU (CUDA) para RTX; si no hay CUDA, caer a CPU
        _WHISPER_MODEL = WhisperModel(
            "large-v3",
            device="cuda",
            compute_type="float16"
        )
        print("[OK] Whisper inicializado con GPU (CUDA, float16)")
        return True
    except Exception as e:
        print(f"[WARN] GPU no disponible: {e}. Usando CPU como fallback.")
        try:
            _WHISPER_MODEL = WhisperModel("base", device="cpu", compute_type="int8")
            print("[OK] Whisper inicializado con CPU (int8)")
            return True
        except Exception as e2:
            print(f"[ERROR] No se pudo inicializar Whisper: {e2}")
            return False


def transcribir_audio(ruta_archivo: str, idioma: str = "es") -> Optional[str]:
    """
    Transcribe archivo de audio a texto usando Whisper.

    Parámetros:
        ruta_archivo: Ruta al archivo .mp3, .wav, .m4a, etc.
        idioma: Código ISO del idioma (ej: "es", "en")

    Retorna:
        Texto transcrito o None si hay error.
    """
    if _WHISPER_MODEL is None:
        if not inicializar_whisper_gpu():
            print("[WARN] Whisper no está disponible. Necesitas instalar faster-whisper.")
            return None

    try:
        segments, info = _WHISPER_MODEL.transcribe(
            ruta_archivo,
            beam_size=5,
            language=idioma,
            condition_on_previous_text=False
        )

        # Unir segmentos
        transcripcion = " ".join([seg.text for seg in segments])
        return transcripcion.strip()

    except Exception as e:
        print(f"[ERROR] Error transcribiendo {ruta_archivo}: {e}")
        return None


# ============================================================================
# CONVERTIDOR PRINCIPAL: TRANSCRIPCIÓN → JSON
# ============================================================================

def convertir_transcripcion_a_json(
    transcripcion: str,
    minutos_base: int = 30,
    incluir_metadata: bool = True,
) -> Dict[str, Any]:
    """
    Convierte transcripción de voz a JSON para inserción en Tbl_Gestor_Tareas.

    Parámetros:
        transcripcion: Texto de la transcripción (ej: salida de Whisper)
        minutos_base: Minutos estimados base para cálculos
        incluir_metadata: Si True, agrega metadata técnica

    Retorna:
        Dict con estructura JSON lista para inserción en BD

    Ejemplo:
        >>> transcripcion = "Revisar los rodamientos del CNC para mañana, debe ser rápido"
        >>> json_tarea = convertir_transcripcion_a_json(transcripcion)
        >>> print(json_tarea["titulo"])
        "Rodamientos CNC"
    """
    if not transcripcion or not isinstance(transcripcion, str):
        raise ValueError("La transcripción debe ser un string no vacío")

    # Extrae entidades
    prioridad = extraer_prioridad(transcripcion)
    usuario = extraer_usuario(transcripcion)
    area = extraer_area(transcripcion)
    pieza = extraer_pieza(transcripcion)
    minutos = calcular_minutos_estimados(transcripcion, minutos_base)
    titulo = generar_titulo_tecnico(transcripcion, area, pieza)

    # Construir descripción desde transcripción
    descripcion = transcripcion.strip()

    # JSON de salida
    resultado: Dict[str, Any] = {
        "titulo": titulo,
        "descripcion": descripcion,
        "usuario_asignado": usuario,
        "minutos_estimados": minutos,
        "priority_rank": prioridad,
        "tipo_tarea": "MANUAL",
        "source_type": "VOZ_LOCAL",
    }

    # Meta JSON con metadata adicional
    meta_dict = {
        "transcripcion_original": transcripcion,
        "area_detectada": area,
        "pieza_detectada": pieza,
        "complejidad_estimada": "ALTA" if prioridad == 0 else "MEDIA" if prioridad == 1 else "BAJA",
    }

    if incluir_metadata:
        meta_dict["procesado_en_timestamp"] = _get_timestamp_iso()
        meta_dict["version_converter"] = "1.0"

    # Serializar meta_json como string JSON
    resultado["meta_json"] = json.dumps(meta_dict, ensure_ascii=False, indent=2)

    return resultado


def _get_timestamp_iso() -> str:
    """Retorna timestamp ISO 8601 actual."""
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


# ============================================================================
# UTILIDADES ADICIONALES
# ============================================================================

def validar_json_tarea(json_tarea: Dict[str, Any]) -> Tuple[bool, str]:
    """
    Valida que el JSON de tarea cumpla con requisitos mínimos.

    Retorna:
        (bool: válido, str: mensaje de error si no es válido)
    """
    campos_requeridos = [
        "titulo", "descripcion", "usuario_asignado",
        "minutos_estimados", "priority_rank", "tipo_tarea", "source_type"
    ]

    for campo in campos_requeridos:
        if campo not in json_tarea or json_tarea[campo] is None:
            return False, f"Campo faltante o nulo: {campo}"

    # Validaciones de tipo/rango
    if not isinstance(json_tarea["titulo"], str) or len(json_tarea["titulo"]) > 50:
        return False, "Título debe ser string <= 50 caracteres"

    if not isinstance(json_tarea["minutos_estimados"], int) or json_tarea["minutos_estimados"] < 0:
        return False, "Minutos estimados debe ser int >= 0"

    if json_tarea["priority_rank"] not in [0, 1, 2]:
        return False, "Priority rank debe ser 0, 1 o 2"

    if json_tarea["tipo_tarea"] != "MANUAL":
        return False, "Tipo tarea debe ser MANUAL"

    if json_tarea["source_type"] != "VOZ_LOCAL":
        return False, "Source type debe ser VOZ_LOCAL"

    return True, ""


if __name__ == "__main__":
    # TEST: Prueba local sin API
    test_casos = [
        "Revisar los rodamientos del CNC para mañana, debe ser rápido",
        "Urgente: paro de línea en ensamble, revisar sensores ESP8266",
        "Necesito que Juan calibre los NEMA en el laboratorio",
        "Análisis completo de prototipado, va a tomar tiempo",
    ]

    print("=" * 70)
    print("TESTS: Conversión Transcripción -> JSON")
    print("=" * 70)

    for i, transcripcion in enumerate(test_casos, 1):
        print(f"\n[TEST {i}] Transcripción:")
        print(f"  '{transcripcion}'")

        try:
            resultado = convertir_transcripcion_a_json(transcripcion)
            valido, error = validar_json_tarea(resultado)

            print(f"\n  JSON Generado:")
            print(f"    Título: {resultado['titulo']}")
            print(f"    Usuario: {resultado['usuario_asignado']}")
            print(f"    Minutos: {resultado['minutos_estimados']}")
            print(f"    Prioridad: {resultado['priority_rank']}")
            print(f"    Válido: {'OK' if valido else 'ERROR - ' + error}")

        except Exception as e:
            print(f"  ERROR: {e}")

    print("\n" + "=" * 70)
