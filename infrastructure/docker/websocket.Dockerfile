# VOIID WebSocket image.
FROM node:20-slim
WORKDIR /app
COPY package.json ./
COPY backend/websocket ./backend/websocket
RUN npm install --workspaces --include-workspace-root || npm install
WORKDIR /app/backend/websocket
EXPOSE 4001
CMD ["npm", "run", "dev"]
