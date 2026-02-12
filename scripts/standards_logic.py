
# --- ESTÁNDARES DE MATERIALES (v12.0) ---

DEFAULT_STANDARDS = [
    # ACEROS
    {"Descripcion": "ACERO A36", "Categoria": "ACERO"},
    {"Descripcion": "ACERO 1018", "Categoria": "ACERO"},
    {"Descripcion": "ACERO 1045", "Categoria": "ACERO"},
    {"Descripcion": "ACERO 4140", "Categoria": "ACERO"},
    {"Descripcion": "ACERO 8620", "Categoria": "ACERO"},
    {"Descripcion": "ACERO D2", "Categoria": "ACERO"},
    {"Descripcion": "ACERO O1", "Categoria": "ACERO"},
    {"Descripcion": "ACERO H13", "Categoria": "ACERO"},
    {"Descripcion": "ACERO INOXIDABLE 304", "Categoria": "INOXIDABLE"},
    {"Descripcion": "ACERO INOXIDABLE 316", "Categoria": "INOXIDABLE"},
    {"Descripcion": "ACERO INOXIDABLE 316L", "Categoria": "INOXIDABLE"},
    {"Descripcion": "ACERO INOXIDABLE 416", "Categoria": "INOXIDABLE"},
    {"Descripcion": "ACERO INOXIDABLE 420", "Categoria": "INOXIDABLE"},
    
    # ALUMINIOS
    {"Descripcion": "ALUMINIO 6061", "Categoria": "ALUMINIO"},
    {"Descripcion": "ALUMINIO 6061 T6", "Categoria": "ALUMINIO"},
    {"Descripcion": "ALUMINIO 7075", "Categoria": "ALUMINIO"},
    {"Descripcion": "ALUMINIO 5052", "Categoria": "ALUMINIO"},
    {"Descripcion": "ALUMINIO MIC-6", "Categoria": "ALUMINIO"},
    
    # PLÁSTICOS DE INGENIERÍA
    {"Descripcion": "NYLAMID V (VERDE - LUBRICADO)", "Categoria": "PLASTICO"},
    {"Descripcion": "NYLAMID M (MECANICO)", "Categoria": "PLASTICO"},
    {"Descripcion": "NYLAMID SL (NEGRO)", "Categoria": "PLASTICO"},
    {"Descripcion": "NYLAMID 6/6", "Categoria": "PLASTICO"},
    {"Descripcion": "ACETAL (DELRIN) BLANCO", "Categoria": "PLASTICO"},
    {"Descripcion": "ACETAL (DELRIN) NEGRO", "Categoria": "PLASTICO"},
    {"Descripcion": "UHMW-PE (POLIETILENO)", "Categoria": "PLASTICO"},
    {"Descripcion": "PTFE (TEFLON)", "Categoria": "PLASTICO"},
    {"Descripcion": "PEEK", "Categoria": "PLASTICO"},
    {"Descripcion": "POLICARBONATO (LEXAN)", "Categoria": "PLASTICO"},
    {"Descripcion": "ACRILICO", "Categoria": "PLASTICO"},
    {"Descripcion": "PVC GRIS CEDULA 80", "Categoria": "PLASTICO"},
    
    # METALES NO FERROSOS
    {"Descripcion": "BRONCE SAE 62", "Categoria": "BRONCE"},
    {"Descripcion": "BRONCE SAE 64", "Categoria": "BRONCE"},
    {"Descripcion": "BRONCE SAE 660", "Categoria": "BRONCE"},
    {"Descripcion": "BRONCE AL-NI (ALUMINIO-NIQUEL)", "Categoria": "BRONCE"},
    {"Descripcion": "COBRE ELECTROLITICO", "Categoria": "COBRE"},
    {"Descripcion": "COBRE BERILIO", "Categoria": "COBRE"},
    {"Descripcion": "LATON", "Categoria": "LATON"},
    
    # PERFILES ESTRUCTURALES (EJEMPLOS COMUNES)
    {"Descripcion": "ANGULO DE ACERO 1 X 1 X 1/8", "Categoria": "PERFIL"},
    {"Descripcion": "ANGULO DE ACERO 1-1/2 X 1-1/2 X 1/8", "Categoria": "PERFIL"},
    {"Descripcion": "ANGULO DE ACERO 2 X 2 X 1/4", "Categoria": "PERFIL"},
    {"Descripcion": "SOLERA DE ACERO 1 X 1/8", "Categoria": "PERFIL"},
    {"Descripcion": "SOLERA DE ACERO 2 X 1/4", "Categoria": "PERFIL"},
    {"Descripcion": "PTR 1 X 1 CAL 14", "Categoria": "PERFIL"},
    {"Descripcion": "PTR 2 X 2 CAL 11", "Categoria": "PERFIL"},
    {"Descripcion": "HSS 3 X 3 X 1/4", "Categoria": "PERFIL"},
    {"Descripcion": "HSS 4 X 4 X 1/4", "Categoria": "PERFIL"},
    {"Descripcion": "TUBO CEDULA 40 1 PULGADA", "Categoria": "TUBERIA"},
    {"Descripcion": "TUBO CEDULA 80 1 PULGADA", "Categoria": "TUBERIA"},
    
    # MATERIALES ESPECIALES
    {"Descripcion": "CARBURO DE TUNGSTENO", "Categoria": "ESPECIAL"},
    {"Descripcion": "TITANIO GRADO 2", "Categoria": "ESPECIAL"},
    {"Descripcion": "GRAFITO", "Categoria": "ESPECIAL"}
]

def ensure_standards_table():
    engine = get_engine()
    
    # 1. Crear tabla si no existe
    create_table_query = """
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='Tbl_Estandares_Materiales' AND xtype='U')
    BEGIN
        CREATE TABLE Tbl_Estandares_Materiales (
            ID INT IDENTITY(1,1) PRIMARY KEY, 
            Descripcion NVARCHAR(400) UNIQUE NOT NULL, 
            Categoria NVARCHAR(100)
        )
    END
    """
    
    try:
        with engine.begin() as conn:
            conn.execute(text(create_table_query))
            
            # 2. Verificar si está vacía para sembrar datos
            res = conn.execute(text("SELECT COUNT(*) FROM Tbl_Estandares_Materiales")).fetchone()
            count = res[0] if res else 0
            
            if count == 0:
                print("Sembrando Tbl_Estandares_Materiales con datos por defecto...")
                insert_query = text("INSERT INTO Tbl_Estandares_Materiales (Descripcion, Categoria) VALUES (:d, :c)")
                for item in DEFAULT_STANDARDS:
                    try:
                        conn.execute(insert_query, {"d": item["Descripcion"], "c": item["Categoria"]})
                    except:
                        pass # Ignorar duplicados si por alguna razón fallara la lógica de conteo
    except Exception as e:
        print(f"Error inicializando tabla de estándares: {e}")

def get_standards():
    ensure_standards_table() # Asegurar existencia antes de leer
    engine = get_engine()
    with engine.connect() as conn:
        df = pd.read_sql("SELECT * FROM Tbl_Estandares_Materiales ORDER BY Descripcion ASC", conn)
    return sanitize(df).to_dict(orient='records')

def add_standard(desc, cat="GENERAL"):
    engine = get_engine()
    try:
        with engine.begin() as conn:
            conn.execute(text("INSERT INTO Tbl_Estandares_Materiales (Descripcion, Categoria) VALUES (:d, :c)"), {"d": desc, "c": cat})
        return {"status": "success"}
    except Exception as e:
        if "UNIQUE constraint" in str(e) or "2627" in str(e):
            return {"status": "error", "message": "El material ya existe en la biblioteca."}
        return {"status": "error", "message": str(e)}

def edit_standard(id, new_desc):
    engine = get_engine()
    try:
        with engine.begin() as conn:
            conn.execute(text("UPDATE Tbl_Estandares_Materiales SET Descripcion = :d WHERE ID = :id"), {"d": new_desc, "id": id})
        return {"status": "success"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def delete_standard(id):
    engine = get_engine()
    try:
        with engine.begin() as conn:
            conn.execute(text("DELETE FROM Tbl_Estandares_Materiales WHERE ID = :id"), {"id": id})
        return {"status": "success"}
    except Exception as e:
        return {"status": "error", "message": str(e)}
