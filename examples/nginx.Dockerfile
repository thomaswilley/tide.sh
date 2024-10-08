# Use the official Nginx image as the base
FROM nginx:latest
#
# entrypoint for initialization should be mounted as a volume
# certbot output should be at /var/www/certbot
# letsencrypt output should be at /etc/letsencrypt
#
# nginx.conf is generated by ./docker_nginx_entrypoint.sh, requiring (from) ./nginx.conf.template
# because for now at least we'll let that manage the letsencrypt evars.

# Install Certbot and other required packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    certbot && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the entrypoint script and nginx template into the image
COPY ./docker_nginx_entrypoint.sh /docker-entrypoint.d/custom-entrypoint.sh
COPY ./nginx.conf.template /etc/nginx/templates/nginx.conf.template

# Ensure the entrypoint script is executable
RUN chmod +x /docker-entrypoint.d/custom-entrypoint.sh

# Create necessary directories and set permissions
RUN mkdir -p /etc/letsencrypt /var/www/certbot && \
    chown -R www-data:www-data /etc/letsencrypt /var/www/certbot

CMD ["bash", "/docker-entrypoint.d/custom-entrypoint.sh"]