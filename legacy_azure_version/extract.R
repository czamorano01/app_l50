#' extract.R
#' =========
#' Etapa de INGESTA del pipeline ETL - Talla de madurez Pejegallo (L50).
#'
#' Qué hace:
#'   1. Calcula el hash SHA-256 del archivo fuente local (.xlsx).
#'   2. Compara contra el último hash registrado en un manifest.json
#'      guardado en Azure Blob Storage.
#'   3. Si cambió (o es la primera corrida), sube una copia versionada
#'      a la zona "raw" del contenedor y actualiza el manifest.
#'   4. Si no cambió, no hace nada (idempotencia), y GitHub Actions
#'      puede saltarse transform/load ese día.
#'
#' Cómo se automatiza:
#'   Este script lo ejecuta un workflow de GitHub Actions programado con
#'   cron (ver .github/workflows/etl_pejegallo.yml). El dataset original
#'   es un archivo estático, así que la automatización real es: revisar
#'   diariamente si hay una versión nueva del archivo en el origen y
#'   versionarla/cargarla a Azure sin intervención humana si corresponde.

library(AzureStor)
library(digest)
library(jsonlite)

CONTAINER_NAME     <- Sys.getenv("AZURE_CONTAINER_NAME", "pejegallo-etl")
STORAGE_ACCOUNT    <- Sys.getenv("AZURE_STORAGE_ACCOUNT")
STORAGE_KEY        <- Sys.getenv("AZURE_STORAGE_KEY")
RAW_PREFIX         <- "raw/pejegallo"
MANIFEST_BLOB      <- file.path(RAW_PREFIX, "manifest.json")
LOCAL_SOURCE_FILE  <- Sys.getenv("LOCAL_SOURCE_FILE", "data/raw/pejegallo_L50_2024.xlsx")

get_container <- function() {
  endpoint <- storage_endpoint(
    sprintf("https://%s.blob.core.windows.net", STORAGE_ACCOUNT),
    key = STORAGE_KEY
  )
  storage_container(endpoint, CONTAINER_NAME)
}

compute_file_hash <- function(filepath) {
  digest(file = filepath, algo = "sha256")
}

read_manifest <- function(cont) {
  tryCatch({
    tmp <- tempfile(fileext = ".json")
    storage_download(cont, MANIFEST_BLOB, tmp, overwrite = TRUE)
    fromJSON(tmp)
  }, error = function(e) {
    message("No existe manifest previo; se asume primera ejecución.")
    list()
  })
}

write_manifest <- function(cont, manifest) {
  tmp <- tempfile(fileext = ".json")
  write(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), tmp)
  storage_upload(cont, tmp, MANIFEST_BLOB)
}

extract <- function(run_id = NULL) {
  if (is.null(run_id)) {
    run_id <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
  }

  if (!file.exists(LOCAL_SOURCE_FILE)) {
    stop(sprintf("No se encontró el archivo fuente: %s", LOCAL_SOURCE_FILE))
  }

  current_hash <- compute_file_hash(LOCAL_SOURCE_FILE)
  message(sprintf("Hash SHA-256 del archivo fuente: %s", current_hash))

  cont <- get_container()
  manifest <- read_manifest(cont)
  last_hash <- manifest$last_hash

  if (!is.null(last_hash) && identical(current_hash, last_hash)) {
    message("El archivo fuente no ha cambiado desde la última ejecución. No se re-ingesta.")
    return(list(changed = FALSE, blob_path = manifest$last_blob_path, run_id = run_id))
  }

  dest_blob <- file.path(RAW_PREFIX, paste0(run_id, "_pejegallo_L50_2024.xlsx"))
  message(sprintf("Cambio detectado. Subiendo a %s/%s", CONTAINER_NAME, dest_blob))
  storage_upload(cont, LOCAL_SOURCE_FILE, dest_blob)

  manifest$last_hash <- current_hash
  manifest$last_blob_path <- dest_blob
  manifest$last_run_id <- run_id
  manifest$last_updated <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  write_manifest(cont, manifest)
  message("Ingesta completada y manifest actualizado.")

  list(changed = TRUE, blob_path = dest_blob, run_id = run_id)
}

if (sys.nframe() == 0) {
  result <- extract()
  cat(toJSON(result, auto_unbox = TRUE, pretty = TRUE))
}
