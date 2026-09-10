"""
streamlit_app.py
================
Dashboard de Streamlit para el proyecto de Talla de Madurez (L50) de
Pejegallo (Callorhynchus callorynchus).

Se conecta directamente a `pejegallo.especimenes_curado` en Azure
Database for PostgreSQL. Pensado para desplegarse en Streamlit
Community Cloud, usando `st.secrets` para las credenciales.

Nota: aunque el pipeline de transformación/carga está escrito en R,
el dashboard final se implementa en Streamlit (Python) por decisión
del equipo -- consulta la misma tabla curada en Postgres sin
problema de interoperabilidad entre lenguajes.
"""

import os

import pandas as pd
import plotly.express as px
import streamlit as st
from sqlalchemy import create_engine

st.set_page_config(page_title="Pejegallo - Talla de Madurez (L50)", layout="wide")


@st.cache_resource
def get_engine():
    cfg = st.secrets if hasattr(st, "secrets") and len(st.secrets) > 0 else os.environ
    host = cfg.get("AZURE_PG_HOST")
    port = cfg.get("AZURE_PG_PORT", "5432")
    db = cfg.get("AZURE_PG_DBNAME", "pejegallo_db")
    user = cfg.get("AZURE_PG_USER")
    password = cfg.get("AZURE_PG_PASSWORD")
    url = f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{db}?sslmode=require"
    return create_engine(url)


@st.cache_data(ttl=600)
def load_data() -> pd.DataFrame:
    engine = get_engine()
    return pd.read_sql("SELECT * FROM pejegallo.especimenes_curado;", engine)


@st.cache_data(ttl=600)
def load_quality_log() -> pd.DataFrame:
    engine = get_engine()
    query = """
        SELECT run_id, regla, columna, registros_afectados, accion_tomada, detalle
        FROM pejegallo.log_calidad_datos
        ORDER BY ejecutado_en DESC
        LIMIT 20;
    """
    return pd.read_sql(query, engine)


st.title("🐟 Talla de Madurez (L50) — Pejegallo")
st.caption("Callorhynchus callorynchus · Pipeline: R + Azure (Blob Storage → GitHub Actions → PostgreSQL)")

df = load_data()

if df.empty:
    st.warning("La tabla curada está vacía. Corre el pipeline (extract → transform → load) primero.")
    st.stop()

# --- Filtros ---
with st.sidebar:
    st.header("Filtros")
    sexo_sel = st.multiselect("Sexo", sorted(df["sexo"].dropna().unique()), default=None)
    madurez_sel = st.multiselect("Madurez", sorted(df["maturity"].dropna().unique()), default=None)

df_filtered = df.copy()
if sexo_sel:
    df_filtered = df_filtered[df_filtered["sexo"].isin(sexo_sel)]
if madurez_sel:
    df_filtered = df_filtered[df_filtered["maturity"].isin(madurez_sel)]

# --- KPIs ---
col1, col2, col3, col4 = st.columns(4)
col1.metric("Especímenes", len(df_filtered))
col2.metric("Machos", int((df_filtered["sexo"] == "male").sum()))
col3.metric("Hembras", int((df_filtered["sexo"] == "female").sum()))
col4.metric("% Maduros", f"{(df_filtered['maturity'] == 'mature').mean() * 100:.1f}%")

st.divider()

c1, c2 = st.columns(2)
with c1:
    st.subheader("Distribución de longitud total por sexo y madurez")
    fig1 = px.box(df_filtered, x="sexo", y="total_length_cm", color="maturity", points="all")
    st.plotly_chart(fig1, use_container_width=True)

with c2:
    st.subheader("Proporción madura / inmadura por sexo")
    prop_df = (
        df_filtered.groupby(["sexo", "maturity"]).size().reset_index(name="conteo")
    )
    fig2 = px.bar(prop_df, x="sexo", y="conteo", color="maturity", barmode="stack")
    st.plotly_chart(fig2, use_container_width=True)

st.subheader("Factor de condición de Fulton vs. longitud total")
fig3 = px.scatter(
    df_filtered.dropna(subset=["factor_condicion_fulton"]),
    x="total_length_cm", y="factor_condicion_fulton",
    color="sexo", hover_data=["maturity", "collection_no"],
    labels={"total_length_cm": "Longitud total (cm)", "factor_condicion_fulton": "Factor de Fulton (K)"},
)
st.plotly_chart(fig3, use_container_width=True)

st.subheader("Longitud total vs. longitud precaudal (proporción morfométrica)")
fig4 = px.scatter(
    df_filtered.dropna(subset=["precaudal_length_cm"]),
    x="total_length_cm", y="precaudal_length_cm", color="sexo",
    trendline="ols",
    labels={"total_length_cm": "Longitud total (cm)", "precaudal_length_cm": "Longitud precaudal (cm)"},
)
st.plotly_chart(fig4, use_container_width=True)

with st.expander("Ver tabla completa"):
    st.dataframe(df_filtered, use_container_width=True)

with st.expander("Ver log de calidad de datos (últimas ejecuciones del pipeline)"):
    st.dataframe(load_quality_log(), use_container_width=True)
