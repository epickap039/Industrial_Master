# Guía de Conexión Excel a SQL Server

Para que tus archivos Excel actuales consulten la base de datos directamente, usa el siguiente código VBA.

## Código VBA (Macro)

```vba
Sub ConsultarPieza()
    Dim conn As Object
    Dim rs As Object
    Dim sql As String
    Dim codigo As String
    
    codigo = Range("A2").Value 'Asumiendo que el código está en A2
    
    Set conn = CreateObject("ADODB.Connection")
    conn.Open "Driver={SQL Server};Server=localhost\SQLEXPRESS;Database=DB_Materiales_Industrial;Trusted_Connection=yes;"
    
    sql = "SELECT Descripcion, Material, Proceso_Primario FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = '" & codigo & "'"
    
    Set rs = conn.Execute(sql)
    
    If Not rs.EOF Then
        Range("B2").Value = rs.Fields(0).Value 'Descripcion
        Range("C2").Value = rs.Fields(1).Value 'Material
    Else
        MsgBox "Pieza no encontrada en el Maestro", vbExclamation
    End If
    
    rs.Close
    conn.Close
End Sub
```

## Requisitos

- Tener instalada la base de datos en `localhost\SQLEXPRESS`.
- Habilitar la referencia "Microsoft ActiveX Data Objects 6.1 Library" en el editor de VBA.
