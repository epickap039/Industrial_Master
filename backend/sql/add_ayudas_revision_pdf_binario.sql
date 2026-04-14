-- Ayudas visuales: copia del PDF en BD para conservar historial aunque se mueva o borre el archivo en disco.
-- La API sirve primero Pdf_Binario si existe y no está vacío; si no, usa Ruta_PDF como antes.

IF COL_LENGTH('dbo.Tbl_Ayudas_Revisiones', 'Pdf_Binario') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Ayudas_Revisiones
    ADD Pdf_Binario VARBINARY(MAX) NULL;
END
GO
