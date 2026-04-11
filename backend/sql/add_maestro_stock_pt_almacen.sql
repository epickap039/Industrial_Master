-- Stock físico PT (hoja Inventario / Google Sheets) vinculado por Codigo_Pieza.
-- Ejecutar en la base del catálogo maestro (la app también intenta crear columnas al sincronizar).

IF COL_LENGTH('dbo.Tbl_Maestro_Piezas', 'Stock_PT_Almacen') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Maestro_Piezas
        ADD Stock_PT_Almacen INT NOT NULL
            CONSTRAINT DF_Tbl_Maestro_Piezas_Stock_PT_Almacen DEFAULT (0);
END
GO

IF COL_LENGTH('dbo.Tbl_Maestro_Piezas', 'Stock_PT_Almacen_SyncAt') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Maestro_Piezas ADD Stock_PT_Almacen_SyncAt DATETIME2(0) NULL;
END
GO

-- Migración defensiva para esquemas antiguos con columna nullable.
UPDATE dbo.Tbl_Maestro_Piezas
SET Stock_PT_Almacen = 0
WHERE Stock_PT_Almacen IS NULL;
GO
