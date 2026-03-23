-- =============================================================================
-- PURGA DE DATOS FANTASMA — Ingeniería / BOM transaccional
-- =============================================================================
-- Objetivo: vaciar listas de materiales, revisiones, versiones, tipos y logs
--           huérfanos acumulados por borrados lógicos antiguos.
--
-- NO MODIFICA (protegido):
--   - Tbl_Maestro_Piezas   (catálogo maestro único / piezas base)
--   - Tbl_Proyectos_Tracto (tractos del lobby)
--   - Tbl_Materiales_Aprobados, Tbl_Auditoria_Cambios, Tbl_Reportes_Beta, Tbl_Usuarios
--
-- ORDEN: hijos → padres (FKs típicas del proyecto; ver PROYECTO_WIKI.md).
--
-- Ejecutar en SSMS sobre la misma BD que el backend. Hacer BACKUP antes.
-- Para solo ver conteos, comenta los DELETE y ejecuta los SELECT previos.
-- =============================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

BEGIN TRY
    DECLARE @n INT;

    -- Diagnóstico previo (opcional)
    IF OBJECT_ID(N'dbo.Tbl_BOM_Estructura', N'U') IS NOT NULL
    BEGIN
        SELECT @n = COUNT(*) FROM dbo.Tbl_BOM_Estructura;
        PRINT CONCAT('ANTES: Tbl_BOM_Estructura filas = ', @n);
    END

    -- 1) Log de ingeniería (FK → revisión)
    IF OBJECT_ID(N'dbo.Tbl_Log_Cambios_Ingenieria', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Log_Cambios_Ingenieria;
        PRINT 'OK: Tbl_Log_Cambios_Ingenieria vaciada.';
    END

    -- 2) Líneas BOM
    IF OBJECT_ID(N'dbo.Tbl_BOM_Estructura', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_BOM_Estructura;
        PRINT 'OK: Tbl_BOM_Estructura vaciada.';
    END

    -- 3) Ensambles
    IF OBJECT_ID(N'dbo.Tbl_Ensambles', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Ensambles;
        PRINT 'OK: Tbl_Ensambles vaciada.';
    END

    -- 4) Estaciones de línea
    IF OBJECT_ID(N'dbo.Tbl_Estaciones', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Estaciones;
        PRINT 'OK: Tbl_Estaciones vaciada.';
    END

    -- 5) Unidades físicas ligadas a revisiones
    IF OBJECT_ID(N'dbo.Tbl_Unidades_Fisicas', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Unidades_Fisicas;
        PRINT 'OK: Tbl_Unidades_Fisicas vaciada.';
    END

    -- 6) Revisiones BOM
    IF OBJECT_ID(N'dbo.Tbl_BOM_Revisiones', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_BOM_Revisiones;
        PRINT 'OK: Tbl_BOM_Revisiones vaciada.';
    END

    -- 7) Clientes por versión
    IF OBJECT_ID(N'dbo.Tbl_Clientes_Configuracion', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Clientes_Configuracion;
        PRINT 'OK: Tbl_Clientes_Configuracion vaciada.';
    END

    -- 8) Versiones de ingeniería
    IF OBJECT_ID(N'dbo.Tbl_Versiones_Ingenieria', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Versiones_Ingenieria;
        PRINT 'OK: Tbl_Versiones_Ingenieria vaciada.';
    END

    -- 9) Tipos de proyecto (dependen de tracto; tracto NO se borra)
    IF OBJECT_ID(N'dbo.Tbl_Tipos_Proyecto', N'U') IS NOT NULL
    BEGIN
        DELETE FROM dbo.Tbl_Tipos_Proyecto;
        PRINT 'OK: Tbl_Tipos_Proyecto vaciada.';
    END

    IF OBJECT_ID(N'dbo.Tbl_BOM_Estructura', N'U') IS NOT NULL
    BEGIN
        SELECT @n = COUNT(*) FROM dbo.Tbl_BOM_Estructura;
        PRINT CONCAT('DESPUÉS: Tbl_BOM_Estructura filas = ', @n, ' (esperado 0).');
    END

    COMMIT TRANSACTION;
    PRINT 'PURGA FANTASMAS: COMMIT completado.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT CONCAT('ERROR: ', @msg);
    THROW;
END CATCH;
GO
