/*
  Tabla puente para asignación multiusuario compartida en misiones del Centro.
  Mantiene una sola misión/progreso y varios usuarios asignados.
*/

IF OBJECT_ID('dbo.Tbl_Gestor_Tarea_Asignados', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tbl_Gestor_Tarea_Asignados (
        ID_Asignado INT IDENTITY(1,1) PRIMARY KEY,
        ID_Tarea INT NOT NULL,
        Usuario NVARCHAR(200) NOT NULL,
        Fecha_Asignacion DATETIME2(0) NOT NULL CONSTRAINT DF_Tbl_Gestor_Tarea_Asignados_Fecha DEFAULT (SYSUTCDATETIME())
    );

    ALTER TABLE dbo.Tbl_Gestor_Tarea_Asignados
    ADD CONSTRAINT FK_Tbl_Gestor_Tarea_Asignados_Tarea
        FOREIGN KEY (ID_Tarea) REFERENCES dbo.Tbl_Gestor_Tareas(ID_Tarea) ON DELETE CASCADE;

    CREATE UNIQUE INDEX UX_Tbl_Gestor_Tarea_Asignados_TareaUsuario
        ON dbo.Tbl_Gestor_Tarea_Asignados (ID_Tarea, Usuario);
END
GO
