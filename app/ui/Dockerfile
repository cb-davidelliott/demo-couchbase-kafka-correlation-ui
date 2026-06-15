FROM node:18-alpine

# Install build dependencies for compiling native C/C++ packages like couchbase SDK (if wheels are not matching)
RUN apk add --no-cache python3 make g++ git

WORKDIR /app

# Copy dependency manifest
COPY package.json .

# Install dependencies (running production clean-install)
RUN npm install --only=production

# Copy server code and public static HTML/CSS asset files
COPY server.js .
COPY public/ ./public/

EXPOSE 3000

ENV PORT=3000

CMD ["npm", "start"]
