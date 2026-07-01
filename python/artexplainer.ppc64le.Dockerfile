ARG PYTHON_VERSION=3.11
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS builder

# Required for building packages on ppc64le
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl python3-dev build-essential \
    pkg-config libssl-dev gcc gfortran cmake \
    libopenblas-dev libjpeg-dev libhdf5-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

# Setup virtual environment
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
RUN uv venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Copy storage metadata for editable dependency resolution
COPY storage/pyproject.toml storage/uv.lock storage/

# ------------------ kserve deps ------------------
COPY kserve/pyproject.toml kserve/uv.lock kserve/

# Transform kserve pyproject.toml for ppc64le in-place:
#   - Inject DevPI index after index-strategy (no temp dir needed — COPY kserve kserve restores original)
#   - Inject httptools + uvloop as direct deps (transitive from uvicorn)
#   - Inject ppc64le sources into existing [tool.uv.sources]
#   uv lock runs from /kserve/ so ../storage resolves to /storage/ which already exists
RUN sed -i \
        -e '/^index-strategy\s*=.*/a \\' \
        -e '/^index-strategy\s*=.*/a [[tool.uv.index]]' \
        -e '/^index-strategy\s*=.*/a name = "ppc64le-wheels"' \
        -e '/^index-strategy\s*=.*/a url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        -e '/^index-strategy\s*=.*/a explicit = true' \
        -e '/^\s*"pyasn1>=[^,]*"$/s/"$/",/' \
        -e '/^\s*"pyasn1>=/a\    "httptools",' \
        -e '/^\s*"pyasn1>=/a\    "uvloop",' \
        -e '/^kserve-storage\s*=.*/a grpcio = { index = "ppc64le-wheels" }\ngrpcio-tools = { index = "ppc64le-wheels" }\nnumpy = { index = "ppc64le-wheels" }\npandas = { index = "ppc64le-wheels" }\npsutil = { index = "ppc64le-wheels" }\npyyaml = { index = "ppc64le-wheels" }\nhttptools = { index = "ppc64le-wheels" }\nuvloop = { index = "ppc64le-wheels" }' \
        kserve/pyproject.toml

# DEBUG: print kserve pyproject.toml after transformation
RUN echo "===== kserve pyproject.toml =====" && cat kserve/pyproject.toml

# Generate ppc64le uv.lock from /kserve/ directly, save backup to /tmp/
RUN cd kserve && uv lock && \
    cp uv.lock /tmp/kserve_ppc64le_uv.lock && \
    cp pyproject.toml /tmp/kserve_ppc64le_pyproject.toml

# DEBUG: print kserve uv.lock after generation
RUN echo "===== kserve uv.lock =====" && cat kserve/uv.lock

# Metadata-only sync (pyproject.toml + updated uv.lock, no source tree yet)
RUN cd kserve && uv sync --active --no-cache

COPY kserve kserve
# Re-apply ppc64le pyproject.toml + uv.lock after COPY overwrites them
RUN cp /tmp/kserve_ppc64le_pyproject.toml kserve/pyproject.toml && \
    cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock
# Full sync with complete source tree
RUN cd kserve && uv sync --active --no-cache

# ------------------ artexplainer deps ------------------
COPY artexplainer/pyproject.toml artexplainer/uv.lock artexplainer/

# Transform artexplainer pyproject.toml for ppc64le in-place:
#   - Inject scikit-learn, scipy, ml-dtypes as direct deps (transitive from ART/keras)
#   - Append DevPI index + ppc64le sources (no existing [tool.uv] sections — safe to append)
#   uv lock runs from /artexplainer/ so ../kserve resolves to /kserve/ which already exists
RUN sed -i \
        -e '/^    "h5py/a\    "scikit-learn",' \
        -e '/^    "h5py/a\    "scipy",' \
        -e '/^    "h5py/a\    "ml-dtypes",' \
        artexplainer/pyproject.toml && \
    printf '%s\n' \
        '' \
        '[[tool.uv.index]]' \
        'name = "ppc64le-wheels"' \
        'url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        'explicit = true' \
        '' \
        '[tool.uv.sources]' \
        'grpcio = { index = "ppc64le-wheels" }' \
        'grpcio-tools = { index = "ppc64le-wheels" }' \
        'scipy = { index = "ppc64le-wheels" }' \
        'numpy = { index = "ppc64le-wheels" }' \
        'pandas = { index = "ppc64le-wheels" }' \
        'psutil = { index = "ppc64le-wheels" }' \
        'pyyaml = { index = "ppc64le-wheels" }' \
        'uvloop = { index = "ppc64le-wheels" }' \
        'httptools = { index = "ppc64le-wheels" }' \
        'scikit-learn = { index = "ppc64le-wheels" }' \
        'pillow = { index = "ppc64le-wheels" }' \
        'h5py = { index = "ppc64le-wheels" }' \
        'ml-dtypes = { index = "ppc64le-wheels" }' \
        >> artexplainer/pyproject.toml

# DEBUG: print artexplainer pyproject.toml after transformation
RUN echo "===== artexplainer pyproject.toml =====" && cat artexplainer/pyproject.toml

# Generate ppc64le uv.lock from /artexplainer/ directly, save backup to /tmp/
RUN cd artexplainer && uv lock && \
    cp uv.lock /tmp/artexplainer_ppc64le_uv.lock && \
    cp pyproject.toml /tmp/artexplainer_ppc64le_pyproject.toml

# DEBUG: print artexplainer uv.lock after generation
RUN echo "===== artexplainer uv.lock =====" && cat artexplainer/uv.lock

# Metadata-only sync (pyproject.toml + updated uv.lock, no source tree yet)
RUN cd artexplainer && uv sync --active --no-cache

COPY artexplainer artexplainer
# Re-apply ppc64le pyproject.toml + uv.lock after COPY overwrites them, then clean up
RUN cp /tmp/artexplainer_ppc64le_pyproject.toml artexplainer/pyproject.toml && \
    cp /tmp/artexplainer_ppc64le_uv.lock artexplainer/uv.lock && \
    rm -f /tmp/kserve_ppc64le_pyproject.toml /tmp/kserve_ppc64le_uv.lock \
          /tmp/artexplainer_ppc64le_pyproject.toml /tmp/artexplainer_ppc64le_uv.lock
# Full sync with complete source tree
RUN cd artexplainer && uv sync --active --no-cache

# Generate third-party licenses
COPY pyproject.toml pyproject.toml
COPY third_party/pip-licenses.py pip-licenses.py
# TODO: Remove this when upgrading to python 3.11+
RUN pip install --no-cache-dir tomli && \
    mkdir -p third_party/library && python3 pip-licenses.py


# ------------------ Production stage ------------------
FROM ${BASE_IMAGE} AS prod

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN useradd kserve -m -u 1000 -d /home/kserve

COPY --from=builder --chown=kserve:kserve third_party third_party
COPY --from=builder --chown=kserve:kserve $VIRTUAL_ENV $VIRTUAL_ENV
COPY --from=builder kserve kserve
COPY --from=builder artexplainer artexplainer

USER 1000
ENV PYTHONPATH=/artexplainer
ENTRYPOINT ["python", "-m", "artserver"]
