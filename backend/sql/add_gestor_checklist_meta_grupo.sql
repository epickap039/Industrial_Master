-- Metadatos de ítem de checklist (grupo / categoría) para agrupación en Monitor.
-- Si ya existe Meta_JSON en Tbl_Gestor_Checklist, no hace falta ejecutar este script.

IF COL_LENGTH('dbo.Tbl_Gestor_Checklist', 'Meta_JSON') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Gestor_Checklist ADD Meta_JSON NVARCHAR(MAX) NULL;
END
GO

IF COL_LENGTH('dbo.Tbl_Gestor_Checklist', 'Grupo') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Gestor_Checklist ADD Grupo NVARCHAR(300) NULL;
END
GO
