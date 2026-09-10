"""
streamlit_app.py
================
Dashboard de Streamlit para el proyecto de Talla de Madurez (L50) de
Pejegallo (Callorhynchus callorynchus).

Versión LOCAL: ya no depende de Azure Blob Storage ni de Azure
Database for PostgreSQL. Lee directamente los CSV que genera
`R/etl_local.R` en data/processed/ (especimenes_curado.csv y
log_calidad_datos.csv), los cuales viajan versionados en el propio
repositorio. Esto permite desplegar el dashboard en Streamlit
Community Cloud sin configurar ningún secreto ni credencial.

Incluye, además de los gráficos exploratorios originales, el ajuste
de curvas sigmoideas (regresión logística) de madurez vs. longitud
por sexo, con la talla de madurez L50 estimada y su intervalo de
confianza (bootstrap).
"""

from pathlib import Path

import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from scipy.optimize import minimize

st.set_page_config(page_title="Pejegallo - Talla de Madurez (L50)", layout="wide")

# ---------------------------------------------------------------------------
# Rutas de datos (generados localmente por R/etl_local.R y versionados en git)
# ---------------------------------------------------------------------------
DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "processed"
CURADO_PATH = DATA_DIR / "especimenes_curado.csv"
LOG_CALIDAD_PATH = DATA_DIR / "log_calidad_datos.csv"


@st.cache_data(ttl=3600)
def load_data() -> pd.DataFrame:
    df = pd.read_csv(CURADO_PATH)
    if "collection_date" in df.columns:
        df["collection_date"] = pd.to_datetime(df["collection_date"], errors="coerce")
    return df


@st.cache_data(ttl=3600)
def load_quality_log() -> pd.DataFrame:
    if not LOG_CALIDAD_PATH.exists():
        return pd.DataFrame()
    df = pd.read_csv(LOG_CALIDAD_PATH)
    sort_col = "ejecutado_en" if "ejecutado_en" in df.columns else None
    if sort_col:
        df = df.sort_values(sort_col, ascending=False)
    return df.head(20)


# ---------------------------------------------------------------------------
# Ajuste de la curva sigmoidea de madurez (L50) por regresión logística
# ---------------------------------------------------------------------------
# p(L) = 1 / (1 + exp(-k * (L - L50)))
# Se estima por máxima verosimilitud (sin depender de statsmodels).

def _sigmoid(L, l50, k):
    z = np.clip(k * (L - l50), -500, 500)
    return 1.0 / (1.0 + np.exp(-z))


def _negloglik(params, L, y):
    l50, k = params
    p = np.clip(_sigmoid(L, l50, k), 1e-9, 1 - 1e-9)
    return -np.sum(y * np.log(p) + (1 - y) * np.log(1 - p))


def _fit_l50(L, y, x0=None):
    if x0 is None:
        x0 = [float(np.median(L)), 0.3]
    res = minimize(_negloglik, x0, args=(L, y), method="Nelder-Mead")
    return res.x  # (L50, k)


@st.cache_data(ttl=3600)
def fit_l50_with_ci(L: np.ndarray, y: np.ndarray, n_boot: int = 100, seed: int = 42):
    """Ajusta la curva sigmoidea y calcula una banda de confianza por bootstrap."""
    l50_hat, k_hat = _fit_l50(L, y)

    rng = np.random.default_rng(seed)
    n = len(L)
    l_grid = np.linspace(L.min(), L.max(), 200)

    l50_boot = []
    curves_boot = []
    for _ in range(n_boot):
        idx = rng.integers(0, n, n)
        Lb, yb = L[idx], y[idx]
        if yb.sum() == 0 or yb.sum() == n:  # sin variación -> no se puede ajustar
            continue
        try:
            l50_b, k_b = _fit_l50(Lb, yb, x0=[l50_hat, k_hat])
            if np.isfinite(l50_b) and L.min() - 20 < l50_b < L.max() + 20:
                l50_boot.append(l50_b)
                curves_boot.append(_sigmoid(l_grid, l50_b, k_b))
        except Exception:
            continue

    l50_boot = np.array(l50_boot)
    curves_boot = np.array(curves_boot)

    if len(l50_boot) > 5:
        l50_ci = (np.percentile(l50_boot, 5), np.percentile(l50_boot, 95))
        curve_lo = np.percentile(curves_boot, 5, axis=0)
        curve_hi = np.percentile(curves_boot, 95, axis=0)
    else:
        l50_ci = (np.nan, np.nan)
        curve_lo = curve_hi = None

    curve_fit = _sigmoid(l_grid, l50_hat, k_hat)
    return {
        "l50": l50_hat, "k": k_hat, "l50_ci": l50_ci,
        "l_grid": l_grid, "curve_fit": curve_fit,
        "curve_lo": curve_lo, "curve_hi": curve_hi,
        "n_boot_ok": len(l50_boot),
    }


def l50_figure(df_sex: pd.DataFrame, length_col: str, label: str, color: str) -> go.Figure:
    sub = df_sex.dropna(subset=[length_col, "maturity"]).copy()
    sub["y"] = (sub["maturity"] == "mature").astype(int)
    L = sub[length_col].to_numpy(dtype=float)
    y = sub["y"].to_numpy(dtype=float)

    fig = go.Figure()

    if len(sub) < 15 or y.sum() == 0 or y.sum() == len(y):
        fig.add_annotation(text="Datos insuficientes para ajustar la curva", showarrow=False)
        fig.update_layout(height=380, title=f"{label} — sin ajuste posible")
        return fig

    fit = fit_l50_with_ci(L, y)

    # Banda de confianza (bootstrap)
    if fit["curve_lo"] is not None:
        fig.add_trace(go.Scatter(
            x=np.concatenate([fit["l_grid"], fit["l_grid"][::-1]]),
            y=np.concatenate([fit["curve_hi"], fit["curve_lo"][::-1]]),
            fill="toself", fillcolor=color.replace("rgb", "rgba").replace(")", ", 0.15)")
            if color.startswith("rgb") else "rgba(28,114,147,0.15)",
            line=dict(width=0), hoverinfo="skip", showlegend=False, name="IC 90% (bootstrap)",
        ))

    # Curva sigmoidea ajustada
    fig.add_trace(go.Scatter(
        x=fit["l_grid"], y=fit["curve_fit"], mode="lines",
        line=dict(color=color, width=3), name="Curva ajustada (logística)",
    ))

    # Puntos observados (jitter vertical para que no se amontonen en 0/1)
    rng = np.random.default_rng(0)
    jitter = rng.uniform(-0.035, 0.035, size=len(y))
    fig.add_trace(go.Scatter(
        x=L, y=y + jitter, mode="markers",
        marker=dict(color=color, size=6, opacity=0.45),
        name="Especímenes (0=inmaduro, 1=maduro)",
    ))

    # Línea de referencia p=0.5 y línea vertical en L50
    fig.add_hline(y=0.5, line_dash="dot", line_color="#9AA7B0")
    fig.add_vline(x=fit["l50"], line_dash="dash", line_color=color)

    l50_txt = f"L50 = {fit['l50']:.1f} cm"
    if np.isfinite(fit["l50_ci"][0]):
        l50_txt += f"  (IC90%: {fit['l50_ci'][0]:.1f}–{fit['l50_ci'][1]:.1f})"

    fig.add_annotation(
        x=fit["l50"], y=1.06, text=l50_txt, showarrow=False,
        font=dict(color=color, size=13, family="Arial Black"),
        xanchor="center",
    )

    fig.update_layout(
        title=f"{label} (n = {len(sub)})",
        xaxis_title=f"{'Longitud total' if 'total' in length_col else 'Longitud precaudal'} (cm)",
        yaxis_title="Probabilidad de madurez",
        yaxis=dict(range=[-0.12, 1.15], tickvals=[0, 0.5, 1]),
        height=420, showlegend=True,
        legend=dict(orientation="h", y=-0.22),
        margin=dict(t=70),
    )
    return fig


# ---------------------------------------------------------------------------
# Carga de datos
# ---------------------------------------------------------------------------
st.title("🐟 Talla de Madurez (L50) — Pejegallo")
st.caption(
    "Callorhynchus callorynchus · Pipeline 100% local (R + VS Code) → "
    "CSV versionado → dashboard en Streamlit Community Cloud"
)

if not CURADO_PATH.exists():
    st.warning(
        "No se encontró data/processed/especimenes_curado.csv. "
        "Corre `Rscript R/etl_local.R` desde la raíz del proyecto y vuelve a cargar la app."
    )
    st.stop()

df = load_data()

if df.empty:
    st.warning("El archivo curado está vacío. Revisa la ejecución de R/etl_local.R.")
    st.stop()

# --- Filtros ---
with st.sidebar:
    st.header("Filtros")
    sexo_sel = st.multiselect("Sexo", sorted(df["sexo"].dropna().unique()), default=None)
    madurez_sel = st.multiselect("Madurez", sorted(df["maturity"].dropna().unique()), default=None)
    st.divider()
    length_metric = st.radio(
        "Variable para la curva L50",
        options=["total_length_cm", "precaudal_length_cm"],
        format_func=lambda c: "Longitud total" if c == "total_length_cm" else "Longitud precaudal",
    )

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

# --- Curvas sigmoideas de L50 (siempre con TODOS los datos por sexo, no con
#     el filtro de madurez activo, ya que la curva necesita ambas clases) ---
st.subheader("📈 Curva de madurez sigmoidea y talla L50")
st.caption(
    "Regresión logística de madurez (0/1) vs. longitud, ajustada por sexo. "
    "La línea vertical marca la talla L50 (50% de probabilidad de estar maduro); "
    "la banda sombreada es el intervalo de confianza 90% obtenido por bootstrap."
)

base_for_l50 = df[df["sexo"].isin(sexo_sel)] if sexo_sel else df
colM, colH = st.columns(2)
with colM:
    st.plotly_chart(
        l50_figure(base_for_l50[base_for_l50["sexo"] == "male"], length_metric, "Machos", "#065A82"),
        use_container_width=True,
    )
with colH:
    st.plotly_chart(
        l50_figure(base_for_l50[base_for_l50["sexo"] == "female"], length_metric, "Hembras", "#B4472B"),
        use_container_width=True,
    )

st.divider()

# --- Gráficos exploratorios ---
c1, c2 = st.columns(2)
with c1:
    st.subheader("Distribución de longitud total por sexo y madurez")
    fig1 = px.box(df_filtered, x="sexo", y="total_length_cm", color="maturity", points="all")
    st.plotly_chart(fig1, use_container_width=True)

with c2:
    st.subheader("Proporción madura / inmadura por sexo")
    prop_df = df_filtered.groupby(["sexo", "maturity"]).size().reset_index(name="conteo")
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

with st.expander("Ver log de calidad de datos (última ejecución de R/etl_local.R)"):
    qlog = load_quality_log()
    if qlog.empty:
        st.info("No se encontró data/processed/log_calidad_datos.csv todavía.")
    else:
        st.dataframe(qlog, use_container_width=True)
