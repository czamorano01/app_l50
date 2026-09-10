#' load.R
#' ======
#' Etapa de CARGA del pipeline ETL - Talla de madurez Pejegallo (L50).
#'
#' Qué hace:
#'   1. Se conecta a Azure Database for PostgreSQL (Flexible Server,
#'      Free Tier) usando DBI/RPostgres.
#'   2. Inserta el registro crudo en `pejegallo.staging_especimenes`.
#'   3. Hace UPSERT en `pejegallo.especimenes_curado` usando la llave
#'      compuesta (sexo, collection_no, collection_date).
#'   4. Inserta el log de calidad de datos.
#'   5. Verifica integridad: compara filas de entrada vs. filas totales
#'      en la tabla curada.

library(DBI)
library(RPostgres)
library(dplyr)

get_connection <- function() {
  host     <- Sys.getenv("AZURE_PG_HOST")
  port     <- as.integer(Sys.getenv("AZURE_PG_PORT", "5432"))
  dbname   <- Sys.getenv("AZURE_PG_DBNAME", "pejegallo_db")
  user     <- Sys.getenv("AZURE_PG_USER")
  password <- Sys.getenv("AZURE_PG_PASSWORD")

  if (host == "" || user == "" || password == "") {
    stop("Faltan variables de entorno AZURE_PG_HOST / AZURE_PG_USER / AZURE_PG_PASSWORD. Ver README.md.")
  }

  dbConnect(
    RPostgres::Postgres(),
    host = host, port = port, dbname = dbname,
    user = user, password = password,
    sslmode = "require"
  )
}

UPSERT_SQL <- "
  INSERT INTO pejegallo.especimenes_curado (
      sexo, collection_code, collection_no, collection_date, maturity,
      total_length_cm, precaudal_length_cm, total_weight_gr, liver_weight_gr,
      factor_condicion_fulton, proporcion_morfometrica, peso_somatico_neto_gr,
      fuente_run_id
  ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
  ON CONFLICT (sexo, collection_no, collection_date) DO UPDATE SET
      maturity = EXCLUDED.maturity,
      total_length_cm = EXCLUDED.total_length_cm,
      precaudal_length_cm = EXCLUDED.precaudal_length_cm,
      total_weight_gr = EXCLUDED.total_weight_gr,
      liver_weight_gr = EXCLUDED.liver_weight_gr,
      factor_condicion_fulton = EXCLUDED.factor_condicion_fulton,
      proporcion_morfometrica = EXCLUDED.proporcion_morfometrica,
      peso_somatico_neto_gr = EXCLUDED.peso_somatico_neto_gr,
      fuente_run_id = EXCLUDED.fuente_run_id,
      fecha_carga = NOW();
"

load_to_azure <- function(df, quality_log, run_id) {
  con <- get_connection()
  on.exit(dbDisconnect(con))

  rows_input <- nrow(df)

  dbBegin(con)
  tryCatch({
    # 1. Staging (crudo, trazabilidad)
    staging_df <- df %>%
      transmute(
        sexo_hoja_origen = ifelse(sexo == "male", "Machos", "Hembras"),
        collection_code, collection_no,
        collection_date = as.character(collection_date),
        sex = sexo, maturity,
        total_length_cm = as.character(total_length_cm),
        precaudal_length_cm = as.character(precaudal_length_cm),
        total_weight_gr = as.character(total_weight_gr),
        liver_weight_gr = as.character(liver_weight_gr),
        ingesta_run_id = run_id
      )
    dbWriteTable(con, DBI::Id(schema = "pejegallo", table = "staging_especimenes"),
                 staging_df, append = TRUE, row.names = FALSE)

    # 2. Upsert en tabla curada
    stmt <- dbSendQuery(con, UPSERT_SQL)
    for (i in seq_len(nrow(df))) {
      r <- df[i, ]
      dbBind(stmt, list(
        r$sexo, r$collection_code, r$collection_no, as.character(r$collection_date),
        r$maturity, r$total_length_cm, r$precaudal_length_cm, r$total_weight_gr,
        r$liver_weight_gr, r$factor_condicion_fulton, r$proporcion_morfometrica,
        r$peso_somatico_neto_gr, r$fuente_run_id
      ))
    }
    dbClearResult(stmt)

    # 3. Log de calidad
    for (entry in quality_log) {
      dbExecute(con, "
        INSERT INTO pejegallo.log_calidad_datos
            (run_id, regla, columna, registros_afectados, accion_tomada, detalle)
        VALUES ($1,$2,$3,$4,$5,$6)",
        params = list(entry$run_id, entry$regla, entry$columna,
                       entry$registros_afectados, entry$accion_tomada, entry$detalle))
    }

    dbCommit(con)
  }, error = function(e) {
    dbRollback(con)
    stop(e)
  })

  # 4. Verificación de integridad
  rows_total <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM pejegallo.especimenes_curado")$n

  message(sprintf(
    "Verificacion de integridad: %d filas de entrada -> %d filas totales en tabla curada.",
    rows_input, rows_total
  ))

  list(run_id = run_id, rows_input = rows_input, rows_total_curado = rows_total,
       integridad_ok = rows_total >= rows_input)
}

if (sys.nframe() == 0) {
  source("R/transform.R")
  args <- commandArgs(trailingOnly = TRUE)
  run_id <- if (length(args) > 0) args[1] else format(Sys.time(), "%Y%m%dT%H%M%S")
  result <- transform("data/raw/pejegallo_L50_2024.xlsx", run_id)
  out <- load_to_azure(result$data, result$quality_log, run_id)
  print(out)
  if (!out$integridad_ok) stop("Verificacion de integridad fallida.")
}
