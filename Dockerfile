FROM nginx:1.28-alpine

# Remove default Nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy application files
COPY src/ /usr/share/nginx/html/

# Expose application port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]