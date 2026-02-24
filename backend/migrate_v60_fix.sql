-- =======================================================
-- PASO FINAL: Eliminar FK y columna ID_Config_Cliente
-- Ejecutar SOLO si el migrate_v60.sql ya corrió exitosamente
-- =======================================================

-- 1. Buscar y eliminar CUALQUIER FK que dependa de ID_Config_Cliente
DECLARE @fk NVARCHAR(200);

SELECT @fk = fk.name
FROM sys.foreign_keys fk
INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
INNER JOIN sys.columns c ON fkc.parent_object_id = c.object_id 
                         AND fkc.parent_column_id = c.column_id
INNER JOIN sys.tables t ON fk.parent_object_id = t.object_id
WHERE t.name = 'Tbl_BOM_Revisiones'
  AND c.name = 'ID_Config_Cliente';

IF @fk IS NOT NULL
BEGIN
    EXEC('ALTER TABLE Tbl_BOM_Revisiones DROP CONSTRAINT ' + @fk);
    PRINT 'OK: FK eliminada -> ' + @fk;
END
ELSE
    PRINT 'SKIP: No se encontro FK sobre ID_Config_Cliente.';

-- 2. Eliminar la columna
IF EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'Tbl_BOM_Revisiones' AND COLUMN_NAME = 'ID_Config_Cliente'
)
BEGIN
    ALTER TABLE Tbl_BOM_Revisiones DROP COLUMN ID_Config_Cliente;
    PRINT 'OK: Columna ID_Config_Cliente eliminada.';
END
ELSE
    PRINT 'SKIP: Columna ya no existe.';

PRINT '>>> Migracion v60.0 COMPLETADA al 100%.';
