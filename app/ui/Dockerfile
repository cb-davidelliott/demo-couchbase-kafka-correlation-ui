FROM node:18.20.4-alpine3.20

# Install build dependencies for compiling native C/C++ packages like couchbase SDK (if wheels are not matching)
RUN apk add --no-cache python3 make g++ git

WORKDIR /app

# Copy dependency manifests
COPY package*.json .

# Install dependencies from the lockfile
RUN npm ci --omit=dev

# Copy server code and public static HTML/CSS asset files
COPY server.js .
COPY public/ ./public/

EXPOSE 3000

ENV PORT=3000

CMD ["npm", "start"]
