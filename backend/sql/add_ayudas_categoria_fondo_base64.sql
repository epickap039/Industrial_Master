/*
  Ayudas visuales:
  agrega imagen de fondo configurable por categoría para tarjetas del menú.
*/
IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Fondo_Base64') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Ayudas_Categorias
    ADD Fondo_Base64 NVARCHAR(MAX) NULL;
END
GO
