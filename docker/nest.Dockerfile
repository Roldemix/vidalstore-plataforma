FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund
COPY . .
RUN npm run build && npm prune --omit=dev
ENV NODE_ENV=production
CMD ["node", "dist/main"]
