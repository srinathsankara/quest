FROM node:18-alpine

WORKDIR /app

COPY package.json .
RUN npm install --production

COPY src/ src/
COPY bin/ bin/
RUN chmod +x bin/*

EXPOSE 3000

CMD ["node", "src/000.js"]
