# Manual del Módulo Árbitro (v3.2)

El módulo **Árbitro de Conflictos** es el componente de inteligencia de decisiones de Industrial Master. Su función es resolver discrepancias de datos cuando múltiples fuentes (Excels) reclaman verdades diferentes para un mismo código de pieza.

## ¿Cómo funciona el Arbitraje?

1. **Detección Automatizada:** El sistema compara cada nueva importación contra el **Catálogo Maestro**. Si detecta que un archivo indica un Material o Proceso diferente, lo marca como "Conflicto".
2. **Botón Resolver Conflicto:** Al hacer clic en la App, se abre una ventana de comparación profesional.
3. **Contraste de Datos:**
   - **Lado Izquierdo:** Muestra la "Verdad Actual" en el maestro.
   - **Lado Derecho:** Muestra los "Candidatos" (los datos tal cual vienen en los archivos Excel conflictivos).
4. **Elección Humana:** El usuario revisa cuál de las versiones es la correcta y presiona **"Aplicar este Valor"**.
5. **Impacto:** Al aplicar un valor, el Catálogo Maestro se actualiza instantáneamente con los nuevos datos validados y la alerta desaparece.

## Reglas de Oro del Árbitro

- El sistema **nunca** sobrescribe el maestro automáticamente si hay duda.
- La decisión final siempre es del usuario (Ingeniero de Datos).
- Se recomienda usar el Arbitraje después de cada carga masiva de archivos.
