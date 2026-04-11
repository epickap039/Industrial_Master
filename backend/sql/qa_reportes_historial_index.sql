/*
  Centro QA - Historial Cerrado/Rechazado
  Opcional pero recomendado para acelerar:
  - /api/reportes            (Estado = Abierto ORDER BY Fecha_Hora DESC)
  - /api/reportes/historial  (Estado IN Cerrado/Rechazado ORDER BY Fecha_Hora DESC)
*/

IF NOT EXISTS (
  SELECT 1
  FROM sys.indexes
  WHERE name = 'IX_Tbl_Reportes_Beta_Estado_Fecha'
    AND object_id = OBJECT_ID('dbo.Tbl_Reportes_Beta')
)
BEGIN
  CREATE NONCLUSTERED INDEX IX_Tbl_Reportes_Beta_Estado_Fecha
  ON dbo.Tbl_Reportes_Beta (Estado ASC, Fecha_Hora DESC)
  INCLUDE (Usuario, Modulo, Gravedad);
END
GO
