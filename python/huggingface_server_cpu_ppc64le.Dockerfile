ARG BASE_IMAGE=ubuntu:22.04
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS base

ARG PYTHON=python3

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends --fix-missing -y \
        g++-12 \
        gcc-12 \
        google-perftools \
        libgl1 \
        libglib2.0-0 \
        libjemalloc2 \
        libnuma1 \
        numactl \
        python3.10-dev \
        python3.10-venv \
        python3-pip \
        curl && \
    apt-get clean && \
    apt-get autoclean && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 10 --slave /usr/bin/g++ g++ /usr/bin/g++-12
ENV CC=/usr/bin/gcc-12 CXX=/usr/bin/g++-12

RUN ln -sf "$(which ${PYTHON})" /usr/bin/python

FROM base AS builder

# Install uv
RUN --mount=type=cache,target=/root/.cache/uv \
    curl -LsSf https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get install --no-install-recommends --fix-missing -y \
        build-essential \
        git \
        libnuma-dev \
        libjpeg-turbo8-dev \
        zlib1g-dev \
        libpng-dev \
        libtiff-dev \
        libfreetype-dev \
        libwebp-dev \
        libopenjp2-7-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
RUN uv venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

ARG TORCH_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cpu"
ARG TORCH_VERSION=2.11.0

# Copy storage metadata for editable dependency resolution
COPY storage/pyproject.toml storage/uv.lock storage/

# Install kserve dependencies (metadata-first for cache)
COPY kserve/pyproject.toml kserve/uv.lock kserve/
# Patch kserve/pyproject.toml: add IBM ppc64le index and route packages that
# have no PyPI ppc64le wheels through it, then regenerate uv.lock.
RUN sed -i \
        -e '/^index-strategy\s*=.*/a \\' \
        -e '/^index-strategy\s*=.*/a [[tool.uv.index]]' \
        -e '/^index-strategy\s*=.*/a name = "ppc64le-wheels"' \
        -e '/^index-strategy\s*=.*/a url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        -e '/^index-strategy\s*=.*/a explicit = true' \
        -e '/^\s*"pyasn1>=[^,]*"$/s/"$/",/' \
        -e '/^\s*"pyasn1>=/a\    "httptools==0.6.4",' \
        -e '/^\s*"pyasn1>=/a\    "uvloop==0.21.0",' \
        -e '/^kserve-storage\s*=.*/a grpcio = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a grpcio-tools = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a numpy = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a pandas = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a psutil = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a pyyaml = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a httptools = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a uvloop = { index = "ppc64le-wheels" }' \
        -e '/^kserve-storage\s*=.*/a scikit-learn = { index = "ppc64le-wheels" }' \
        kserve/pyproject.toml && \
    cd kserve && uv lock && \
    cp uv.lock /tmp/kserve_ppc64le_uv.lock && \
    cp pyproject.toml /tmp/kserve_ppc64le_pyproject.toml

RUN --mount=type=cache,target=/root/.cache/uv \
    cd kserve && \
    uv sync --active

COPY kserve kserve

# Restore the patched pyproject.toml + uv.lock after COPY overwrites them,
# so the second uv sync also resolves from IBM index (not PyPI).
RUN rm -f kserve/pyproject.toml kserve/uv.lock && \
    cp /tmp/kserve_ppc64le_pyproject.toml kserve/pyproject.toml && \
    cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock && \
    rm -f /tmp/kserve_ppc64le_pyproject.toml /tmp/kserve_ppc64le_uv.lock

RUN --mount=type=cache,target=/root/.cache/uv \
    cd kserve && \
    uv sync --active
# Install kserve-storage
COPY storage storage
RUN --mount=type=cache,target=/root/.cache/uv \
    cd storage && uv pip install .

# Install huggingfaceserver dependencies (metadata-first for cache)
COPY huggingfaceserver/pyproject.toml huggingfaceserver/uv.lock huggingfaceserver/health_check.py huggingfaceserver/
RUN --mount=type=cache,target=/root/.cache/uv \
    cd huggingfaceserver && \
    uv pip install --index-strategy unsafe-best-match --extra-index-url ${TORCH_EXTRA_INDEX_URL} \
        torch==${TORCH_VERSION}+cpu \
        torchvision \
        torchaudio && \
    uv sync --active

COPY huggingfaceserver huggingfaceserver
RUN --mount=type=cache,target=/root/.cache/uv \
    cd huggingfaceserver && \
    uv sync --active

# install vllm
ARG VLLM_VERSION=0.24.0
ARG VLLM_CPU_DISABLE_AVX512=true
ENV VLLM_CPU_DISABLE_AVX512=${VLLM_CPU_DISABLE_AVX512}
ARG VLLM_CPU_AVX512BF16=1
ENV VLLM_CPU_AVX512BF16=${VLLM_CPU_AVX512BF16}
ARG VLLM_TARGET_DEVICE=cpu
ENV VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE}
# Clone vLLM repo
RUN git clone --single-branch --branch v${VLLM_VERSION} https://github.com/vllm-project/vllm.git

# Install vLLM build requirements
RUN --mount=type=cache,target=/root/.cache/uv \
    cd vllm && \
    uv pip install -v --torch-backend cpu --index-strategy unsafe-best-match -r requirements/build/cpu.txt

# Install vLLM cpu requirements
RUN --mount=type=cache,target=/root/.cache/uv \
    cd vllm && \
    uv pip install -v --torch-backend cpu --index-strategy unsafe-best-match -r requirements/cpu.txt

# Build and install vLLM
RUN --mount=type=cache,target=/root/.cache/uv \
    cd vllm && \
    VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE} uv pip install --no-build-isolation --index-strategy unsafe-best-match .

# Ensure CPU-only torch, torchvision, and torchaudio are installed.
# Previous uv sync / pip install steps may have pulled CUDA wheels from PyPI;
# this final reinstall from the CPU index guarantees CPU-only builds.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --index-strategy unsafe-best-match --extra-index-url ${TORCH_EXTRA_INDEX_URL} --reinstall \
    torch==${TORCH_VERSION}+cpu \
    torchvision \
    torchaudio

# Cleanup vllm source code
RUN rm -rf /vllm /tmp/*

RUN df -hT

# Generate third-party licenses
COPY pyproject.toml pyproject.toml
COPY third_party/pip-licenses.py pip-licenses.py
# TODO: Remove this when upgrading to python 3.11+
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install tomli
RUN mkdir -p third_party/library && python3 pip-licenses.py

# Build the final image
FROM base AS prod

RUN echo 'ulimit -c 0' >> ~/.bashrc

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN useradd kserve -m -u 1000 -d /home/kserve

COPY --from=builder --chown=kserve:kserve third_party third_party
COPY --from=builder --chown=kserve:kserve $VIRTUAL_ENV $VIRTUAL_ENV
COPY --from=builder --chown=kserve:kserve huggingfaceserver huggingfaceserver
COPY --from=builder --chown=kserve:kserve kserve kserve
COPY --from=builder --chown=kserve:kserve storage storage

RUN df -hT

# Set a writable Hugging Face home folder to avoid permission issue. See https://github.com/kserve/kserve/issues/3562
ENV HF_HOME="/tmp/huggingface"
# https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables#hfhubdisabletelemetry
ENV HF_HUB_DISABLE_TELEMETRY="1"

# Use TCMalloc and jemalloc for better memory management
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4:/usr/lib/x86_64-linux-gnu/libjemalloc.so.2:${LD_PRELOAD}

USER 1000
ENV PYTHONPATH=/huggingfaceserver
ENTRYPOINT ["python", "-m", "huggingfaceserver"]