#!/bin/sh
set -euxo pipefail

# significant credits to docker-nginx-letsencrypt-simple: Copyright (c) 2020 Sebastian Hiebl
## https://github.com/bastidest/docker-nginx-letsencrypt-simple/blob/master/src/start.sh

# required evars
# NGINX_LE_EMAIL: email to use for certbot reg
# NGINX_DOMAIN_TLD_NAME: example.com
# NGINX_DOMAIN_FULL_NAME: www.example.com
# volume mount points
#   - /var/www/certbot
#   - /etc/letsencrypt

# optional evars
# - LE_GENERATE_STAGING_CERT: true/false (if set/non-empty, 
# - NGINX_LE_DISABLE: if this is set, it will end the loop and exit (or not enter the loop, if exists on startup)

if [[ -z "$NGINX_LE_EMAIL" ]] ; then
    echo "An email is required for letsencrypt (NGINX_LE_EMAIL)"
    exit 1
fi
if [[ -z "$NGINX_DOMAIN_TLD_NAME" ]] ; then
    echo "An the TLD name is required (NGINX_DOMAIN_TLD_NAME) [e.g., example.com]"
    exit 1
fi

CERTBOT_DIR=/var/www/certbot
LE_DIR=/etc/letsencrypt
LE_LIVE_DIR="$LE_DIR/live/$NGINX_DOMAIN_TLD_NAME"
FULLCHAIN_PATH="$LE_LIVE_DIR/fullchain.pem"
PRIVKEY_PATH="$LE_LIVE_DIR/privkey.pem"
DHPARAM_PATH=/etc/letsencrypt/ssl-dhparams.pem

NGINX_DOMAIN_KEY_PEM_URI=$PRIVKEY_PATH
NGINX_DOMAIN_CERT_PEM_URI=$FULLCHAIN_PATH

# Create the parent directories if they do not exist
mkdir -p "$CERTBOT_DIR"
echo mkdir -p "$CERTBOT_DIR"
mkdir -p "$LE_DIR"
echo mkdir -p "$LE_DIR"

# generate dhparams if they don't exist
if ! [[ -f "$DHPARAM_PATH" ]] ; then
    openssl dhparam -out "$DHPARAM_PATH" 2048 || { echo "Failed to generate dhparams" ; exit 1 ; }
    echo "Generated dh params @ $DHPARAM_PATH"
else
    echo "Did not generate dh params because they already exist @ $DHPARAM_PATH"
fi

# Replace placeholders with environment variable values
envsubst '$NGINX_DOMAIN_TLD_NAME,$NGINX_DOMAIN_FULL_NAME,$NGINX_DOMAIN_CERT_PEM_URI,$NGINX_DOMAIN_KEY_PEM_URI,$DJANGO_MEDIA_URL,$DJANGO_MEDIA_ROOT,$DJANGO_STATIC_URL,$DJANGO_STATIC_ROOT,$NGINX_PROXY_PASS_URI' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/nginx.conf
echo "Generated /etc/nginx/nginx.conf from template."
cat /etc/nginx/nginx.conf

SELF_SIGNED_SIGNET=__tide__

# if the fullchain or the privkey does not exist, generate some mock certificates
if [[ ! -f "$FULLCHAIN_PATH" || ! -f "$PRIVKEY_PATH" ]] ; then
    set +e
    rm -f "$FULLCHAIN_PATH"
    rm -f "$PRIVKEY_PATH"
    set -e

    mkdir -p "$LE_LIVE_DIR"
    
    (
    echo "US" # Country Name (2 letter code)
    echo "Texas" # State or Province Name
    echo "My city" # Locality Name
    echo "$SELF_SIGNED_SIGNET" # Organization Name
    echo "My department" # Organizational Unit Name
    echo "$NGINX_DOMAIN_TLD_NAME" # Common Name (e.g., domain name)
    echo "" # Email Address (empty in this case)
    ) | openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$PRIVKEY_PATH" -out "$FULLCHAIN_PATH"
fi

nginx -g 'daemon off;' &
NGINX_PID=$!
sleep 5s
echo 'nginx started, pid = $NGINX_PID'

function clean_letsencrypt_directories() {
    echo "cleaning all let's encrypt directories"
    find "$LE_DIR" -mindepth 1 -type d -exec rm -rf {} +
}

(while [[ -z "${NGINX_LE_DISABLE:-}" ]] ; do
     if openssl x509 -noout -text -in "$FULLCHAIN_PATH" | grep "$SELF_SIGNED_SIGNET"; then
        echo "deleting self signed certificates in 'live' directory"
        clean_letsencrypt_directories
     fi

     if [[ -z "${LE_GENERATE_STAGING_CERT:-}" ]] && openssl x509 -noout -text -in "$FULLCHAIN_PATH" | grep 'Fake LE'; then
        echo "a non testing certificate was requested, but testing certificate still exists. removing it."
        clean_letsencrypt_directories
     fi
     
     if ! certbot certonly --webroot --noninteractive --renew-with-new-domains --expand ${LE_GENERATE_STAGING_CERT:+--test-cert} --agree-tos -m "$NGINX_LE_EMAIL" -d "$NGINX_DOMAIN_TLD_NAME,$NGINX_DOMAIN_FULL_NAME" --webroot-path "$CERTBOT_DIR" ; then
        echo "failed to renew certificates"
     else
        echo "reloading nginx..."
        nginx -s reload
     fi

     echo "sleeping for 24h..."
     sleep 24h
 done) &
LOOP_PID=$!

wait $NGINX_PID
kill $LOOP_PID