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

# Generate a uv.lock that includes both PyPI wheels (amd64/arm64) AND IBM
# power-wheels (ppc64le) entries.
# kserve/pyproject.toml already has [tool.uv.sources] and possibly [tool.uv.index],
# so we cannot blindly append — that causes duplicate TOML key errors.
# Instead, use Python (tomllib + tomli_w) to surgically merge the ppc64le
# entries into the existing sections before running uv lock.
RUN pip install --quiet tomli-w && \
    mkdir -p /tmp/kserve_temp && \
    cp kserve/pyproject.toml kserve/uv.lock /tmp/kserve_temp/ && \
    python3 - << 'PYEOF'
import tomllib, tomli_w, copy

with open("/tmp/kserve_temp/pyproject.toml", "rb") as f:
    data = tomllib.load(f)

tool_uv = data.setdefault("tool", {}).setdefault("uv", {})

# Add IBM power-wheels index if not already present
indexes = tool_uv.setdefault("index", [])
if not any(i.get("name") == "power-wheels" for i in indexes):
    indexes.append({
        "name": "power-wheels",
        "url": "https://wheels.developerfirst.ibm.com/ppc64le/linux"
    })

# Packages to redirect to IBM mirror on ppc64le
ppc_packages = [
    "grpcio", "grpcio-tools", "numpy", "pandas",
    "psutil", "pyyaml", "uvloop", "httptools"
]

sources = tool_uv.setdefault("sources", {})
for pkg in ppc_packages:
    key = pkg.replace("-", "_")
    sources[key] = [
        {"index": "pypi",         "marker": "platform_machine != 'ppc64le'"},
        {"index": "power-wheels", "marker": "platform_machine == 'ppc64le'"},
    ]

with open("/tmp/kserve_temp/pyproject.toml", "wb") as f:
    tomli_w.dump(data, f)
PYEOF

# uv lock now runs with the correctly merged pyproject.toml — no duplicate keys.
# The existing uv.lock seed keeps all non-ppc64le packages pinned; only the
# ppc64le packages are re-resolved against the IBM mirror.
RUN cd /tmp/kserve_temp && \
    uv lock \
        --upgrade-package grpcio \
        --upgrade-package grpcio-tools \
        --upgrade-package numpy \
        --upgrade-package pandas \
        --upgrade-package psutil \
        --upgrade-package pyyaml \
        --upgrade-package uvloop \
        --upgrade-package httptools && \
    cp uv.lock /kserve/uv.lock && \
    rm -rf /tmp/kserve_temp

# Sync kserve dependencies using the updated lock
RUN cd kserve && uv sync --active --no-cache --frozen

COPY kserve kserve
RUN cd kserve && uv sync --active --no-cache --frozen

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
