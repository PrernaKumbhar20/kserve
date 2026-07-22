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

# Install build dependencies
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && \
    apt-get install --no-install-recommends --fix-missing -y \
        build-essential \
        git \
        libnuma-dev && \
    if [ "$(uname -m)" = "ppc64le" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends --fix-missing -y \
            libjpeg-dev \
            zlib1g-dev \
            libfreetype6-dev \
            liblcms2-dev \
            libwebp-dev \
            tcl-dev \
            tk-dev; \
    fi && \
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

# On ppc64le: patch pyproject.toml to add the ppc64le package index and sources,
# then regenerate uv.lock before syncing.
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
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
        cp pyproject.toml /tmp/kserve_ppc64le_pyproject.toml; \
    fi

RUN cd kserve && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

COPY kserve kserve

# On ppc64le: restore the patched pyproject.toml + uv.lock after COPY overwrites them
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        rm -f kserve/pyproject.toml kserve/uv.lock && \
        cp /tmp/kserve_ppc64le_pyproject.toml kserve/pyproject.toml && \
        cp /tmp/kserve_ppc64le_uv.lock kserve/uv.lock && \
        rm -f /tmp/kserve_ppc64le_pyproject.toml /tmp/kserve_ppc64le_uv.lock; \
    fi

RUN cd kserve && \
    uv sync --active --no-cache && \
    uv cache clean && \
    rm -rf ~/.cache/uv

# Install kserve-storage
COPY storage storage

# On ppc64le: append ppc64le index + sources to storage/pyproject.toml,
# regenerate uv.lock, then sync (same pattern as kserve/lgbserver).
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        sed -i \
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
        uv sync --active --no-cache; \
    else \
        cd storage && uv pip install . --no-cache; \
    fi

# Install huggingfaceserver dependencies (metadata-first for cache)
COPY huggingfaceserver/pyproject.toml huggingfaceserver/uv.lock huggingfaceserver/health_check.py huggingfaceserver/

# On ppc64le: patch huggingfaceserver/pyproject.toml to:
# - exclude bitsandbytes (x86_64-only, no source dist on PyPI, not on IBM devpi)
# - route opencv-python-headless to IBM devpi (no PyPI ppc64le wheel, available on devpi)
# - add the IBM ppc64le index so uv.sources can reference it
# Uses Python to safely manipulate TOML structure (avoids sed corrupting nested tables).
# TODO: remove exclusions/overrides if ppc64le builds become available on PyPI.
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        printf '%s\n' \
            'import re, pathlib' \
            'p = pathlib.Path("huggingfaceserver/pyproject.toml")' \
            'txt = p.read_text()' \
            'txt = txt.replace("\"bitsandbytes>=0.45.3\"", "\"bitsandbytes>=0.45.3; sys_platform == '\''linux'\'' and platform_machine != '\''ppc64le'\''\"")' \
            'addition = "\n[[tool.uv.index]]\nname = \"ppc64le-wheels\"\nurl = \"https://wheels.developerfirst.ibm.com/ppc64le/linux\"\nexplicit = true\n\n[tool.uv.sources]\nopencv-python-headless = { index = \"ppc64le-wheels\" }\n"' \
            'txt = txt + addition' \
            'if "index-strategy" not in txt:' \
            '    txt = re.sub(r"(\[tool\.uv\])", r"\1\nindex-strategy = \"unsafe-best-match\"", txt)' \
            'p.write_text(txt)' \
            > /tmp/patch_hfs_pyproject.py && \
        python3 /tmp/patch_hfs_pyproject.py && \
        cd huggingfaceserver && uv lock && \
        cp uv.lock /tmp/hfs_ppc64le_uv.lock && \
        cp pyproject.toml /tmp/hfs_ppc64le_pyproject.toml; \
    fi

RUN cd huggingfaceserver && \
    if [ "$(uname -m)" = "ppc64le" ]; then \
        uv pip install --no-cache-dir --index-strategy unsafe-best-match \
            --extra-index-url https://wheels.developerfirst.ibm.com/ppc64le/linux \
            torch==${TORCH_VERSION} \
            torchvision \
            torchaudio \
            pillow && \
        uv sync --active --no-cache \
            --no-install-package torch \
            --no-install-package torchvision \
            --no-install-package torchaudio \
            --no-install-package cuda-bindings \
            --no-install-package cuda-pathfinder \
            --no-install-package cuda-python \
            --no-install-package cuda-tile \
            --no-install-package cuda-toolkit \
            --no-install-package nvidia-cublas \
            --no-install-package nvidia-cuda-cccl \
            --no-install-package nvidia-cuda-crt \
            --no-install-package nvidia-cuda-cupti \
            --no-install-package nvidia-cuda-nvcc \
            --no-install-package nvidia-cuda-nvrtc \
            --no-install-package nvidia-cuda-runtime \
            --no-install-package nvidia-cuda-tileiras \
            --no-install-package nvidia-cudnn-cu13 \
            --no-install-package nvidia-cudnn-frontend \
            --no-install-package nvidia-cufft \
            --no-install-package nvidia-cufile \
            --no-install-package nvidia-curand \
            --no-install-package nvidia-cusolver \
            --no-install-package nvidia-cusparse \
            --no-install-package nvidia-cusparselt-cu13 \
            --no-install-package nvidia-cutlass-dsl \
            --no-install-package nvidia-cutlass-dsl-libs-base \
            --no-install-package nvidia-cutlass-dsl-libs-cu13 \
            --no-install-package nvidia-ml-py \
            --no-install-package nvidia-nccl-cu13 \
            --no-install-package nvidia-nvjitlink \
            --no-install-package nvidia-nvshmem-cu13 \
            --no-install-package nvidia-nvtx \
            --no-install-package nvidia-nvvm \
            --no-install-package tokenspeed-triton \
            --no-install-package triton; \
    else \
        uv pip install --no-cache-dir --index-strategy unsafe-best-match --extra-index-url ${TORCH_EXTRA_INDEX_URL} \
            torch==${TORCH_VERSION}+cpu \
            torchvision \
            torchaudio && \
        uv sync --active --no-cache; \
    fi && \
    uv cache clean && \
    rm -rf ~/.cache/uv

COPY huggingfaceserver huggingfaceserver

# On ppc64le: restore the patched pyproject.toml + uv.lock after COPY overwrites them
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        rm -f huggingfaceserver/pyproject.toml huggingfaceserver/uv.lock && \
        cp /tmp/hfs_ppc64le_pyproject.toml huggingfaceserver/pyproject.toml && \
        cp /tmp/hfs_ppc64le_uv.lock huggingfaceserver/uv.lock && \
        rm -f /tmp/hfs_ppc64le_pyproject.toml /tmp/hfs_ppc64le_uv.lock; \
    fi

RUN cd huggingfaceserver && \
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
# Clone vLLM repo
RUN git clone --single-branch --branch v${VLLM_VERSION} https://github.com/vllm-project/vllm.git

# Install vLLM build requirements
RUN cd vllm && \
    uv pip install --no-cache -v --torch-backend cpu --index-strategy unsafe-best-match -r requirements/build/cpu.txt && \
    uv cache clean

# Install vLLM cpu requirements
RUN cd vllm && \
    uv pip install --no-cache -v --torch-backend cpu --index-strategy unsafe-best-match -r requirements/cpu.txt && \
    uv cache clean

# Build and install vLLM
RUN cd vllm && \
    VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE} uv pip install --no-cache --no-build-isolation --index-strategy unsafe-best-match . && \
    uv cache clean

# Ensure CPU-only torch, torchvision, and torchaudio are installed.
# Previous uv sync / pip install steps may have pulled CUDA wheels from PyPI;
# this final reinstall from the CPU index guarantees CPU-only builds.
RUN if [ "$(uname -m)" = "ppc64le" ]; then \
        uv pip install --no-cache-dir --index-strategy unsafe-best-match --reinstall \
            --extra-index-url https://wheels.developerfirst.ibm.com/ppc64le/linux \
            torch==${TORCH_VERSION} \
            torchvision \
            torchaudio \
            pillow; \
    else \
        uv pip install --no-cache-dir --index-strategy unsafe-best-match --extra-index-url ${TORCH_EXTRA_INDEX_URL} --reinstall \
            torch==${TORCH_VERSION}+cpu \
            torchvision \
            torchaudio; \
    fi

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

# Use TCMalloc and jemalloc for better memory management (paths are arch-specific)
RUN ARCH="$(uname -m)" && \
    if [ "$ARCH" = "ppc64le" ]; then \
        echo "LD_PRELOAD=/usr/lib/powerpc64le-linux-gnu/libtcmalloc.so.4:/usr/lib/powerpc64le-linux-gnu/libjemalloc.so.2" >> /etc/environment; \
    else \
        echo "LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4:/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" >> /etc/environment; \
    fi

USER 1000
ENV PYTHONPATH=/huggingfaceserver
ENTRYPOINT ["python", "-m", "huggingfaceserver"]