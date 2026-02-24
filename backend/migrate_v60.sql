-- =======================================================
-- SCRIPT DE MIGRACIÓN: Industrial Manager v15.5 → v60.0
-- Fecha: 2026-02-24
-- IMPORTANTE: Ejecutar DESPUÉS del respaldo/backup
-- =======================================================

BEGIN TRANSACTION;

PRINT '>>> Paso 1: Crear Tbl_Log_Cambios_Ingenieria';
IF NOT EXISTS (SELECT 1 FROM sysobjects WHERE name='Tbl_Log_Cambios_Ingenieria' AND xtype='U')
BEGIN
    CREATE TABLE Tbl_Log_Cambios_Ingenieria (
        ID_Log          INT IDENTITY(1,1) PRIMARY KEY,
        ID_Revision     INT NOT NULL,
        Usuario         NVARCHAR(100) NOT NULL DEFAULT SYSTEM_USER,
        Fecha_Hora      DATETIME2 NOT NULL DEFAULT GETDATE(),
        Accion          NVARCHAR(50) NOT NULL,
        Detalle_Cambio  NVARCHAR(500) NOT NULL,
        Motivo          NVARCHAR(300) NULL,
        CONSTRAINT FK_Log_Revision FOREIGN KEY (ID_Revision)
            REFERENCES Tbl_BOM_Revisiones(ID_Revision)
    );
    PRINT '  OK: Tbl_Log_Cambios_Ingenieria creada.';
END
ELSE
    PRINT '  SKIP: Tbl_Log_Cambios_Ingenieria ya existe.';

PRINT '>>> Paso 2: Agregar ID_Revision_Asignada a Tbl_Clientes_Configuracion';
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'Tbl_Clientes_Configuracion' AND COLUMN_NAME = 'ID_Revision_Asignada'
)
BEGIN
    ALTER TABLE Tbl_Clientes_Configuracion
    ADD ID_Revision_Asignada INT NULL;
    PRINT '  OK: Columna ID_Revision_Asignada agregada.';
END
ELSE
    PRINT '  SKIP: Columna ya existe.';

PRINT '>>> Paso 3: Migrar Tbl_BOM_Revisiones (ID_Config_Cliente → ID_Version)';
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'Tbl_BOM_Revisiones' AND COLUMN_NAME = 'ID_Version'
)
BEGIN
    -- 3a. Agregar nueva columna nullable
    ALTER TABLE Tbl_BOM_Revisiones ADD ID_Version INT NULL;
    PRINT '  OK: Columna ID_Version agregada.';

    -- 3b. Rellenar via SQL dinámico (EXEC) para evitar error de parser
    --     SQL Server no reconoce columnas nuevas en el mismo batch si no se usa EXEC
    EXEC('
        UPDATE R
        SET R.ID_Version = CC.ID_Version
        FROM Tbl_BOM_Revisiones R
        JOIN Tbl_Clientes_Configuracion CC ON R.ID_Config_Cliente = CC.ID_Config_Cliente
    ');
    PRINT '  OK: Datos migrados (ID_Config_Cliente → ID_Version).';

    -- 3c. NOT NULL + FK (también via EXEC)
    EXEC('ALTER TABLE Tbl_BOM_Revisiones ALTER COLUMN ID_Version INT NOT NULL');
    EXEC('
        ALTER TABLE Tbl_BOM_Revisiones
        ADD CONSTRAINT FK_Revision_Version
        FOREIGN KEY (ID_Version) REFERENCES Tbl_Versiones_Ingenieria(ID_Version)
    ');
    PRINT '  OK: FK_Revision_Version establecida.';

    -- 3d. Eliminar FK antigua si existe
    DECLARE @fk_name NVARCHAR(200);
    SELECT @fk_name = CONSTRAINT_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
    WHERE TABLE_NAME = 'Tbl_BOM_Revisiones'
      AND CONSTRAINT_TYPE = 'FOREIGN KEY'
      AND CONSTRAINT_NAME LIKE '%Config_Cliente%';

    IF @fk_name IS NOT NULL
    BEGIN
        EXEC('ALTER TABLE Tbl_BOM_Revisiones DROP CONSTRAINT ' + @fk_name);
        PRINT '  OK: FK antigua eliminada.';
    END

    -- 3e. Eliminar columna antigua si existe
    IF EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'Tbl_BOM_Revisiones' AND COLUMN_NAME = 'ID_Config_Cliente'
    )
    BEGIN
        EXEC('ALTER TABLE Tbl_BOM_Revisiones DROP COLUMN ID_Config_Cliente');
        PRINT '  OK: Columna ID_Config_Cliente eliminada.';
    END
END
ELSE
    PRINT '  SKIP: Tbl_BOM_Revisiones ya fue migrada.';

PRINT '>>> Migración completada exitosamente.';
COMMIT TRANSACTION;
