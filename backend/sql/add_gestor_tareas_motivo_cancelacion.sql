-- Motivo de cancelación para misiones del Centro de Monitoreo (Andon).

IF COL_LENGTH('dbo.Tbl_Gestor_Tareas', 'Motivo_Cancelacion') IS NULL
BEGIN
    ALTER TABLE dbo.Tbl_Gestor_Tareas ADD Motivo_Cancelacion NVARCHAR(MAX) NULL;
END
GO
