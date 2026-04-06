-- Etiquetas (#hashtags) por documento en Ayudas Visuales (JSON array de strings en NVARCHAR(MAX)).
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.Tbl_Ayudas_Maestro') AND name = N'Tags'
)
BEGIN
    ALTER TABLE dbo.Tbl_Ayudas_Maestro ADD Tags NVARCHAR(MAX) NULL;
END
GO
