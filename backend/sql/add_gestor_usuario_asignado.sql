-- Opcional: columna para el responsable asignado desde el Radar (Quest Briefing).
-- El API mapea el JSON `usuario_asignado` a Usuario_Asignado (o variantes en gestor_tareas.py).

IF NOT EXISTS (
    SELECT 1
    FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.Tbl_Gestor_Tareas')
      AND name = N'Usuario_Asignado'
)
BEGIN
    ALTER TABLE dbo.Tbl_Gestor_Tareas ADD Usuario_Asignado NVARCHAR(200) NULL;
END
GO
