ARG PYTHON_VERSION=3.11
ARG BASE_IMAGE=python:${PYTHON_VERSION}-slim-bookworm
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS builder

# Required for building packages on ppc64le
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl python3-dev build-essential \
    pkg-config libssl-dev gcc gfortran cmake \
    libopenblas-dev libjpeg-dev libhdf5-dev wget && \
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

# Transform kserve pyproject.toml for ppc64le:
#   1. Remove legacy index-url / extra-index-url keys from [tool.uv]
#   2. Inject ppc64le sources after kserve-storage inside existing [tool.uv.sources]
#   3. Append [[tool.uv.index]] entries (array-of-tables — no duplicate key issue)
RUN mkdir -p /tmp/kserve_temp && \
    mkdir -p /tmp/storage && \
    cp storage/pyproject.toml /tmp/storage/pyproject.toml && \
    cp kserve/pyproject.toml /tmp/kserve_temp/pyproject.toml && \
    sed -i \
        -e '/^index-strategy\s*=.*/a \\' \
        -e '/^index-strategy\s*=.*/a [[tool.uv.index]]' \
        -e '/^index-strategy\s*=.*/a name = "ppc64le-wheels"' \
        -e '/^index-strategy\s*=.*/a url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        -e '/^index-strategy\s*=.*/a explicit = true' \
        -e '/^\s*"pyasn1>=[^,]*"$/s/"$/",/' \
        -e '/^\s*"pyasn1>=/a\    "httptools",' \
        -e '/^\s*"pyasn1>=/a\    "uvloop",' \
        -e '/^kserve-storage\s*=.*/a grpcio = { index = "ppc64le-wheels" }\ngrpcio-tools = { index = "ppc64le-wheels" }\nnumpy = { index = "ppc64le-wheels" }\npandas = { index = "ppc64le-wheels" }\npsutil = { index = "ppc64le-wheels" }\npyyaml = { index = "ppc64le-wheels" }\nhttptools = { index = "ppc64le-wheels" }\nuvloop = { index = "ppc64le-wheels" }' \
        /tmp/kserve_temp/pyproject.toml

# Generate ppc64le uv.lock, save copies to /tmp for reuse after COPY, and promote into kserve/
RUN cd /tmp/kserve_temp && uv lock && \
    cp uv.lock /tmp/kserve_ppc64le_uv.lock && \
    cp pyproject.toml /tmp/kserve_ppc64le_pyproject.toml && \
    cp uv.lock /kserve/uv.lock && \
    cp pyproject.toml /kserve/pyproject.toml

# Clean up temp folder
RUN rm -rf /tmp/kserve_temp

# Metadata-only sync (pyproject.toml + updated uv.lock, no source tree yet)
RUN cd kserve && uv sync --active --no-cache

COPY kserve kserve
# Re-apply the generated ppc64le pyproject.toml + uv.lock after COPY overwrites them
RUN cp /tmp/kserve_ppc64le_pyproject.toml kserve/pyproject.toml && \
    cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock
# Full sync with complete source tree using the ppc64le-aware pyproject.toml + uv.lock
RUN cd kserve && uv sync --active --no-cache

# ------------------ artexplainer deps ------------------
COPY artexplainer/pyproject.toml artexplainer/uv.lock artexplainer/

# Transform artexplainer pyproject.toml for ppc64le:
#   No existing [tool.uv] or [tool.uv.sources] — append everything fresh via cat >>.
#   kserve dependency uses ../kserve path — symlink /kserve so it resolves from /tmp/artexplainer_temp/.
RUN mkdir -p /tmp/artexplainer_temp && \
    ln -s /kserve /tmp/kserve && \
    cp artexplainer/pyproject.toml /tmp/artexplainer_temp/pyproject.toml && \
    sed -i \
        -e '/^    "h5py/a\    "scikit-learn",' \
        -e '/^    "h5py/a\    "scipy",' \
        -e '/^    "h5py/a\    "ml-dtypes",' \
        /tmp/artexplainer_temp/pyproject.toml && \
    cat >> /tmp/artexplainer_temp/pyproject.toml << 'EOF'

[[tool.uv.index]]
name = "ppc64le-wheels"
url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"
explicit = true

[tool.uv.sources]
grpcio = { index = "ppc64le-wheels" }
grpcio-tools = { index = "ppc64le-wheels" }
scipy = { index = "ppc64le-wheels" }
numpy = { index = "ppc64le-wheels" }
pandas = { index = "ppc64le-wheels" }
psutil = { index = "ppc64le-wheels" }
pyyaml = { index = "ppc64le-wheels" }
uvloop = { index = "ppc64le-wheels" }
httptools = { index = "ppc64le-wheels" }
scikit-learn = { index = "ppc64le-wheels" }
pillow = { index = "ppc64le-wheels" }
h5py = { index = "ppc64le-wheels" }
ml-dtypes = { index = "ppc64le-wheels" }
EOF

# Generate ppc64le uv.lock and promote into artexplainer/
RUN cd /tmp/artexplainer_temp && uv lock && \
    cp uv.lock /tmp/artexplainer_ppc64le_uv.lock && \
    cp pyproject.toml /tmp/artexplainer_ppc64le_pyproject.toml && \
    cp uv.lock /artexplainer/uv.lock && \
    cp pyproject.toml /artexplainer/pyproject.toml

# Clean up temp folder
RUN rm -rf /tmp/artexplainer_temp /tmp/kserve

# Metadata-only sync (pyproject.toml + updated uv.lock, no source tree yet)
RUN cd artexplainer && uv sync --active --no-cache

COPY artexplainer artexplainer
# Re-apply ppc64le files after COPY overwrites them
RUN cp /tmp/artexplainer_ppc64le_pyproject.toml artexplainer/pyproject.toml && \
    cp /tmp/artexplainer_ppc64le_uv.lock artexplainer/uv.lock
# Full sync with complete source tree
RUN cd artexplainer && uv sync --active --no-cache

# Generate third-party licenses
COPY pyproject.toml pyproject.toml
COPY third_party/pip-licenses.py pip-licenses.py
# TODO: Remove this when upgrading to python 3.11+
RUN pip install --no-cache-dir tomli
RUN mkdir -p third_party/library && python3 pip-licenses.py


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
