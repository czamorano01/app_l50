#' etl_local.R
#' ===========
#' Pipeline ETL LOCAL - Talla de madurez Pejegallo (L50).
#'
#' Pensado para ejecutarse manualmente en VS Code / RStudio (Rscript
#' R/etl_local.R desde la raíz del proyecto). Reemplaza la versión
#' anterior basada en Azure Blob Storage + Azure PostgreSQL + GitHub
#' Actions (esos archivos quedan archivados en legacy_azure_version/
#' solo como referencia).
#'
#' Qué hace:
#'   1. INGESTA: lee el archivo fuente local (.xlsx), hojas "Machos"
#'      y "Hembras".
#'   2. TRANSFORMACIÓN: aplica las mismas reglas explícitas de calidad
#'      de datos documentadas en el informe (ver detalle regla por
#'      regla más abajo), y calcula las métricas derivadas.
#'   3. CARGA: escribe el resultado curado y el log de calidad como
#'      archivos locales en data/processed/ (CSV, consumidos
#'      directamente por el dashboard de Streamlit — sin base de
#'      datos externa).
#'
#' Cómo se automatiza:
#'   No hay orquestación en la nube: el dataset fuente es un archivo
#'   estático, así que basta con volver a correr este script cada vez
#'   que el archivo fuente cambie, y luego hacer commit + push de los
#'   CSV resultantes en data/processed/ para que el dashboard
#'   desplegado en Streamlit Community Cloud los sirva actualizados.
#'
#' Reglas de calidad de datos aplicadas (con conteos exactos obtenidos
#' al perfilar el dataset original):
#'
#'   1. Filas que NO son especímenes (residuo de una tabla de
#'      frecuencias/histograma pegada por error en el mismo rango de
#'      columnas de las hojas "Machos" y "Hembras"):
#'        -> Se DESCARTAN. Se identifican porque `Collection Code` es
#'           distinto de "CCM" (el único código válido de colecta).
#'        -> Justificación: no son errores de medición, son un
#'           artefacto de la hoja de cálculo, por lo que no
#'           corresponde imputarlos.
#'
#'   2. Total Weight / Liver Weight con valores centinela "-" o "?"
#'      (que representan "no medido" en la planilla original), o
#'      vacíos:
#'        -> Se CONVIERTEN a NA. Se CONSERVA la fila completa, ya que
#'           el resto de las variables (longitud, madurez, sexo)
#'           siguen siendo válidas y útiles para otras métricas.
#'
#'   3. PreCaudal Length faltante:
#'        -> Se CONSERVA como NA. Solo impacta la métrica de
#'           proporción morfométrica para esas filas.
#'
#'   4. Normalización de fechas: `Collection Date` se parsea a tipo
#'      Date (formato mm/dd/yyyy del dataset original -> ISO).
#'
#'   5. Valores de `Total Weight` biológicamente imposibles: se
#'      detectan con dos criterios (a) el peso neto somático
#'      (peso_total - peso_higado) resulta NEGATIVO; (b) el Factor de
#'      Condición de Fulton resulta > 3, muy por fuera del rango
#'      típico de la especie (~0.3 a 1.2).
#'        -> Se IMPUTAN como NA (no se descarta la fila completa, ya
#'           que longitud/madurez/sexo siguen siendo válidos).
#'
#'   6. Variable `Gonad Weight` y cualquier índice hepatosomático se
#'      EXCLUYEN completamente del pipeline, por decisión explícita
#'      del equipo (no se leen ni se cargan).

user_library <- file.path(path.expand("~"), "R", paste0("win-library-", getRversion()[1, 1]))
if (dir.exists(user_library)) {
  .libPaths(c(user_library, .libPaths()))
}

library(dplyr)
library(readxl)
library(lubridate)
library(stringr)

LOCAL_SOURCE_FILE <- Sys.getenv("LOCAL_SOURCE_FILE", "data/raw/pejegallo_L50_2024.xlsx")
OUTPUT_DIR        <- "data/processed"

RAW_COLS <- c(
  "Collection Code", "Collection No.", "Collection Date [mm/dd/yyyy]",
  "Sex [\"male\", \"female\" or \"?\"]", "Maturity",
  "Total Length [in cm]", "PreCaudal Length [in cm]",
  "Total Weight (gr)", "Liver Weight (gr)"
)

#' Lee una hoja (Machos o Hembras) del archivo Excel local y retorna
#' solo las columnas de interés, sin filtrar todavía.
read_sheet_raw <- function(filepath, sheet_name) {
  df <- read_excel(filepath, sheet = sheet_name, skip = 3, .name_repair = "minimal")
  present <- intersect(RAW_COLS, colnames(df))
  df <- df[, present]
  df <- df[rowSums(!is.na(df)) > 0, ]  # descarta filas 100% vacías (padding)
  df
}

#' Convierte un valor centinela ("-", "?", vacío) a NA; deja el resto tal cual.
clean_sentinel <- function(x) {
  x_chr <- as.character(x)
  x_chr <- str_trim(x_chr)
  ifelse(x_chr %in% c("-", "?", "", "NA"), NA, x)
}

run_etl <- function(filepath = LOCAL_SOURCE_FILE, run_id = NULL) {
  if (is.null(run_id)) {
    run_id <- format(Sys.time(), "%Y%m%dT%H%M%S")
  }
  if (!file.exists(filepath)) {
    stop(sprintf(
      "No se encontro el archivo fuente: %s\n Copia pejegallo_L50_2024.xlsx en data/raw/ antes de correr el ETL.",
      filepath
    ))
  }

  quality_log <- list()

  message("Leyendo hojas 'Machos' y 'Hembras' desde ", filepath, " ...")
  machos_raw  <- read_sheet_raw(filepath, "Machos")
  hembras_raw <- read_sheet_raw(filepath, "Hembras")

  n_machos_raw  <- nrow(machos_raw)
  n_hembras_raw <- nrow(hembras_raw)

  # --- 1. Filtrar solo especímenes reales (Collection Code == "CCM") ---
  machos_valid  <- machos_raw  %>% filter(`Collection Code` == "CCM")
  hembras_valid <- hembras_raw %>% filter(`Collection Code` == "CCM")

  n_machos_desc  <- n_machos_raw  - nrow(machos_valid)
  n_hembras_desc <- n_hembras_raw - nrow(hembras_valid)

  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "descarte_filas_no_especimen_machos",
    columna = "Collection Code", registros_afectados = n_machos_desc,
    accion_tomada = "descartado",
    detalle = "Residuo de tabla de frecuencias pegada en el rango de datos"
  )
  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "descarte_filas_no_especimen_hembras",
    columna = "Collection Code", registros_afectados = n_hembras_desc,
    accion_tomada = "descartado",
    detalle = "Residuo de tabla de frecuencias pegada en el rango de datos"
  )

  # --- 2. Unificar Machos + Hembras con etiqueta de sexo explícita ---
  machos_valid$sexo_hoja_origen  <- "Machos"
  hembras_valid$sexo_hoja_origen <- "Hembras"
  df <- bind_rows(machos_valid, hembras_valid)

  # --- 3. Limpiar centinelas en columnas de peso ---
  n_peso_total_afectado  <- sum(is.na(clean_sentinel(df$`Total Weight (gr)`)))
  n_peso_higado_afectado <- sum(is.na(clean_sentinel(df$`Liver Weight (gr)`)))

  df$total_weight_gr <- as.numeric(clean_sentinel(df$`Total Weight (gr)`))
  df$liver_weight_gr <- as.numeric(clean_sentinel(df$`Liver Weight (gr)`))

  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "limpieza_centinela_peso_total",
    columna = "Total Weight (gr)", registros_afectados = n_peso_total_afectado,
    accion_tomada = "conservado",
    detalle = "'-' / '?' / vacío -> NA; fila se conserva"
  )
  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "limpieza_centinela_peso_higado",
    columna = "Liver Weight (gr)", registros_afectados = n_peso_higado_afectado,
    accion_tomada = "conservado",
    detalle = "'-' / '?' / vacío -> NA; fila se conserva"
  )

  # --- 4. Longitudes y PreCaudal ---
  df$total_length_cm     <- as.numeric(clean_sentinel(df$`Total Length [in cm]`))
  df$precaudal_length_cm <- as.numeric(clean_sentinel(df$`PreCaudal Length [in cm]`))

  n_precaudal_na <- sum(is.na(df$precaudal_length_cm))
  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "conservar_na_precaudal",
    columna = "PreCaudal Length [in cm]", registros_afectados = n_precaudal_na,
    accion_tomada = "conservado",
    detalle = "Se mantiene NA; solo afecta proporcion_morfometrica"
  )

  # --- 5. Fecha ---
  df$collection_date <- suppressWarnings(mdy(df$`Collection Date [mm/dd/yyyy]`))

  # --- 6. Normalización de texto ---
  df$maturity <- str_to_lower(str_trim(as.character(df$Maturity)))
  df$sexo <- ifelse(df$sexo_hoja_origen == "Machos", "male", "female")

  # --- 7. Métricas derivadas provisionales (para detectar imposibilidades) ---
  fulton_prov <- ifelse(
    !is.na(df$total_weight_gr) & !is.na(df$total_length_cm) & df$total_length_cm > 0,
    100 * df$total_weight_gr / (df$total_length_cm ^ 3), NA
  )
  somatico_prov <- ifelse(
    !is.na(df$total_weight_gr) & !is.na(df$liver_weight_gr),
    df$total_weight_gr - df$liver_weight_gr, NA
  )

  peso_erroneo_mask <- (!is.na(somatico_prov) & somatico_prov < 0) |
                        (!is.na(fulton_prov) & fulton_prov > 3)
  n_peso_erroneo <- sum(peso_erroneo_mask)

  df$total_weight_gr[peso_erroneo_mask] <- NA

  quality_log[[length(quality_log) + 1]] <- list(
    run_id = run_id, regla = "peso_total_biologicamente_imposible",
    columna = "Total Weight (gr)", registros_afectados = n_peso_erroneo,
    accion_tomada = "imputado",
    detalle = "Peso somatico neto negativo o Fulton K > 3 -> Total Weight puesto a NA"
  )

  # --- 8. Métricas derivadas finales ---
  df$factor_condicion_fulton <- ifelse(
    !is.na(df$total_weight_gr) & !is.na(df$total_length_cm) & df$total_length_cm > 0,
    100 * df$total_weight_gr / (df$total_length_cm ^ 3), NA
  )
  df$proporcion_morfometrica <- ifelse(
    !is.na(df$precaudal_length_cm) & !is.na(df$total_length_cm) & df$total_length_cm > 0,
    df$precaudal_length_cm / df$total_length_cm, NA
  )
  df$peso_somatico_neto_gr <- ifelse(
    !is.na(df$total_weight_gr) & !is.na(df$liver_weight_gr),
    df$total_weight_gr - df$liver_weight_gr, NA
  )

  # --- 9. Selección final de columnas ---
  df_final <- df %>%
    transmute(
      sexo, collection_code = `Collection Code`,
      collection_no = as.character(`Collection No.`),
      collection_date, maturity,
      total_length_cm, precaudal_length_cm,
      total_weight_gr, liver_weight_gr,
      factor_condicion_fulton, proporcion_morfometrica, peso_somatico_neto_gr,
      fuente_run_id = run_id
    )

  quality_log_df <- bind_rows(lapply(quality_log, as.data.frame))
  quality_log_df$ejecutado_en <- Sys.time()

  dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)
  write.csv(df_final, file.path(OUTPUT_DIR, "especimenes_curado.csv"), row.names = FALSE)
  write.csv(quality_log_df, file.path(OUTPUT_DIR, "log_calidad_datos.csv"), row.names = FALSE)

  message(sprintf(
    "ETL local completo: %d especimenes validos (%d machos, %d hembras).",
    nrow(df_final), sum(df_final$sexo == "male"), sum(df_final$sexo == "female")
  ))
  message(sprintf("Escrito en: %s/especimenes_curado.csv y log_calidad_datos.csv", OUTPUT_DIR))
  message("Ahora haz commit + push de data/processed/ para que Streamlit sirva los datos actualizados.")

  invisible(list(data = df_final, quality_log = quality_log_df))
}

if (sys.nframe() == 0) {
  run_etl()
}
