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
# power-wheels (ppc64le) entries. Steps:
# 1. Copy pyproject.toml + uv.lock into a temp dir
# 2. Append the IBM index + platform-conditional [tool.uv.sources] to pyproject.toml
# 3. Run `uv lock --upgrade-package` for only the ppc64le packages — this adds
#    ppc64le wheel entries from the IBM mirror into the lock while keeping all
#    existing PyPI entries intact
# 4. Overwrite kserve/uv.lock with the updated lock so uv sync uses it
# NOTE: This runs inside the QEMU-emulated ppc64le container, so uv correctly
# identifies the platform as ppc64le and resolves IBM mirror wheels for it.
ARG DEVPI_PPC64LE_URL=https://wheels.developerfirst.ibm.com/ppc64le/linux
RUN mkdir -p /tmp/kserve_temp && \
    cp kserve/pyproject.toml kserve/uv.lock /tmp/kserve_temp/ && \
    cat >> /tmp/kserve_temp/pyproject.toml << 'EOF'

[[tool.uv.index]]
name = "power-wheels"
url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"

[tool.uv.sources]
grpcio = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
grpcio_tools = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
numpy = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
pandas = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
psutil = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
pyyaml = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
uvloop = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
httptools = [
    { index = "pypi", marker = "platform_machine != 'ppc64le'" },
    { index = "power-wheels", marker = "platform_machine == 'ppc64le'" },
]
EOF

# Run uv lock inside the temp dir. The existing uv.lock seed means uv only
# needs to resolve the newly added ppc64le sources — all other packages stay
# pinned. The result contains wheel entries for ALL platforms.
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

# Sync kserve dependencies using the updated lock (contains IBM mirror wheels
# for ppc64le — uv picks the correct wheel per platform marker)
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
