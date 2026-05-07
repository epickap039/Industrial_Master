from database import get_db_connection
from env_config import allow_runtime_ddl


def iniciar_auditoria():
    """Crea la tabla de auditoría si no existe. No detiene el arranque si falla."""
    print("--- INICIANDO SISTEMA DE AUDITORIA ---")
    if not allow_runtime_ddl():
        print(
            "--- IM_ALLOW_RUNTIME_DDL desactivado: se omite creación automática en iniciar_auditoria(); "
            "aplique las migraciones SQL equivalentes ---"
        )
        return
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Auditoria_Cambios')
            BEGIN
                CREATE TABLE Tbl_Auditoria_Cambios (
                    ID_Log INT IDENTITY(1,1) PRIMARY KEY,
                    Codigo_Pieza VARCHAR(50),
                    Accion VARCHAR(50),
                    Valor_Anterior NVARCHAR(MAX),
                    Valor_Nuevo NVARCHAR(MAX),
                    Usuario VARCHAR(100),
                    Fecha_Hora DATETIME DEFAULT GETDATE()
                );
            END
        """)
        conn.commit()
    # TABLA DE MATERIALES APROBADOS
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Materiales_Aprobados')
            BEGIN
                CREATE TABLE Tbl_Materiales_Aprobados (
                    ID INT IDENTITY(1,1) PRIMARY KEY,
                    Material VARCHAR(200) UNIQUE
                );
            END
        """)
        
        # POBLAR TABLA SI ESTÁ VACÍA
        cursor.execute("SELECT COUNT(*) FROM Tbl_Materiales_Aprobados")
        if cursor.fetchone()[0] == 0:
            materiales_iniciales = [
                "ACERO ASTM A36 1/8\"", "ACERO ASTM A36 3/16\"", "ACERO ASTM A36 C.10", "ACERO ASTM A36 C.14", "ACERO ASTM A36 C.16",
                "ACERO ASTM A572 G50 1/2\"", "ACERO ASTM A572 G50 1/4\"", "ACERO ASTM A572 G50 3/4\"", "ACERO ASTM A572 G50 3/8\"", "ACERO ASTM A572 G50 5/16\"",
                "ACERO INOXIDABLE 304 CAL.16", "ACERO INOXIDABLE C.11", "ALUMINIO 3003 C.11", "ALUMINIO 3003 C.14", "ALUMINIO 5052 1/4\"", "ALUMINIO NEGRO 3003 C.19",
                "ALUMINIO MACIZO 6026 Ø 1 1/2\"", "ALUMINIO MACIZO 6026 Ø 1/2\"", "ALUMINIO MACIZO 6026 Ø 2 1/2\"", "ALUMINIO MACIZO 6026 Ø 2\"", "ALUMINIO MACIZO 6026 Ø 3 1/2\"", "ALUMINIO MACIZO 6026 Ø 3\"", "ALUMINIO MACIZO 6026 Ø 4\"", "ALUMINIO MACIZO 6026 Ø 7/8\"",
                "ANGULO ASTM A36 1 1/2\" x 1 1/2\" x 3/16\"", "ANGULO ASTM A36 1\" x 1\" x 3/16\"", "ANGULO ASTM A36 2\" x 2\" x 3/16\"",
                "BARRA HUECA AISI 1018 Ø 33mm x 14mm", "BARRA HUECA AISI 1018 Ø 40mm x 25mm", "BARRA HUECA AISI 1018 Ø 40mm x 28mm", "BARRA HUECA AISI 1018 Ø 50mm x 35mm", "BARRA HUECA AISI 1018 Ø 76mm x 38mm",
                "BARRA CROMADA AISI 1045 Ø 28mm", "BARRA CROMADA AISI 1045 Ø 45mm", "TUBO HONEADO AISI 1018 Ø 60mm x 50mm", "TUBO HONEADO AISI 1018 Ø 73mm x 63mm",
                "BARRA HUECA CROMADA AISI 1018 Ø 38.1mm X 25.4mm",
                "BARRA HUECA DE ALUMINIO B241 6026 Ø 101.6mm X 50.5mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 63.5mm X 29.7mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 76.2mm X 29.7mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 88.9mm X 24.7mm",
                "CAJA DE TENSADO DE LONA", "CANAL C A36 4\"", "COMERCIAL BISAGRA DE LIBRO", "COMERCIAL BISAGRA DE PIANO", "MATRACA DE LONA", "PERFIL ALUMINIO PELDAÑO 688 6061 T6", "PERNO REY  COMERCIAL", "SEGURO DE FUNDICION -", "SEGURO DE RESORTE CORTO", "SEGURO DE RESORTE LARGO",
                "HSS ASTM A500 °B 2 1/2\" x 2 1/2\" x 1/4\"", "HSS ASTM A500 °B 2 1/2\" x 2 1/2\" x 3/16\"", "HSS ASTM A500 °B 2\" x 2\" x 1/4\"", "HSS ASTM A500 °B 2\" x 2\" x 3/16\"", "HSS ASTM A500 °B 3 1/2\" X 3 1/2\" X 3/16\"", "HSS ASTM A500 °B 3\" x 2\" x 1/4\"", "HSS ASTM A500 °B 3\" x 2\" x 3/16\"", "HSS ASTM A500 °B 3\" x 3\" x 1/4\"", "HSS ASTM A500 °B 3\" x 3\" x 3/16\"", "HSS ASTM A500 °B 4 1/2\" x 3 1/2\" x 3/16\"", "HSS ASTM A500 °B 4\" x 2\" x 1/4\"", "HSS ASTM A500 °B 4\" x 2\" x 3/16\"", "HSS ASTM A500 °B 4\" x 3\" x 1/4\"", "HSS ASTM A500 °B 4\" x 3\" x 3/16\"", "HSS ASTM A500 °B 4\" x 3\" x 3/8\"", "HSS ASTM A500 °B 4\" x 4\" x 3/8\"", "HSS ASTM A500 °B 6\" x 2\" x 1/4\"", "HSS ASTM A500 °B 6\" x 2\" x 3/16\"", "HSS ASTM A500 °B 6\" x 3\" x 1/4\"", "HSS ASTM A500 °B 6\" x 3\" x 3/16\"", "HSS ASTM A500 °B 6\" x 4\" x 1/4\"", "HSS ASTM A500 °B 6\" x 4\" x 3/8\"", "HSS ASTM A500 °B 6\" X 6\" X 1/4\"", "HSS ASTM A500 °B 6\" x 6\" x 3/8\"",
                "PLACA HARDOX 1/4\"", "PLACA STRENX 110 XF 3/16\"", "PLACA STRENX 110XF 1/2\"",
                "PTR ASTM A36 1 1/2\" x 1 1/2 \" x 3/16\"", "PTR ASTM A36 1\" x 1\" x C.11",
                "REDONDO AISI 1018 Ø 1 1/2\"", "REDONDO AISI 1018 Ø 1 1/4\"", "REDONDO AISI 1018 Ø 1 3/8\"", "REDONDO AISI 1018 Ø 1\"", "REDONDO AISI 1018 Ø 1/2\"", "REDONDO AISI 1018 Ø 2 1/2\"", "REDONDO AISI 1018 Ø 2 5/8\"", "REDONDO AISI 1018 Ø 2\"", "REDONDO AISI 1018 Ø 3\"", "REDONDO AISI 1018 Ø 3/4\"", "REDONDO AISI 1018 Ø 7/8\"", "REDONDO NEGRO Ø 5/16\"", "REDONDO NEGRO Ø 5/8\"",
                "RIEL DE ACERO A36 1500", "SOLERA ASTM A36 1 1/2\" x 1/2\"", "SOLERA ASTM A36 1 1/4\" x 1/4\"", "SOLERA ASTM A36 1\" x 1/2\"", "SOLERA ASTM A36 2\" x 1\"", "SOLERA ASTM A36 4\" x 1\"", "SOLERA ASTM A36 6\" x 1\"", "SOLERA DE ALUMINIO ASTM A36 2\" X 1\"",
                "TOLDO ALUMINIO C.19",
                "TUBO DE ACERO A500 °B Ø 1 1/2\" CED. 80", "TUBO DE ACERO A500 °B Ø 1 1/2\" CED. 80 SIN/COS", "TUBO DE ACERO A500 °B Ø 1\" CED. 40 C/COS", "TUBO DE ACERO A500 °B Ø 1\" CED. 40 SIN/COS",
                "TUBO DE ALUMINIO B241 Ø  2\" x  1\" x 1/8\"", "TUBO DE ALUMINIO B241 Ø 2 1/2\"", "TUBO DE ALUMINIO B241 Ø 2\"", "TUBO DE ALUMINIO B241 Ø 2\" x  1\" x 1/8\"", "TUBO DE ALUMINIO B241 Ø 3 1/2\"", "TUBO DE ALUMINIO NEGRO B241 Ø 2 1/2\"",
                "TUBO STROCK CROMADO ASTM 1045 Ø 70mm X 63mm",
                "PERFIL ALUMINIO CUERNO EA 685 6061T6", "PERFIL ALUMINIO PRINCIPAL EXT 684 6061T6", "PERFIL ALUMINIO ANGULO VISTA 686", "PERFIL ALUMINIO REFUERZO INT 683", "BORDA LATERAL BASCULANTE 4.9 6061", "BORDA LATERAL BASCULANTE 3.5 6061", "PERFIL DE ALUMINIO TIPO BISAGRA ABATIBLE 3.10 MT 6061-T6", "PERFIL DE ALUMINIO TIPO ESCALON ABATIBLE 3.10 MT 6061-T6"
            ]
            
            for mat in materiales_iniciales:
                cursor.execute("IF NOT EXISTS (SELECT * FROM Tbl_Materiales_Aprobados WHERE Material = ?) INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)", (mat, mat))
            
            conn.commit()
            print(f"--- TB_MATERIALES_APROBADOS INICIALIZADA ({len(materiales_iniciales)} items) ---")

        # --- TABLAS DE JERARQUÍA DE PROYECTOS ---
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Proyectos_Tracto')
            BEGIN
                CREATE TABLE Tbl_Proyectos_Tracto (
                    ID_Tracto INT IDENTITY(1,1) PRIMARY KEY,
                    Nombre_Tracto VARCHAR(200) UNIQUE NOT NULL
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Tipos_Proyecto')
            BEGIN
                CREATE TABLE Tbl_Tipos_Proyecto (
                    ID_Tipo INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Tracto INT NOT NULL,
                    Nombre_Tipo VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Tipo_Tracto FOREIGN KEY (ID_Tracto) REFERENCES Tbl_Proyectos_Tracto(ID_Tracto) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Versiones_Ingenieria')
            BEGIN
                CREATE TABLE Tbl_Versiones_Ingenieria (
                    ID_Version INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Tipo INT NOT NULL,
                    Nombre_Version VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Version_Tipo FOREIGN KEY (ID_Tipo) REFERENCES Tbl_Tipos_Proyecto(ID_Tipo) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Clientes_Configuracion')
            BEGIN
                CREATE TABLE Tbl_Clientes_Configuracion (
                    ID_Config_Cliente INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Version INT NOT NULL,
                    Nombre_Cliente VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Cliente_Version FOREIGN KEY (ID_Version) REFERENCES Tbl_Versiones_Ingenieria(ID_Version) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_BOM_Revisiones')
            BEGIN
                CREATE TABLE Tbl_BOM_Revisiones (
                    ID_Revision INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Version INT NOT NULL,
                    Numero_Revision INT NOT NULL,
                    Estado VARCHAR(200) NOT NULL,
                    Fecha_Creacion DATETIME DEFAULT GETDATE(),
                    CONSTRAINT FK_Revision_Version2 FOREIGN KEY (ID_Version) REFERENCES Tbl_Versiones_Ingenieria(ID_Version) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Estaciones')
            BEGIN
                CREATE TABLE Tbl_Estaciones (
                    ID_Estacion INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Revision INT NOT NULL,
                    Nombre_Estacion VARCHAR(200) NOT NULL,
                    Orden INT NOT NULL DEFAULT 0,
                    CONSTRAINT FK_Estacion_Revision FOREIGN KEY (ID_Revision) REFERENCES Tbl_BOM_Revisiones(ID_Revision) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Ensambles')
            BEGIN
                CREATE TABLE Tbl_Ensambles (
                    ID_Ensamble INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Estacion INT NOT NULL,
                    Nombre_Ensamble VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Ensamble_Estacion FOREIGN KEY (ID_Estacion) REFERENCES Tbl_Estaciones(ID_Estacion) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_BOM_Estructura')
            BEGIN
                CREATE TABLE Tbl_BOM_Estructura (
                    ID_BOM INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Ensamble INT NOT NULL,
                    Codigo_Pieza VARCHAR(50) NOT NULL,
                    Cantidad FLOAT NOT NULL,
                    Observaciones VARCHAR(500),
                    CONSTRAINT FK_BOM_Ensamble FOREIGN KEY (ID_Ensamble) REFERENCES Tbl_Ensambles(ID_Ensamble) ON DELETE CASCADE
                );
            END
        """)
        
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Unidades_Fisicas')
            BEGIN
                CREATE TABLE Tbl_Unidades_Fisicas (
                    ID_Unidad INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Revision INT NOT NULL,
                    Serie VARCHAR(50) NOT NULL,
                    Observaciones VARCHAR(MAX),
                    ID_VIN_Asociado INT NULL,
                    CONSTRAINT FK_Unidad_Revision FOREIGN KEY (ID_Revision) REFERENCES Tbl_BOM_Revisiones(ID_Revision) ON DELETE CASCADE
                );
            END
        """)
        conn.commit()

        print("--- ✅ SISTEMA DE AUDITORIA INICIALIZADO CORRECTAMENTE ---")
    except Exception as e:
        print(f"--- ⚠️ ALERTA SQL (Auditoría): {e} ---")
    finally:
        try:
             conn.close()
        except:
             pass

def registrar_auditoria(cursor, codigo_pieza, accion, valor_anterior, valor_nuevo, usuario):
    """
    Registra un evento en Tbl_Auditoria_Cambios.
    Maneja la conversión de dicts a JSON string si es necesario.
    """
    try:
        # Convertir a cadena si son diccionarios/listas
        if isinstance(valor_anterior, (dict, list)):
            valor_anterior = str(valor_anterior) # Usamos str() para ser consistente con lo que espera el parser (ast.literal_eval/json)
        if isinstance(valor_nuevo, (dict, list)):
            valor_nuevo = str(valor_nuevo)

        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (codigo_pieza, accion, str(valor_anterior), str(valor_nuevo), usuario))
    except Exception as e:
        print(f"--- ⚠️ ERROR AUDITORIA INTERNA: {e} ---")

def registrar_log_global(cursor, codigo_pieza, accion, anterior, nuevo, usuario):
    try:
        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (codigo_pieza, accion, anterior[:250], nuevo[:250], usuario))
    except Exception:
        pass