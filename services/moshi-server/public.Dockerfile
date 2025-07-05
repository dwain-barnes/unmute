# This is the public-facing version.
FROM nvidia/cuda:12.1.0-devel-ubuntu22.04 AS base

# Set environment variables to avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    ca-certificates \
    libssl-dev \
    git \
    pkg-config \
    cmake \
    wget \
    openssh-client \
    python3 \
    python3-pip \
    python3-dev \
    libpython3-dev \
    libpython3.10-dev \
    --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

COPY --from=ghcr.io/astral-sh/uv:0.7.2 /uv /uvx /bin/

WORKDIR /app

# When starting the container for the first time, we need to compile and download
# everything, so disregarding healthcheck failure for 10 minutes is free.
# We have a volume storing the build cache, so subsequent starts will be faster.
HEALTHCHECK --start-period=10m \
    CMD curl --fail http://localhost:8080/api/build_info || exit 1

EXPOSE 8080
ENV RUST_BACKTRACE=1

RUN wget https://raw.githubusercontent.com/kyutai-labs/moshi/a40c5612ade3496f4e4aa47273964404ba287168/rust/moshi-server/pyproject.toml
RUN wget https://raw.githubusercontent.com/kyutai-labs/moshi/a40c5612ade3496f4e4aa47273964404ba287168/rust/moshi-server/uv.lock

COPY . .

# Install Python dependencies using uv
RUN uv sync --locked

# Install additional Python dependencies that moshi-server needs
RUN uv pip install huggingface_hub transformers torch torchaudio numpy pydantic triton

# CRITICAL FIX: Install packages globally AND in venv
RUN /bin/bash -c "source .venv/bin/activate && pip install huggingface_hub transformers torch torchaudio numpy pydantic triton"

# ADDITIONAL FIX: Install packages globally as fallback
RUN pip3 install huggingface_hub transformers torch torchaudio numpy pydantic triton

# MOSHI FIX: Install moshi package from PyPI (much simpler!)
RUN pip3 install -U moshi
RUN /bin/bash -c "source .venv/bin/activate && pip install -U moshi"
RUN uv pip install moshi

# Set Python path to include both global and venv locations
ENV PYTHONPATH="/app/.venv/lib/python3.10/site-packages:/usr/local/lib/python3.10/dist-packages:$PYTHONPATH"

# Create a comprehensive startup script
RUN echo '#!/bin/bash' > /app/start.sh && \
    echo 'set -ex' >> /app/start.sh && \
    echo 'export PATH="/root/.cargo/bin:$PATH"' >> /app/start.sh && \
    echo 'export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH' >> /app/start.sh && \
    echo 'export PYTHONPATH="/app/.venv/lib/python3.10/site-packages:/usr/local/lib/python3.10/dist-packages:$PYTHONPATH"' >> /app/start.sh && \
    echo 'export TORCH_COMPILE_DISABLE=1' >> /app/start.sh && \
    echo 'python3 -c "import torch._dynamo; torch._dynamo.config.suppress_errors = True" || true' >> /app/start.sh && \
    echo 'cd /app' >> /app/start.sh && \
    echo '# Install missing packages at runtime as fallback' >> /app/start.sh && \
    echo 'pip3 install huggingface_hub transformers torch torchaudio numpy pydantic triton || true' >> /app/start.sh && \
    echo 'pip3 install -U moshi || true' >> /app/start.sh && \
    echo 'uvx --from "huggingface_hub[cli]" huggingface-cli login --token $HUGGING_FACE_HUB_TOKEN' >> /app/start.sh && \
    echo 'CARGO_TARGET_DIR=/app/target cargo install --features cuda moshi-server@0.6.3' >> /app/start.sh && \
    echo 'source .venv/bin/activate' >> /app/start.sh && \
    echo '/root/.cargo/bin/moshi-server "$@"' >> /app/start.sh && \
    chmod +x /app/start.sh

# Use the comprehensive startup script
ENTRYPOINT ["/app/start.sh"]