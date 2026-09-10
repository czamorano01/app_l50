# Pipeline ETL local — Talla de Madurez (L50) de Pejegallo

Pipeline ETL en **R**, pensado para correr localmente desde **VS Code**
(o RStudio), que ingesta datos biométricos de pejegallo
(*Callorhynchus callorynchus*, hojas "Machos" y "Hembras" del dataset
original), los transforma aplicando criterios explícitos de calidad
de datos, y deja el resultado curado en archivos CSV versionados en
el propio repositorio. El dashboard de **Streamlit** lee esos CSV
directamente — no depende de ninguna base de datos ni credencial en
la nube.

**Stack**: R 4.3 (dplyr, readxl) · CSV versionado en git · Streamlit
(local o Streamlit Community Cloud).

**Variables excluidas por decisión del equipo**: `Gonad Weight` y
cualquier índice hepatosomático no se leen ni se cargan en ninguna
etapa.

> Este proyecto tuvo una primera versión con Azure Blob Storage +
> Azure PostgreSQL + GitHub Actions. Esos archivos se conservan, sin
> mantenimiento, en `legacy_azure_version/` solo como referencia — el
> pipeline activo es el local descrito aquí.

---

## 1. Arquitectura

```
[Archivo fuente local .xlsx: hojas Machos + Hembras]
        │
        │  R/etl_local.R  (VS Code / RStudio, ejecución manual)
        │  - lee ambas hojas
        │  - aplica reglas de calidad de datos (dplyr)
        │  - calcula métricas derivadas
        ▼
 data/processed/
   ├── especimenes_curado.csv     (limpio + métricas derivadas)
   └── log_calidad_datos.csv      (auditoría de reglas de calidad)
        │
        │  git commit + push
        ▼
 dashboard/streamlit_app.py  ── lee los CSV directamente
        │
        ▼
 Streamlit (local: `streamlit run`, o desplegado en Streamlit
 Community Cloud) — incluye curvas sigmoideas de madurez y L50
```

No hay orquestación en la nube: como el dataset fuente es un archivo
estático, la automatización consiste en volver a correr el ETL cada
vez que cambie el archivo fuente, y subir los CSV resultantes.

---

## 2. Requisitos previos

- R 4.3+ y VS Code con la extensión de R (o RStudio)
- Python 3.10+ (solo para correr el dashboard localmente)
- Cuenta gratuita en [streamlit.io](https://streamlit.io) si quieres
  desplegar el dashboard en la nube

---

## 3. Ejecutar el ETL localmente (VS Code)

```bash
# 1. Instalar dependencias de R (una sola vez)
Rscript R/install_packages.R

# 2. Verificar que el archivo fuente esté en data/raw/
ls data/raw/pejegallo_L50_2024.xlsx

# 3. Correr el ETL
Rscript R/etl_local.R
```

En Windows, si Git Bash no reconoce `Rscript` después de instalar R,
cierra y vuelve a abrir la terminal de VS Code. Como alternativa,
ejecuta el ETL con la ruta completa:

```bash
"/c/Program Files/R/R-4.6.1/bin/Rscript.exe" R/etl_local.R
```

Esto genera/actualiza:
- `data/processed/especimenes_curado.csv`
- `data/processed/log_calidad_datos.csv`

`etl_local.R` imprime en consola un resumen (N° de especímenes
válidos por sexo) y deja registrado, en el log de calidad, cuántos
registros fueron descartados, imputados o conservados en cada regla.

---

## 4. Ejecutar el dashboard localmente

```bash
pip install -r dashboard/requirements.txt
streamlit run dashboard/streamlit_app.py
```

El dashboard lee `data/processed/especimenes_curado.csv` de forma
relativa a la raíz del repositorio — no necesita ningún secreto ni
variable de entorno.

### Curvas sigmoideas de L50

El dashboard ajusta, por sexo, una regresión logística de madurez
(inmaduro=0 / maduro=1) en función de la longitud:

```
p(L) = 1 / (1 + exp(-k · (L - L50)))
```

`L50` es la longitud a la que la probabilidad de estar maduro es 50%.
El ajuste se hace por máxima verosimilitud (`scipy.optimize`) y el
intervalo de confianza de `L50` se estima por bootstrap (remuestreo
con reemplazo, 100 iteraciones). Desde la barra lateral se puede
elegir si la curva se ajusta con **longitud total** o **longitud
precaudal**.

---

## 5. Desplegar el dashboard en Streamlit Community Cloud

1. Sube este repositorio a GitHub (incluyendo
   `data/processed/*.csv` — son livianos y es lo único que el
   dashboard necesita).
2. Ve a [share.streamlit.io](https://share.streamlit.io) → *New app*.
3. Selecciona el repo, la rama, y el archivo principal:
   `dashboard/streamlit_app.py`.
4. Deploy. No se necesita configurar *Secrets*: todo el dato vive en
   el CSV versionado.

Cada vez que quieras actualizar el dashboard con datos nuevos:
`Rscript R/etl_local.R` → revisar los CSV → `git commit` + `git push`.
Streamlit Community Cloud redespliega automáticamente al detectar el
push.

---

## 6. Calidad de datos

Reglas aplicadas en `R/etl_local.R` (documentadas también en el
código, con conteos exactos):

| Regla | Columna | Acción |
|---|---|---|
| Filas ajenas a especímenes (residuo de tabla de frecuencias pegada) | Collection Code | Descartado |
| Centinelas `-` / `?` / vacío → NA | Total Weight | Conservado |
| Centinelas `-` / `?` / vacío → NA | Liver Weight | Conservado |
| PreCaudal Length faltante | PreCaudal Length | Conservado (NA) |
| Peso biológicamente imposible (somático neto < 0 o Fulton K > 3) | Total Weight | Imputado (NA) |
| Variables excluidas por decisión del equipo | Gonad Weight / índice hepatosomático | Excluido |

---

## 7. Estructura del repositorio

```
pejegallo-pipeline/
├── data/
│   ├── raw/
│   │   └── pejegallo_L50_2024.xlsx   # archivo fuente original
│   └── processed/
│       ├── especimenes_curado.csv    # generado por etl_local.R
│       └── log_calidad_datos.csv     # generado por etl_local.R
├── R/
│   ├── etl_local.R                   # ingesta + transformación (todo en uno)
│   └── install_packages.R
├── dashboard/
│   ├── streamlit_app.py              # dashboard (incluye curvas L50)
│   └── requirements.txt
├── legacy_azure_version/             # versión anterior (Azure + GitHub Actions), solo de referencia
└── README.md
```
