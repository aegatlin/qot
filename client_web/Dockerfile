# Release image for the PWA: the static build behind Caddy. Build from the
# repo root (it needs core/ and core_wasm/):
#   docker build -f client_web/Dockerfile -t qot-web .
# Versions match mise.toml; bump them together.
ARG RUST_VERSION=1.98.1
ARG NODE_VERSION=24.22.2
ARG CADDY_VERSION=2.10.2

# 1. qot_core compiled to WebAssembly, with its JS bindings.
FROM rust:${RUST_VERSION}-slim AS core
ARG WASM_BINDGEN_VERSION=0.2.130
ARG BINARYEN_VERSION=version_129
RUN apt-get update -y && apt-get install -y curl ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_* \
    && rustup target add wasm32-unknown-unknown
RUN curl -fsSL "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}/wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin "wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl/wasm-bindgen" \
    && curl -fsSL "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz" \
      | tar -xz -C /opt \
    && ln -s "/opt/binaryen-${BINARYEN_VERSION}/bin/wasm-opt" /usr/local/bin/wasm-opt
WORKDIR /repo
# The whole Cargo workspace has to be present for cargo to load it.
COPY Cargo.toml Cargo.lock ./
COPY core core
COPY core_ffi core_ffi
COPY core_wasm core_wasm
COPY client_cli client_cli
COPY scripts/build-wasm-core scripts/
RUN mkdir client_web && scripts/build-wasm-core --release

# 2. The app.
FROM node:${NODE_VERSION}-slim AS app
WORKDIR /repo/client_web
COPY client_web/package.json client_web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY client_web/ ./
COPY --from=core /repo/client_web/src/core src/core
RUN npm run build

# 3. Served by Caddy. API_URL (the sync API) is read at start.
FROM caddy:${CADDY_VERSION}-alpine
COPY client_web/Caddyfile /etc/caddy/Caddyfile
COPY client_web/bin/web /usr/local/bin/web
COPY --from=app /repo/client_web/dist /srv
ENV PORT=8080
EXPOSE 8080
CMD ["web"]
