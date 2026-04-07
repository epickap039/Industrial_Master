-- Script para agregar columna Minutos_Estimados a Tbl_Gestor_Tareas
-- Si la tabla no existe o ya tiene la columna, se ignora

BEGIN TRANSACTION;

PRINT '>>> Verificando si Tbl_Gestor_Tareas existe...';

IF EXISTS (SELECT 1 FROM sysobjects WHERE name='Tbl_Gestor_Tareas' AND xtype='U')
BEGIN
    PRINT 'OK: Tabla Tbl_Gestor_Tareas encontrada.';

    -- Verificar si la columna Minutos_Estimados ya existe
    IF NOT EXISTS (
        SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'Tbl_Gestor_Tareas'
          AND COLUMN_NAME = 'Minutos_Estimados'
    )
    BEGIN
        PRINT '>>> Agregando columna Minutos_Estimados...';
        ALTER TABLE Tbl_Gestor_Tareas
        ADD Minutos_Estimados INT NULL DEFAULT 0;

        PRINT 'OK: Columna Minutos_Estimados agregada.';
    END
    ELSE
    BEGIN
        PRINT 'SKIP: Columna Minutos_Estimados ya existe.';
    END
END
ELSE
BEGIN
    PRINT 'ERROR: Tabla Tbl_Gestor_Tareas no encontrada.';
END

COMMIT TRANSACTION;
