/*
  Chat interno entre usuarios + soporte de zumbido.
*/

IF OBJECT_ID('dbo.Tbl_Chat_Mensajes', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tbl_Chat_Mensajes (
        ID_Mensaje INT IDENTITY(1,1) PRIMARY KEY,
        Emisor NVARCHAR(120) NOT NULL,
        Receptor NVARCHAR(120) NOT NULL,
        Tipo NVARCHAR(20) NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Tipo DEFAULT ('texto'),
        Mensaje NVARCHAR(MAX) NULL,
        Fecha_Envio DATETIME2(0) NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Fecha DEFAULT (SYSUTCDATETIME()),
        Leido BIT NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Leido DEFAULT (0)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tbl_Chat_Mensajes_ParFecha' AND object_id = OBJECT_ID('dbo.Tbl_Chat_Mensajes'))
BEGIN
    CREATE INDEX IX_Tbl_Chat_Mensajes_ParFecha
        ON dbo.Tbl_Chat_Mensajes (Emisor, Receptor, Fecha_Envio DESC);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Tbl_Chat_Mensajes_ReceptorLeido' AND object_id = OBJECT_ID('dbo.Tbl_Chat_Mensajes'))
BEGIN
    CREATE INDEX IX_Tbl_Chat_Mensajes_ReceptorLeido
        ON dbo.Tbl_Chat_Mensajes (Receptor, Leido, Fecha_Envio DESC);
END
GO
