-- Tablas para módulo Ayudas Visuales (orden: categorías → maestro → revisiones → FKs)

IF OBJECT_ID('dbo.Tbl_Ayudas_Categorias', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tbl_Ayudas_Categorias (
        ID_Categoria     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        Nombre_Categoria NVARCHAR(200) NOT NULL,
        Activo           BIT NOT NULL DEFAULT 1,
        Icono_Codigo     NVARCHAR(50) NULL,
        Icono_Png_Base64 NVARCHAR(MAX) NULL
    );
END
GO

IF OBJECT_ID('dbo.Tbl_Ayudas_Maestro', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tbl_Ayudas_Maestro (
        Id_Ayuda         INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        Id_Categoria     INT NOT NULL,
        Titulo_Documento NVARCHAR(500) NOT NULL,
        Fecha_Creacion   DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        VIN              NVARCHAR(50) NULL
    );
END
GO

IF OBJECT_ID('dbo.Tbl_Ayudas_Revisiones', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tbl_Ayudas_Revisiones (
        Id_Revision     INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        Id_Ayuda        INT NOT NULL,
        Numero_Revision NVARCHAR(80) NOT NULL,
        Consecutivo_Unico NVARCHAR(80) NULL,
        Ruta_PDF        NVARCHAR(1000) NOT NULL,
        Fecha_Subida    DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
        Es_Vigente      BIT NOT NULL DEFAULT 1,
        Usuario_Subida  NVARCHAR(200) NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Ayudas_Maestro_Categoria')
    ALTER TABLE dbo.Tbl_Ayudas_Maestro
    ADD CONSTRAINT FK_Ayudas_Maestro_Categoria FOREIGN KEY (Id_Categoria)
        REFERENCES dbo.Tbl_Ayudas_Categorias (ID_Categoria);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Ayudas_Revisiones_Maestro')
    ALTER TABLE dbo.Tbl_Ayudas_Revisiones
    ADD CONSTRAINT FK_Ayudas_Revisiones_Maestro FOREIGN KEY (Id_Ayuda)
        REFERENCES dbo.Tbl_Ayudas_Maestro (Id_Ayuda);
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'UX_Ayudas_Consecutivo_Unico'
      AND object_id = OBJECT_ID('dbo.Tbl_Ayudas_Revisiones')
)
BEGIN
    CREATE UNIQUE INDEX UX_Ayudas_Consecutivo_Unico
    ON dbo.Tbl_Ayudas_Revisiones (Consecutivo_Unico)
    WHERE Consecutivo_Unico IS NOT NULL
      AND Consecutivo_Unico <> '';
END
GO
