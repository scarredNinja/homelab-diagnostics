FROM nginx:alpine

# Copy dashboard static files to nginx html directory
COPY dashboard/ /usr/share/nginx/html/

EXPOSE 80
