#' install_packages.R
#' ===================
#' Dependencias del ETL local (data/raw -> data/processed).
#' Ya no se necesitan AzureStor, digest, jsonlite, DBI ni RPostgres:
#' el pipeline corre 100% local y escribe CSV.

required_pkgs <- c("dplyr", "readxl", "lubridate", "stringr")

user_library <- file.path(path.expand("~"), "R", paste0("win-library-", getRversion()[1, 1]))
if (!dir.exists(user_library)) {
  dir.create(user_library, recursive = TRUE)
}
.libPaths(c(user_library, .libPaths()))

installed <- rownames(installed.packages())
missing <- setdiff(required_pkgs, installed)

if (length(missing) > 0) {
  message("Instalando paquetes faltantes: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("Todos los paquetes requeridos ya estan instalados.")
}
