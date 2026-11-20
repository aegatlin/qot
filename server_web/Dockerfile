# Release image for the qot sync server. Build from the repo root (it
# needs core/ and core_nif/ for the NIF):
#   docker build -f server_web/Dockerfile -t qot-server .
# Versions match mise.toml (Rust 1.98.1, Elixir 1.20.5, Erlang 29.1.2);
# bump them together.
ARG RUST_VERSION=1.98.1
ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261027-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# 1. qot_core as the server's NIF (core_nif/, Qot.Core), on the Debian the
#    runner uses so the C library matches.
FROM rust:${RUST_VERSION}-slim-trixie AS core
WORKDIR /repo
# The whole Cargo workspace has to be present for cargo to load it.
COPY Cargo.toml Cargo.lock ./
COPY core core
COPY core_ffi core_ffi
COPY core_wasm core_wasm
COPY core_nif core_nif
COPY client_cli client_cli
RUN cargo build --release --locked -p qot_nif

# 2. The Elixir release.
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="prod"
# Qot.Core loads the NIF built above instead of compiling it (no Rust here).
ENV QOT_NIF_PREBUILT="1"

# Dependencies first, so code changes don't refetch them.
COPY server_web/mix.exs server_web/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY server_web/config/config.exs server_web/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY server_web/priv priv
COPY --from=core /repo/target/release/libqot_nif.so priv/native/qot_nif.so
COPY server_web/lib lib
RUN mix compile

# runtime.exs is read at boot, so changing it doesn't recompile.
COPY server_web/config/runtime.exs config/
COPY server_web/rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app
ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/qot ./

USER nobody

# Migrations are a separate step (bin/migrate), run by the platform before
# the new version takes traffic, so a failed migration fails the deploy.
CMD ["/app/bin/server"]
