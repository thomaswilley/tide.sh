# tide_finalbootstrap.sh
#!/bin/bash

# add any cleanup or startup you'd like here
## ~~
echo 'hello' > /tmp/world.txt


## ~~
# it is not reccomended to modify the below.
echo "TIDE_PUBLIC_IP=$(ip addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | awk 'NR==1{ print $1 }')" >> $HOME/.env

set -a
source $HOME/.env
set +a

echo "
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            tide.sh is up. see $HOME/.env
            $NGINX_PUBLIC_IP
            $NGINX_DOMAIN_TLD_NAME
            use docker/docker compose from here on the remote as needed.
        ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
"