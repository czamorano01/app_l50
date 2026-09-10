-- =========================================================
-- Esquema del repositorio analítico - Azure Database for
-- PostgreSQL Flexible Server (Free Tier)
-- Proyecto: Talla de madurez (L50) - Pejegallo (Callorhynchus callorynchus)
-- =========================================================

CREATE SCHEMA IF NOT EXISTS pejegallo;

-- Staging: carga cruda de Machos + Hembras, sin limpiar (trazabilidad)
CREATE TABLE IF NOT EXISTS pejegallo.staging_especimenes (
    id                   SERIAL PRIMARY KEY,
    sexo_hoja_origen     TEXT,          -- 'Machos' o 'Hembras', hoja de origen en el Excel
    collection_code      TEXT,
    collection_no        TEXT,
    collection_date      TEXT,
    sex                  TEXT,
    maturity             TEXT,
    total_length_cm      TEXT,
    precaudal_length_cm  TEXT,
    total_weight_gr      TEXT,
    liver_weight_gr      TEXT,
    ingesta_run_id        TEXT,
    ingesta_timestamp      TIMESTAMP DEFAULT NOW()
);

-- Curada: datos limpios, tipados, con métricas derivadas.
-- Nota: NO incluye Gonad Weight (excluido a petición del equipo) ni
-- ningún índice hepatosomático.
CREATE TABLE IF NOT EXISTS pejegallo.especimenes_curado (
    especimen_id            SERIAL PRIMARY KEY,
    sexo                      TEXT NOT NULL,             -- 'male' | 'female'
    collection_code            TEXT NOT NULL,             -- 'CCM' (único valor válido tras el filtro)
    collection_no                TEXT,
    collection_date                DATE,
    maturity                         TEXT NOT NULL,       -- 'mature' | 'inmature'
    total_length_cm                    DOUBLE PRECISION NOT NULL,
    precaudal_length_cm                  DOUBLE PRECISION,
    total_weight_gr                        DOUBLE PRECISION,   -- NULL si faltante/sentinela
    liver_weight_gr                          DOUBLE PRECISION, -- NULL si faltante/sentinela

    -- Métricas derivadas (Sección 3c del informe)
    factor_condicion_fulton                    DOUBLE PRECISION,  -- 100 * peso/longitud^3
    proporcion_morfometrica                       DOUBLE PRECISION, -- long_precaudal/long_total
    peso_somatico_neto_gr                           DOUBLE PRECISION, -- peso_total - peso_higado

    fuente_run_id                                     TEXT,
    fecha_carga                                          TIMESTAMP DEFAULT NOW(),

    CONSTRAINT uq_especimen UNIQUE (sexo, collection_no, collection_date)
);

-- Log de calidad de datos (misma lógica que en el pipeline de relaves)
CREATE TABLE IF NOT EXISTS pejegallo.log_calidad_datos (
    log_id            SERIAL PRIMARY KEY,
    run_id             TEXT NOT NULL,
    regla                TEXT NOT NULL,
    columna                TEXT,
    registros_afectados      INTEGER,
    accion_tomada              TEXT,     -- 'descartado' | 'imputado' | 'conservado'
    detalle                     TEXT,
    ejecutado_en                  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_especimenes_sexo ON pejegallo.especimenes_curado(sexo);
CREATE INDEX IF NOT EXISTS idx_especimenes_madurez ON pejegallo.especimenes_curado(maturity);
