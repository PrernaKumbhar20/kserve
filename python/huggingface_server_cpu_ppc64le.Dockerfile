ARG BASE_IMAGE=ubuntu:22.04
ARG VENV_PATH=/prod_venv

FROM ${BASE_IMAGE} AS base

ARG PYTHON=python3

RUN apt-get update && \
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
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    ln -s /root/.local/bin/uv /usr/local/bin/uv

# Install build dependencies.
# libjpeg-dev, libpng-dev, libtiff-dev, libfreetype6-dev, zlib1g-dev are
# required to compile pillow from source (no pre-built ppc64le wheel on PyPI).
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get install --no-install-recommends --fix-missing -y \
        build-essential \
        git \
        libfreetype6-dev \
        libjpeg-dev \
        libnuma-dev \
        libpng-dev \
        libprotobuf-dev \
        libtiff-dev \
        libyajl-dev \
        llvm-dev \
        protobuf-compiler \
        zlib1g-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal && \
    /root/.cargo/bin/rustup default stable

ENV PATH="/root/.cargo/bin:$PATH"

# Activate virtual env
ARG VENV_PATH
ENV VIRTUAL_ENV=${VENV_PATH}
RUN uv venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:/root/.cargo/bin:$PATH"
RUN uv pip install --no-cache-dir "cmake>=3.26" ninja

ARG TORCH_EXTRA_INDEX_URL="https://wheels.developerfirst.ibm.com/ppc64le/linux"
ARG LOCAL_INDEX_URL="http://10.20.186.132:8000/"
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

RUN cd kserve && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

COPY kserve kserve

# Restore the patched pyproject.toml + uv.lock after COPY overwrites them,
# so the second uv sync also resolves from IBM index (not PyPI).
RUN rm -f kserve/pyproject.toml kserve/uv.lock && \
    cp /tmp/kserve_ppc64le_pyproject.toml kserve/pyproject.toml && \
    cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock && \
    rm -f /tmp/kserve_ppc64le_pyproject.toml /tmp/kserve_ppc64le_uv.lock

RUN cd kserve && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

# Install kserve-storage
COPY storage storage

RUN sed -i \
        -e '/^    "pyasn1>=[^,]*"$/s/"$/",/' \
        -e '/^    "pyasn1>=/a\    "google-crc32c==1.8.0",' \
        -e '/^    "pyasn1>=/a\    "pyyaml==6.0.2",' \
        storage/pyproject.toml && \
    printf '%s\n' \
        '' \
        '[tool.uv]' \
        'index-strategy = "unsafe-best-match"' \
        'package = true' \
        '' \
        '[build-system]' \
        'requires = ["setuptools>=61.0"]' \
        'build-backend = "setuptools.build_meta"' \
        '' \
        '[[tool.uv.index]]' \
        'name = "ppc64le-wheels"' \
        'url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
        'explicit = true' \
        '' \
        '[tool.uv.sources]' \
        'google-crc32c = { index = "ppc64le-wheels" }' \
        'hf-xet = { index = "ppc64le-wheels" }' \
        'pyyaml = { index = "ppc64le-wheels" }' \
        >> storage/pyproject.toml && \
    cd storage && uv lock && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

# Install huggingfaceserver dependencies (metadata-first for cache)
COPY huggingfaceserver/pyproject.toml huggingfaceserver/uv.lock huggingfaceserver/health_check.py huggingfaceserver/

RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
            -e '/^dependencies = \[$/a\    "torchaudio==2.9.1",' \
            -e '/^dependencies = \[$/a\    "torchvision==0.27.0",' \
            -e '/^dependencies = \[$/a\    "torch==2.11.0",' \
            -e '/^dependencies = \[$/a\    "markupsafe==3.0.3",' \
            -e 's|"bitsandbytes>=0.45.3"|"bitsandbytes>=0.45.3; platform_machine == '\''x86_64'\''"|' \
            -e 's|"kserve\[llm\] @ file:///${PROJECT_ROOT}/../kserve"|"kserve @ file:///${PROJECT_ROOT}/../kserve"|' \
            huggingfaceserver/pyproject.toml && \
        printf '%s\n' \
            '' \
            '[[tool.uv.index]]' \
            'name = "ppc64le-wheels"' \
            'url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
            'explicit = true' \
            '' \
            '[tool.uv.sources]' \
            'torch = { index = "ppc64le-wheels" }' \
            'torchvision = { index = "ppc64le-wheels" }' \
            'torchaudio = { index = "ppc64le-wheels" }' \
            'markupsafe = { index = "ppc64le-wheels" }' \
            'pillow = { index = "ppc64le-wheels" }' \
            >> huggingfaceserver/pyproject.toml && \
        rm -f huggingfaceserver/uv.lock; \
    fi

RUN cd huggingfaceserver && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

COPY huggingfaceserver huggingfaceserver
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
            -e '/^dependencies = \[$/a\    "torchaudio==2.9.1",' \
            -e '/^dependencies = \[$/a\    "torchvision==0.27.0",' \
            -e '/^dependencies = \[$/a\    "torch==2.11.0",' \
            -e '/^dependencies = \[$/a\    "markupsafe==3.0.3",' \
            -e 's|"bitsandbytes>=0.45.3"|"bitsandbytes>=0.45.3; platform_machine == '\''x86_64'\''"|' \
            -e 's|"kserve\[llm\] @ file:///${PROJECT_ROOT}/../kserve"|"kserve @ file:///${PROJECT_ROOT}/../kserve"|' \
            huggingfaceserver/pyproject.toml && \
        printf '%s\n' \
            '' \
            '[[tool.uv.index]]' \
            'name = "ppc64le-wheels"' \
            'url = "https://wheels.developerfirst.ibm.com/ppc64le/linux"' \
            'explicit = true' \
            '' \
            '[tool.uv.sources]' \
            'torch = { index = "ppc64le-wheels" }' \
            'torchvision = { index = "ppc64le-wheels" }' \
            'torchaudio = { index = "ppc64le-wheels" }' \
            'markupsafe = { index = "ppc64le-wheels" }' \
            'pillow = { index = "ppc64le-wheels" }' \
            >> huggingfaceserver/pyproject.toml && \
        rm -f huggingfaceserver/uv.lock; \
    fi && \
    cd huggingfaceserver && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

# install vllm
ARG VLLM_VERSION=0.24.0
ARG VLLM_CPU_DISABLE_AVX512=true
ENV VLLM_CPU_DISABLE_AVX512=${VLLM_CPU_DISABLE_AVX512}
ARG VLLM_CPU_AVX512BF16=1
ENV VLLM_CPU_AVX512BF16=${VLLM_CPU_AVX512BF16}
ARG VLLM_TARGET_DEVICE=cpu
ENV VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE}
# Preinstall vLLM dependencies from IBM ppc64le devpi and local index.
# sentencepiece, tiktoken, msgspec are fetched from the local index (locally built ppc64le wheels).
# --allow-insecure-host is required because the local index serves over plain HTTP.
# Remaining packages are fetched from the IBM devpi index.
RUN uv pip install --no-cache-dir --index-strategy unsafe-best-match \
    --allow-insecure-host 10.20.186.132 \
    --extra-index-url ${LOCAL_INDEX_URL} \
    sentencepiece==0.2.2 \
    tiktoken==0.13.0 \
    msgspec==0.21.1 && \
    uv cache clean

RUN uv pip install --no-cache-dir --index-strategy unsafe-best-match \
    --extra-index-url ${TORCH_EXTRA_INDEX_URL} \
    ijson==3.5.0 \
    llguidance==1.7.5 \
    xgrammar==0.2.1 \
    opencv-python-headless==4.13.0.92 && \
    uv cache clean

# Install prebuilt vLLM wheel from IBM ppc64le index to avoid long source builds.
RUN uv pip install --no-cache-dir --index-strategy unsafe-best-match \
    --extra-index-url ${TORCH_EXTRA_INDEX_URL} \
    vllm==${VLLM_VERSION} && \
    uv cache clean

# Ensure CPU-only torch, torchvision, and torchaudio are installed.
# Previous uv sync / pip install steps may have pulled CUDA wheels from PyPI;
# this final reinstall from the CPU index guarantees CPU-only builds.
RUN uv pip install --no-cache-dir --index-strategy unsafe-best-match --extra-index-url ${TORCH_EXTRA_INDEX_URL} --reinstall \
    pillow==12.3.0 \
    torch==${TORCH_VERSION} \
    torchvision \
    torchaudio

# Cleanup vllm source code and caches
RUN rm -rf /vllm /root/.cache/uv /root/.cache/pip /tmp/*

RUN df -hT

# Generate third-party licenses
COPY pyproject.toml pyproject.toml
COPY third_party/pip-licenses.py pip-licenses.py
# TODO: Remove this when upgrading to python 3.11+
RUN pip install --no-cache-dir tomli
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