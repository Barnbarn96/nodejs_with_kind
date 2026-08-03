# FROM node:21-alpine
# WORKDIR /app
# COPY package.json package-lock.json ./
# RUN npm ci --omit=dev
# COPY src ./src
# EXPOSE 3000
# CMD ["node", "src/index.js"]
# ---- Build Stage ----
# ---------- Stage 1: Builder ----------
FROM node:21-alpine AS builder
WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --omit=dev

# Copy app source
COPY src ./src

# ---------- Stage 2: Runtime (Distroless) ----------
FROM gcr.io/distroless/nodejs20
WORKDIR /app

# Copy only production files
COPY --from=builder /app /app

# Distroless sets NODE_ENV=production by default
EXPOSE 3000

# Start the app
CMD ["src/index.js"]

