/* ============================================================================
   MIGRACION v15.5 - Perfil de usuario + Consecutivo único de Ayudas Visuales
   SQL Server (dbo)
   ============================================================================ */

/* ------------------------------
   1) Tbl_Usuarios: género + avatar
   ------------------------------ */
IF COL_LENGTH('dbo.Tbl_Usuarios', 'genero') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Usuarios
    ADD genero NVARCHAR(20) NOT NULL
        CONSTRAINT DF_Tbl_Usuarios_genero DEFAULT('N');
END
GO

IF COL_LENGTH('dbo.Tbl_Usuarios', 'avatar_base64') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Usuarios
    ADD avatar_base64 NVARCHAR(MAX) NULL;
END
GO

/* ------------------------------
   1.1) Tbl_Ayudas_Categorias: icono PNG opcional
   ------------------------------ */
IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Icono_Png_Base64') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Ayudas_Categorias
    ADD Icono_Png_Base64 NVARCHAR(MAX) NULL;
END
GO

/* ------------------------------
   2) Tbl_Ayudas_Revisiones: consecutivo único
   ------------------------------ */
IF COL_LENGTH('dbo.Tbl_Ayudas_Revisiones', 'Consecutivo_Unico') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Ayudas_Revisiones
    ADD Consecutivo_Unico NVARCHAR(80) NULL;
END
GO

/* Backfill inicial usando Numero_Revision donde esté vacío */
UPDATE r
SET r.Consecutivo_Unico = UPPER(REPLACE(LTRIM(RTRIM(r.Numero_Revision)), ' ', ''))
FROM dbo.Tbl_Ayudas_Revisiones r
WHERE (r.Consecutivo_Unico IS NULL OR LTRIM(RTRIM(r.Consecutivo_Unico)) = '')
  AND r.Numero_Revision IS NOT NULL
  AND LTRIM(RTRIM(r.Numero_Revision)) <> '';
GO

/* Índice único filtrado (solo valores no nulos/no vacíos) */
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

