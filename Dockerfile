# syntax=docker/dockerfile:1
# Multi-stage build for the rest-express trading dashboard.
#
# The Node server spawns a small Python service at runtime (server/python_service.py
# and an inline market-data block), so the image needs both a Node runtime and a
# Python 3 interpreter. Rather than apt-installing one onto the other, the runtime is
# based on the official python:3.11-slim image (python3 + pip already present) and the
# self-contained Node binary is copied in from the official node image. Both are
# bookworm/glibc, and `node` links only glibc + libstdc++/libgcc, which python-slim
# already ships — so no OS packages are installed at all.
#
# Base images are pinned by multi-arch index digest for reproducible, supply-chain-safe
# builds (this image runs alongside a wallet private key, so a silently-moving base tag
# is not acceptable). Refresh the digests deliberately via a dependency bump:
#   docker buildx imagetools inspect node:20-bookworm-slim
#   docker buildx imagetools inspect python:3.11-slim-bookworm
#
# No secrets are baked in: exchange keys, RPC URLs and wallet keys are runtime env only.

# ---------------------------------------------------------------------------
# Stage 1 — build the client (Vite -> dist/public) and bundle the server
#           (esbuild -> dist/index.js). Needs devDependencies, so a full
#           `npm ci` (NOT --omit=dev).
# ---------------------------------------------------------------------------
FROM node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 AS builder

WORKDIR /app

# Install deps first for better layer caching.
COPY package.json package-lock.json ./
RUN npm ci

# Copy the rest of the source and build.
COPY . .
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2 — production runtime (python-slim base + copied-in node binary)
# ---------------------------------------------------------------------------
FROM python:3.11-slim-bookworm@sha256:a36c24f9cbdf4fd0f52d67f0823eeac19c2028c637cecc392d97f980d4fec56b AS production

ENV NODE_ENV=production \
    PORT=5000

WORKDIR /app

# Node runtime binary (self-contained). npm is not needed at runtime because the
# container runs `node dist/index.js` directly. Pinned to the same digest as the
# builder stage so the runtime node matches the one that built the bundle.
COPY --from=node:20-bookworm-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0 /usr/local/bin/node /usr/local/bin/node

# Python deps for the services the Node server actually spawns
# (python_service.py -> redis.asyncio, inline block -> requests).
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Non-root runtime user.
RUN groupadd -g 1001 nodejs \
    && useradd -u 1001 -g nodejs -m -s /usr/sbin/nologin trading

# The esbuild bundle imports vite (and its config's plugins) eagerly at startup,
# so the full node_modules from the build stage is required at runtime.
COPY --from=builder --chown=trading:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=trading:nodejs /app/dist ./dist
COPY --from=builder --chown=trading:nodejs /app/package.json ./package.json

# python_service.py is spawned with cwd = <process.cwd()>/server, i.e. /app/server.
COPY --chown=trading:nodejs server/*.py ./server/

# Writable logs dir referenced by the app config.
RUN mkdir -p /app/logs && chown trading:nodejs /app/logs

USER trading

# The server always listens on 5000 (hardcoded in server/index.ts).
EXPOSE 5000

# Health check hits the Express health route using Node's built-in fetch,
# so no curl/wget is needed in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:5000/api/system/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
