Attribute VB_Name = "ExportBOMIndustrialManager"
' ==============================================================================
' Exportación BOM para Industrial Manager — SolidWorks 2025
'
' Ejecutar: ExportarBOM_IndustrialManager
'   1) Elige el ensamble (.sldasm) a analizar
'   2) Elige la carpeta donde guardar el CSV
'
' Requiere referencia: biblioteca de tipos de SolidWorks (VBA > Herramientas > Referencias).
'
' CSV (delimitador ;, UTF-8):
'   codigo;cantidad;ruta_subensambles;suprimido;archivo_completo;configuracion
' ==============================================================================

Option Explicit

Private Const DELIM As String = ";"

Private outLines As Collection

' Único punto de entrada: selector de ensamble + carpeta de salida.
Public Sub ExportarBOM_IndustrialManager()
    Dim swApp As SldWorks.SldWorks
    Dim swModel As SldWorks.ModelDoc2
    Dim swAssy As SldWorks.AssemblyDoc
    Dim assemblyPath As String
    Dim folderPath As String
    Dim fileName As String
    Dim errors As Long, warnings As Long

    Set swApp = Application.SldWorks

    assemblyPath = swApp.GetOpenFileName2( _
        "Selecciona el ensamble raíz a analizar", "", _
        "SolidWorks Assemblies (*.sldasm)|*.sldasm", 0, "", "", "")
    If assemblyPath = "" Then Exit Sub

    Dim shellApp As Object
    Dim folderItem As Object
    Set shellApp = CreateObject("Shell.Application")
    Set folderItem = shellApp.BrowseForFolder(0, "Carpeta de destino del CSV", 0)
    If folderItem Is Nothing Then Exit Sub
    folderPath = folderItem.self.Path
    If Right$(folderPath, 1) <> "\" Then folderPath = folderPath & "\"

    Set swModel = swApp.OpenDoc6(assemblyPath, swDocASSEMBLY, swOpenDocOptions_Silent, "", errors, warnings)
    If swModel Is Nothing Then
        MsgBox "No se pudo abrir el ensamble.", vbCritical
        Exit Sub
    End If

    Set swAssy = swModel
    Set outLines = New Collection
    outLines.Add JoinHeader

    Dim vComps As Variant
    vComps = swAssy.GetComponents(True)
    If Not IsArray(vComps) Then
        MsgBox "Sin componentes de primer nivel en el ensamble.", vbInformation
        Exit Sub
    End If

    Dim i As Long
    For i = LBound(vComps) To UBound(vComps)
        ProcessComponent vComps(i), 1#, ""
    Next i

    fileName = folderPath & "SW_BOM_" & Format$(Now, "yyyymmdd_hhnnss") & ".csv"
    WriteUtf8Csv fileName, outLines
    MsgBox "Exportación completada." & vbCrLf & fileName, vbInformation
End Sub

Private Function JoinHeader() As String
    JoinHeader = "codigo" & DELIM & "cantidad" & DELIM & _
        "ruta_subensambles" & DELIM & "suprimido" & DELIM & "archivo_completo" & DELIM & _
        "configuracion"
End Function

Private Sub ProcessComponent(ByVal swComp As SldWorks.Component2, ByVal parentQty As Double, ByVal pathStack As String)
    If swComp Is Nothing Then Exit Sub

    Dim suppressed As Boolean
    suppressed = swComp.IsSuppressed()

    Dim q As Long
    q = 1
    On Error Resume Next
    q = swComp.Quantity
    If Err.Number <> 0 Then q = 1: Err.Clear
    On Error GoTo 0
    If q < 1 Then q = 1

    Dim effQty As Double
    effQty = parentQty * CDbl(q)

    Dim cfgName As String
    cfgName = CStr(swComp.ReferencedConfiguration)

    Dim fullPath As String
    fullPath = swComp.GetPathName
    Dim fname As String
    fname = FileNameFromPath(fullPath)
    Dim stem As String
    stem = StemFromFile(fname)

    If stem <> "" Then
        outLines.Add stem & DELIM & FormatQty(effQty) & DELIM & _
            CsvEscape(pathStack) & DELIM & IIf(suppressed, "1", "0") & DELIM & CsvEscape(fname) & DELIM & _
            CsvEscape(Trim$(cfgName))
    End If

    Dim childPath As String
    childPath = pathStack
    If stem <> "" Then
        If Len(childPath) = 0 Then
            childPath = stem
        Else
            childPath = childPath & "|" & stem
        End If
    End If

    Dim vKids As Variant
    vKids = swComp.GetChildren
    If Not IsArray(vKids) Then Exit Sub
    Dim j As Long
    For j = LBound(vKids) To UBound(vKids)
        ProcessComponent vKids(j), effQty, childPath
    Next j
End Sub

Private Function FileNameFromPath(ByVal fullPath As String) As String
    Dim i As Long
    i = InStrRev(fullPath, "\")
    If i > 0 Then
        FileNameFromPath = Mid$(fullPath, i + 1)
    Else
        FileNameFromPath = fullPath
    End If
End Function

Private Function StemFromFile(ByVal fname As String) As String
    Dim i As Long
    i = InStrRev(fname, ".")
    If i > 0 Then
        StemFromFile = Left$(fname, i - 1)
    Else
        StemFromFile = fname
    End If
End Function

Private Function FormatQty(ByVal q As Double) As String
    FormatQty = Replace(Format$(q, "0.####"), ",", ".")
End Function

Private Function CsvEscape(ByVal s As String) As String
    CsvEscape = Replace(s, DELIM, " ")
End Function

Private Sub WriteUtf8Csv(ByVal pathOut As String, ByVal lines As Collection)
    Dim stm As Object
    Set stm = CreateObject("ADODB.Stream")
    stm.Type = 2
    stm.Mode = 3
    stm.Charset = "UTF-8"
    stm.Open
    Dim i As Long
    For i = 1 To lines.Count
        stm.WriteText CStr(lines(i)), 1
    Next i
    stm.SaveToFile pathOut, 2
    stm.Close
End Sub
