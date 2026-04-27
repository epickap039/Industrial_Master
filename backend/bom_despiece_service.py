"""
Contrato de exportación SolidWorks → CSV (UTF-8 con BOM recomendado).

Cabecera (primera fila), nombres insensibles a mayúsculas; delimitador `;` o `,` (autodetectado).

Columnas:
  - codigo (obligatorio): stem del archivo de la pieza (.sldprt / .sldasm), sin ruta.
    La comparación normaliza códigos (mayúsculas, NFKC, extensión opcional, ``_`` → ``-``).
  - cantidad (obligatorio): cantidad efectiva respecto al ensamble raíz (producto de cantidades en la jerarquía).
  - ruta_subensambles: trazabilidad opcional, p. ej. ``SUB1|SUB2`` desde la raíz.
  - suprimido: 0/1 o S/N — por defecto las filas suprimidas se ignoran en el diff;
    el cliente puede enviar ``include_suppressed=true`` para incluirlas (árbol completo).
  - archivo_completo: nombre de archivo con extensión (opcional, auditoría).
  - configuracion: nombre de configuración referenciada (opcional).

Ejemplo (``;``):
  codigo;cantidad;ruta_subensambles;suprimido;archivo_completo;configuracion
  P-001;4;GRUPO_A|SUB1;0;P-001.sldprt;Predeterminada

La comparación con la lista aprobada es **por código**: se suman cantidades en el CSV y se
comparan con la suma de la lista en todas las estaciones (no se cruza por estación en SW).

Auditoría (backend): cada llamada a ``/api/bom/despiece/compare`` o ``reporte-csv`` registra
en ``Tbl_Auditoria_Cambios`` la acción ``despiece_sw_compare`` con código de pieza
``BOM-DESPIECE-{id_revision}`` y un JSON breve en ``Valor_Nuevo``.
"""

from __future__ import annotations

import csv
import io
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, DefaultDict, Dict, Iterable, List, Optional, Set, Tuple

# Extensiones que a veces aparecen en Codigo_Pieza aunque el SW exporte solo el stem.
_MODEL_EXTENSIONS: Tuple[str, ...] = (".sldprt", ".sldasm", ".slddrw")


def norm_key_codigo(s: str) -> str:
    """
    Clave estable para comparar códigos entre SW, BOM y maestro.

    - Unicode NFKC (homogeneiza caracteres compatibles).
    - Sin extensión de modelo al final, si viene en el texto.
    - Espacios colapsados; guiones bajos unificados a guión (típico CAD vs ERP).
    - Comparación insensible a mayúsculas (casefold).
    """
    t = (s or "").strip()
    if not t:
        return ""
    t = unicodedata.normalize("NFKC", t)
    tl = t.casefold()
    for ext in _MODEL_EXTENSIONS:
        if tl.endswith(ext):
            t = t[: -len(ext)].strip()
            tl = t.casefold()
            break
    t = " ".join(t.split())
    t = t.replace("_", "-")
    return t.casefold()


def _parse_boolish(v: str) -> bool:
    x = (v or "").strip().upper()
    return x in ("1", "S", "SI", "Y", "YES", "TRUE", "T")


def _sniff_delimiter(line: str) -> str:
    sc = line.count(";")
    cc = line.count(",")
    return ";" if sc >= cc else ","


def _open_text_with_bom(raw: bytes) -> str:
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw.decode("utf-8-sig")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1", errors="replace")


@dataclass
class SwRow:
    codigo: str
    cantidad: float
    ruta_subensambles: str = ""
    suprimido: bool = False
    archivo_completo: str = ""
    configuracion: str = ""


@dataclass
class DespieceCompareResult:
    id_revision: int
    lineas_sw_usadas: int
    lineas_lista: int
    codigos_sw_unicos: int
    codigos_lista_unicos: int
    codigos_en_ambos: int
    codigos_solo_sw: int
    codigos_solo_lista: int
    codigos_ok_cantidades: int
    codigos_conflicto_cantidad: int
    cobertura_por_estacion: List[Dict[str, Any]] = field(default_factory=list)
    por_tipo: Dict[str, int] = field(default_factory=dict)
    filas: List[Dict[str, Any]] = field(default_factory=list)
    include_suppressed: bool = False
    csv_filas_total: int = 0
    csv_filas_suprimidas: int = 0


def parse_sw_export_csv(content: bytes) -> List[SwRow]:
    text = _open_text_with_bom(content)
    if not text.strip():
        return []
    first_line = text.splitlines()[0]
    delim = _sniff_delimiter(first_line)
    reader = csv.DictReader(io.StringIO(text), delimiter=delim)
    if not reader.fieldnames:
        return []

    def col(name: str) -> Optional[str]:
        for h in reader.fieldnames or []:
            if h and h.strip().casefold() == name.casefold():
                return h
        return None

    c_codigo = col("codigo")
    c_cant = col("cantidad")
    if not c_codigo or not c_cant:
        raise ValueError(
            "CSV inválido: faltan columnas obligatorias 'codigo' y/o 'cantidad'."
        )
    c_ruta = col("ruta_subensambles")
    c_sup = col("suprimido")
    c_arch = col("archivo_completo")
    c_cfg = col("configuracion")

    out: List[SwRow] = []
    for row in reader:
        raw_code = (row.get(c_codigo) or "").strip()
        if not raw_code:
            continue
        try:
            qty = float(str(row.get(c_cant) or "0").replace(",", "."))
        except ValueError:
            qty = 0.0
        ruta = (row.get(c_ruta) or "").strip() if c_ruta else ""
        sup = _parse_boolish(row.get(c_sup) or "") if c_sup else False
        arch = (row.get(c_arch) or "").strip() if c_arch else ""
        cfg = (row.get(c_cfg) or "").strip() if c_cfg else ""
        out.append(
            SwRow(
                codigo=raw_code,
                cantidad=qty,
                ruta_subensambles=ruta,
                suprimido=sup,
                archivo_completo=arch,
                configuracion=cfg,
            )
        )
    return out


def aggregate_sw_rows(
    rows: Iterable[SwRow],
    *,
    include_suppressed: bool = False,
) -> Tuple[DefaultDict[str, float], int, Dict[str, str]]:
    """Suma cantidades por código normalizado y texto representativo (primer valor visto)."""
    by_code: DefaultDict[str, float] = defaultdict(float)
    display: Dict[str, str] = {}
    used = 0
    for r in rows:
        if r.suprimido and not include_suppressed:
            continue
        raw_code = (r.codigo or "").strip()
        ck = norm_key_codigo(raw_code)
        if not ck:
            continue
        if ck not in display:
            display[ck] = raw_code
        by_code[ck] += r.cantidad
        used += 1
    return by_code, used, display


def load_bom_lines_for_revision(cursor, id_revision: int) -> List[Dict[str, Any]]:
    cursor.execute(
        """
        SELECT
            E.Codigo_Pieza,
            E.Cantidad,
            ES.Nombre_Estacion,
            EN.Nombre_Ensamble
        FROM Tbl_BOM_Estructura E
        INNER JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
        INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        WHERE ES.ID_Revision = ?
        """,
        (id_revision,),
    )
    rows = cursor.fetchall()
    out: List[Dict[str, Any]] = []
    for r in rows:
        out.append(
            {
                "codigo": str(r.Codigo_Pieza or "").strip(),
                "cantidad": float(r.Cantidad) if r.Cantidad is not None else 0.0,
                "nombre_estacion": str(r.Nombre_Estacion or "").strip(),
                "nombre_ensamble": str(r.Nombre_Ensamble or "").strip(),
            }
        )
    return out


def aggregate_bom_lines(
    lines: Iterable[Dict[str, Any]],
) -> Tuple[DefaultDict[str, float], Dict[str, str]]:
    by_code: DefaultDict[str, float] = defaultdict(float)
    display: Dict[str, str] = {}
    for ln in lines:
        raw = str(ln.get("codigo") or "").strip()
        ck = norm_key_codigo(raw)
        if not ck:
            continue
        if ck not in display:
            display[ck] = raw
        q = float(ln["cantidad"] or 0)
        by_code[ck] += q
    return by_code, display


def load_maestro_codes(cursor) -> Set[str]:
    cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas")
    s: Set[str] = set()
    for r in cursor.fetchall():
        c = str(r.Codigo_Pieza or "").strip()
        if c:
            s.add(norm_key_codigo(c))
    return s


def _sw_context_by_code(
    sw_rows: List[SwRow],
    *,
    include_suppressed: bool = False,
) -> Dict[str, Dict[str, str]]:
    """Primera ruta SW vista por código normalizado (para filas informativas)."""
    out: Dict[str, Dict[str, str]] = {}
    for r in sw_rows:
        if r.suprimido and not include_suppressed:
            continue
        ck = norm_key_codigo(r.codigo)
        if not ck or ck in out:
            continue
        out[ck] = {
            "estacion_sw": "",
            "ruta_sw": (r.ruta_subensambles or "").strip(),
        }
    return out


def _index_bom_por_codigo_norm(
    bom_lines: List[Dict[str, Any]],
) -> DefaultDict[str, List[Dict[str, Any]]]:
    """Índice código normalizado → líneas BOM (evita O(n²) al armar LISTA_SIN_SW)."""
    idx: DefaultDict[str, List[Dict[str, Any]]] = defaultdict(list)
    for ln in bom_lines:
        ck = norm_key_codigo(str(ln.get("codigo") or ""))
        if ck:
            idx[ck].append(ln)
    return idx


def _lista_contexto_desde_lineas(lineas: List[Dict[str, Any]]) -> Tuple[str, str]:
    """Estaciones y ensambles a partir de las líneas BOM ya filtradas por código."""
    ests: List[str] = []
    enss: List[str] = []
    seen_e: Set[str] = set()
    seen_n: Set[str] = set()
    for ln in lineas:
        e = str(ln.get("nombre_estacion") or "").strip()
        if e and e not in seen_e:
            seen_e.add(e)
            ests.append(e)
        n = str(ln.get("nombre_ensamble") or "").strip()
        if n and n not in seen_n:
            seen_n.add(n)
            enss.append(n)
    return (" · ".join(ests) if ests else "—", " · ".join(enss) if enss else "—")


def _cobertura_global_totales_por_codigo(
    bom_by_code: DefaultDict[str, float],
    sw_by_code: DefaultDict[str, float],
    bom_codes: Set[str],
    sw_codes: Set[str],
) -> List[Dict[str, Any]]:
    """Resumen de cobertura: totales por código (lista sumada en todas las estaciones)."""
    ok = 0
    diff = 0
    for ck in bom_codes & sw_codes:
        if abs(float(sw_by_code[ck]) - float(bom_by_code[ck])) <= 1e-6:
            ok += 1
        else:
            diff += 1
    return [
        {
            "estacion": "Totales por código (lista sumada en todas las estaciones)",
            "codigos_en_lista": len(bom_codes),
            "coinciden_sw": ok,
            "cantidad_distinta": diff,
            "no_aparece_en_csv": len(bom_codes - sw_codes),
        }
    ]


def compare_despiece(
    id_revision: int,
    sw_rows: List[SwRow],
    *,
    include_suppressed: bool = False,
    cursor: Any = None,
) -> DespieceCompareResult:
    if cursor is None:
        raise ValueError("cursor es obligatorio")

    bom_lines = load_bom_lines_for_revision(cursor, id_revision)
    if not bom_lines:
        raise ValueError(f"No hay líneas BOM para ID_Revisión {id_revision}.")

    maestro = load_maestro_codes(cursor)
    bom_idx = _index_bom_por_codigo_norm(bom_lines)
    csv_filas_total = len(sw_rows)
    csv_filas_suprimidas = sum(1 for r in sw_rows if r.suprimido)

    sw_by_code, sw_used, sw_display = aggregate_sw_rows(
        sw_rows,
        include_suppressed=include_suppressed,
    )
    bom_by_code, bom_display = aggregate_bom_lines(bom_lines)
    sw_ctx = _sw_context_by_code(
        sw_rows,
        include_suppressed=include_suppressed,
    )

    def etiqueta_codigo(ck: str) -> str:
        return bom_display.get(ck) or sw_display.get(ck) or ck

    filas: List[Dict[str, Any]] = []
    por_tipo: DefaultDict[str, int] = defaultdict(int)

    sw_codes = set(sw_by_code.keys())
    bom_codes = set(bom_by_code.keys())
    intersect = sw_codes & bom_codes
    mismatch_codes: Set[str] = set()

    for ck in sorted(sw_codes - bom_codes):
        tipo = "SW_SIN_LISTA"
        por_tipo[tipo] += 1
        in_maestro = ck in maestro
        sx = sw_ctx.get(ck, {})
        filas.append(
            {
                "tipo": tipo,
                "codigo": etiqueta_codigo(ck),
                "detalle": "En el CSV de SolidWorks hay piezas que no están en esta lista de materiales.",
                "cantidad_sw": sw_by_code[ck],
                "cantidad_lista": 0.0,
                "estacion_sw": sx.get("estacion_sw", ""),
                "estacion_lista": "",
                "ruta_sw": sx.get("ruta_sw", ""),
                "en_maestro": in_maestro,
                "nota": ""
                if in_maestro
                else "No existe en Tbl_Maestro_Piezas (revisar nomenclatura).",
            }
        )

    for ck in sorted(bom_codes - sw_codes):
        tipo = "LISTA_SIN_SW"
        por_tipo[tipo] += 1
        est_txt, ens_txt = _lista_contexto_desde_lineas(bom_idx.get(ck, []))
        filas.append(
            {
                "tipo": tipo,
                "codigo": etiqueta_codigo(ck),
                "detalle": "La lista incluye este código pero no aparece en el CSV (o quedó fuera por suprimido).",
                "cantidad_sw": 0.0,
                "cantidad_lista": bom_by_code[ck],
                "estacion_sw": "",
                "estacion_lista": "",
                "estaciones_lista": est_txt,
                "ensambles_lista": ens_txt,
                "en_maestro": ck in maestro,
                "nota": "",
            }
        )

    for ck in sorted(intersect):
        a = float(sw_by_code[ck])
        b = float(bom_by_code[ck])
        if abs(a - b) > 1e-6:
            tipo = "CANTIDAD_MISMATCH"
            por_tipo[tipo] += 1
            mismatch_codes.add(ck)
            est_txt, ens_txt = _lista_contexto_desde_lineas(bom_idx.get(ck, []))
            filas.append(
                {
                    "tipo": tipo,
                    "codigo": etiqueta_codigo(ck),
                    "detalle": "Cantidad total distinta: suma en el CSV frente a la suma en toda la lista.",
                    "cantidad_sw": a,
                    "cantidad_lista": b,
                    "estacion_sw": "",
                    "estacion_lista": "",
                    "estaciones_lista": est_txt,
                    "ensambles_lista": ens_txt,
                    "en_maestro": ck in maestro,
                    "nota": "",
                }
            )

    cobertura = _cobertura_global_totales_por_codigo(
        bom_by_code, sw_by_code, bom_codes, sw_codes
    )
    codigos_ok_cantidades = len(intersect - mismatch_codes)

    return DespieceCompareResult(
        id_revision=id_revision,
        lineas_sw_usadas=sw_used,
        lineas_lista=len(bom_lines),
        codigos_sw_unicos=len(sw_codes),
        codigos_lista_unicos=len(bom_codes),
        codigos_en_ambos=len(intersect),
        codigos_solo_sw=len(sw_codes - bom_codes),
        codigos_solo_lista=len(bom_codes - sw_codes),
        codigos_ok_cantidades=codigos_ok_cantidades,
        codigos_conflicto_cantidad=len(mismatch_codes),
        cobertura_por_estacion=cobertura,
        por_tipo=dict(por_tipo),
        filas=filas,
        include_suppressed=include_suppressed,
        csv_filas_total=csv_filas_total,
        csv_filas_suprimidas=csv_filas_suprimidas,
    )


def limit_filas_para_api(
    filas: List[Dict[str, Any]],
    *,
    max_filas: int,
) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """
    La app no debe pintar miles de filas: prioriza discrepancias de cantidad, luego solo-CSV, luego solo-lista.
    El informe CSV completo sigue generándose en el servidor con todas las filas.
    """
    cap = max(30, min(int(max_filas or 200), 500))
    total = len(filas)
    if total <= cap:
        return list(filas), {
            "truncado": False,
            "total": total,
            "mostradas": total,
            "limite": cap,
        }
    order = {"CANTIDAD_MISMATCH": 0, "SW_SIN_LISTA": 1, "LISTA_SIN_SW": 2}
    s = sorted(
        filas,
        key=lambda f: (order.get(str(f.get("tipo") or ""), 9), str(f.get("codigo") or "")),
    )
    muestra = s[:cap]
    return muestra, {
        "truncado": True,
        "total": total,
        "mostradas": cap,
        "limite": cap,
        "nota": "Use “Descargar informe CSV” para el listado completo de discrepancias.",
    }


def filas_to_csv(filas: List[Dict[str, Any]]) -> str:
    """CSV con UTF-8 BOM para Excel."""
    buf = io.StringIO()
    fieldnames = [
        "tipo",
        "codigo",
        "detalle",
        "cantidad_sw",
        "cantidad_lista",
        "estacion_sw",
        "estacion_lista",
        "ruta_sw",
        "estaciones_lista",
        "ensambles_lista",
        "estaciones_sw",
        "en_maestro",
        "nota",
    ]
    w = csv.DictWriter(buf, fieldnames=fieldnames, delimiter=";", extrasaction="ignore")
    w.writeheader()
    for row in filas:
        flat = {k: row.get(k, "") for k in fieldnames}
        for k in ("estaciones_sw", "estaciones_lista"):
            v = flat.get(k)
            if isinstance(v, list):
                flat[k] = "|".join(v)
        w.writerow(flat)
    return buf.getvalue()
