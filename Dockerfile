# ---------- Stage 1: Builder ----------
# Same Node major and same Debian base as the runtime image below, so
# anything npm installs here behaves identically at runtime. Node 24 is the
# current LTS (Node 20 reached end-of-life in April 2026).
FROM node:24-bookworm-slim AS builder
WORKDIR /app

# Install production dependencies only
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy app source
COPY src ./src

# ---------- Stage 2: Runtime (Distroless, non-root) ----------
# :nonroot runs as uid/gid 65532 — matches runAsUser/runAsGroup in
# gitops/apps/kind-api/base/rollout.yaml.
FROM gcr.io/distroless/nodejs24-debian12:nonroot
WORKDIR /app
ENV NODE_ENV=production

# Copy only production files
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/src ./src

EXPOSE 3000

# Distroless's entrypoint is `node`, so this is the script argument.
CMD ["src/index.js"]
