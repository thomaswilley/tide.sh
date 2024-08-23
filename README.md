# tide.sh
tide.sh: ship docker/compose apps to production on digital ocean

This is beta software currently. Tt does work and there are production deployments using it.

# why tide.sh exists

tide.sh was built to ship docker compose-based sites to production while keeping run rate costs (e.g., from hosting) low.

# a typical development flow with tide.sh

0. Create .env.prod (production) and .env.dev (local development)
1. Create compose.yml (production) and dev.compose.yml (local development)
2. Create project (e.g., django start-project)
3. Work locally. dev.compose.yml may just be django and postgres but no nginx, for example. .env.dev is setup and works.
4. Create keys for github (access: your repo for clone/fetch) and digitalocean.com (access: ssh key & droplet actions)
5. Commit git repo to github
6. Complete your .env.prod. Get your domain created if you have one. Decide whether you want test certs or not.
N. _Deploy with tide.sh_ (See below for automation provided by tide.sh)

note: if you develop on windows (e.g., vscode with powershell term), you will want to enter bash in that terminal session within vscode in order to properly run ./tide.sh.

See the ./examples folder of this repo for sample files including:

- compose.yml and .env.prod for a production django application (django, nginx, postgres)
- nginx reverse proxy container configuration that includes letsencrypt SSL with autorenewals used in this application

# what does tide.sh automate

Deploy the first time ```$ ./tide.sh -e .env.prod deploy```
- Register your ssh key
- Create a droplet
- Clone your repo
- Setup the environment variables
- Cleanup (tide_finalbootstrap.sh, which you can customize as you like)

Subsequent changes available on your repo on github can be automatically re-deployed with ```./tide.sh -e .env.prod re-deploy```

Do a complete destroy/re-deploy with ```$ ./tide.sh -e .env.prod deploy --force```

Audit your remote to tune hardness ```./tide.sh -e audit```

Access your production system (e.g., docker compose logs, debugging and fixing your deployment pipeline) with ```$./tide.sh -e .env.prod ssh```

# can I contribute?

Please do! More work is needed. There are currently no guidelines on contributions, all are welcomed.