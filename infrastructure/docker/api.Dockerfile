# VOIID API image. Built from monorepo root so workspace deps resolve.
FROM node:20-slim
WORKDIR /app
COPY package.json ./
COPY packages ./packages
COPY backend/api ./backend/api
RUN npm install --workspaces --include-workspace-root || npm install
WORKDIR /app/backend/api
EXPOSE 4000
CMD ["npm", "run", "dev"]
