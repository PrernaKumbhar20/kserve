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
        -e '/^index-url\s*=/d' \
        -e '/^extra-index-url\s*=/d' \
        -e '/^index-strategy\s*=.*/a \\n[[tool.uv.index]]\nname = "pypi"\nurl = "https://pypi.org/simple"\ndefault = true\n\n[[tool.uv.index]]\nname = "ppc64le-wheels"\nurl = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        -e '/^kserve-storage\s*=.*/a grpcio = { index = "ppc64le-wheels" }\ngrpcio-tools = { index = "ppc64le-wheels" }\nnumpy = { index = "ppc64le-wheels" }\npandas = { index = "ppc64le-wheels" }\npsutil = { index = "ppc64le-wheels" }\npyyaml = { index = "ppc64le-wheels" }\nhttptools = { index = "ppc64le-wheels" }\nuvloop = { index = "ppc64le-wheels" }' \
        /tmp/kserve_temp/pyproject.toml

# Generate ppc64le uv.lock and promote it back into the kserve/ dir
RUN cd /tmp/kserve_temp && uv lock && \
    cp uv.lock /kserve/uv.lock && \
    cp pyproject.toml /kserve/pyproject.toml

# Clean up temp folder
RUN rm -rf /tmp/kserve_temp

# Metadata-only sync (pyproject.toml + updated uv.lock, no source tree yet)
RUN cd kserve && uv sync --active --no-cache

COPY kserve kserve
# Full sync with complete source tree using the ppc64le-aware pyproject.toml + uv.lock
RUN cd kserve && uv sync --active --no-cache

# ------------------ artexplainer deps ------------------
COPY artexplainer/pyproject.toml artexplainer/uv.lock artexplainer/
RUN cd artexplainer && uv sync --active --no-cache

COPY artexplainer artexplainer
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
