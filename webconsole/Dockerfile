FROM oven/bun:1.3 AS build
WORKDIR /app
COPY package.json bun.lock tsconfig.json vite.config.ts index.html ./
RUN bun install --frozen-lockfile
COPY src ./src
COPY server ./server
RUN bun run build

FROM oven/bun:1.3-slim
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/server ./server
COPY --from=build /app/package.json ./package.json
EXPOSE 8080
CMD ["bun", "run", "server/index.ts"]
