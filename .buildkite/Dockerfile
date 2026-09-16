FROM koalaman/shellcheck:v0.11.0 AS shellcheck
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 jq \
    && rm -rf /var/lib/apt/lists/*
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
WORKDIR /work
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts
COPY . .
CMD ["npm", "test"]
