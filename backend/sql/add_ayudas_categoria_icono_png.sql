/*
  Añade soporte para iconos PNG en categorías de Ayudas Visuales.
  Requerido para el botón "Editar imagen categoría".
*/

IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Icono_Png_Base64') IS NULL
BEGIN
  ALTER TABLE dbo.Tbl_Ayudas_Categorias
  ADD Icono_Png_Base64 NVARCHAR(MAX) NULL;
END
GO
