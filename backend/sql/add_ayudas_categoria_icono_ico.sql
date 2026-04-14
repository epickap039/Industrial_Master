-- Ícono de categoría en ICO (tintado en cliente según tema; opcional frente a PNG legado).

IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Icono_Ico_Base64') IS NULL
BEGIN
  ALTER TABLE dbo.Tbl_Ayudas_Categorias
  ADD Icono_Ico_Base64 NVARCHAR(MAX) NULL;
END
GO
