# Serverpod deploy on SiteHost

Builds a Serverpod server on GitHub Actions, then SSHes into a stock Nginx + PHP container, installs a localhost reverse proxy and a supervisord program, and publishes the compiled bundle. The container does not get a Dart SDK.

Pin `@v1`.

This is for another project's Serverpod app. Talaria's own API stays on its `custom_dart` image and the Nginx Proxy container in front of `api.newtalaria.com`.

The container stays on the free **Nginx + PHP 8.5** image (Noble). Give that container the project's domain and SSL in the SiteHost panel. SiteHost's built-in edge sends the domain to port 80. Nginx on the container proxies to Serverpod on `127.0.0.1:8080`, including WebSocket upgrade. A `www` container does not publish port 8080 to other containers, so this project does not create a separate Nginx Proxy container.

PHP-FPM stays running because the stock image owns that process. Size the container for Serverpod.

## What survives a restart

The bundle lives under `/container/application/releases/<sha>/`, and `current` is a symlink to the live release. The supervisor program file lives under `/container/config`. Those paths are volumes, so Stop, Start, reboot, and a stock image upgrade keep them.

Anything installed with apt, including a Dart SDK, lives in the container's writable layer. A restart keeps that layer. A stock image upgrade, recreate, or clone discards it. This action does not install Dart. The next deploy writes the Nginx site and the supervisor program again, which repairs an image upgrade that replaced those files outside the volumes.

## Set up a site

Create one Nginx + PHP 8.5 container for this app. Attach the domain and turn on SSL. In the container environment, set Serverpod's own names:

- `SERVERPOD_DATABASE_HOST`, `SERVERPOD_DATABASE_PORT`, `SERVERPOD_DATABASE_NAME`, `SERVERPOD_DATABASE_USER`, `SERVERPOD_DATABASE_REQUIRE_SSL`
- `SERVERPOD_PASSWORD_database` for the database password
- any other `SERVERPOD_PASSWORD_<camelCase>` key the app reads

An SSH session does not see those variables. The process inherits them from supervisord, which was started with the container environment.

Secrets and variables follow the Silverstripe and Flutter deploys. If one of those actions is already in the organisation, reuse `SITEHOST_SSH_PRIVATE_KEY`, `SITEHOST_SSH_HOST`, `SITEHOST_SSH_HOST_FINGERPRINT`, and `SITEHOST_SSH_PORT`. The Silverstripe README has the key ceremony.

Create a GitHub environment per container (`production`, and `test` when there is one). Put these variables on the environment:

| Name | When | Example |
| --- | --- | --- |
| `SITEHOST_SSH_USER` | Every deploy | `example` |
| `SITEHOST_SITE_URL` | Every deploy | `https://api.example.com` |

`SITEHOST_SITE_URL` must start with `http://` or `https://`.

| Name | Default |
| --- | --- |
| `SITEHOST_APP_PATH` | `/container/application` |

Optional file `/container/config/serverpod/passwords.yaml` on the container. When it exists, each publish symlinks it into the release as `config/passwords.yaml` and leaves the file in place across deploys. It must be readable by `www-data` (uid 33). Prefer the `SERVERPOD_*` environment variables when the panel can hold the values.

The SSH user must be able to write `/container/config/nginx`, `/container/config/supervisord.conf`, and `/container/config/serverpod`, and reload Nginx and supervisord. Leave the config directory writable when you create the user.

`config/passwords.yaml` in the server package fails the build. `passwords.yaml.example` is copied.

## Add the workflow

Save this as `.github/workflows/deploy.yml` in the app repository. Pass the key by name. `secrets: inherit` does not reach a reusable workflow in another organisation.

```yaml
name: Deploy Serverpod to SiteHost

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Container to deploy
        type: choice
        required: true
        options:
          - production
      emergency_override:
        description: Production only. Deploy a ref that is not main or a tag.
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  deploy:
    uses: newtalaria/sitehost-serverpod/.github/workflows/deploy.yml@v1
    with:
      environment: ${{ inputs.environment }}
      emergency_override: ${{ inputs.emergency_override }}
      require_main_or_tag: ${{ inputs.environment == 'production' }}
      server_path: server
      dart_version: "3.12.2"
      apply_migrations: true
    secrets:
      SITEHOST_SSH_PRIVATE_KEY: ${{ secrets.SITEHOST_SSH_PRIVATE_KEY }}
```

The shared workflow queues deploys with group `sitehost-serverpod-${{ github.repository }}-${{ inputs.environment }}`. Leave that group off the caller. GitHub cancels the run as a deadlock when the caller and the called workflow lock one group.

## What each run does

1. Check out the app and run `dart pub get`, then `dart build cli --target bin/main.dart --output build`, on the runner.
2. Assemble a release tree: the AOT bundle with `bin/main` renamed to `bin/server`, public config, `web/`, `migrations/`, and `lib/src/generated/protocol.yaml`.
3. SSH in and install hosting if it is missing or out of date: an Nginx site that proxies to `127.0.0.1:8080` with `Upgrade` and `Connection`, and a supervisord program `serverpod` that runs `current/bin/server` as `www-data`. `nginx -t` and `supervisorctl reread` must succeed. A failure restores the previous Nginx and supervisor files.
4. Upload the tree to `/container/application/releases/<sha>/`.
5. Point `current` at that release, symlink `passwords.yaml` when the container has one, and `supervisorctl restart serverpod`. The first run moves an existing `current` directory to `releases/previous`. A failed restart points `current` back at the previous release.
6. Request `SITEHOST_SITE_URL`. A response below HTTP 500 means the proxy reached the process. 502, 503, and 504 retry, then fail.
7. On smoke failure, point `current` back at the previous release and restart it.

Insights on port 8081 stays on the machine. Set `web_path` (for example `/app`) to proxy that prefix to the Serverpod web server on `127.0.0.1:8082`. The default is the API only.

## Inputs

| Input | Default | Effect |
| --- | --- | --- |
| `environment` | required | GitHub environment for this container. |
| `server_path` | `server` | Serverpod server package, relative to the repository. |
| `dart_version` | `3.12.2` | Dart SDK on the runner. |
| `apply_migrations` | `true` | Pass `--apply-migrations` when the process starts. |
| `web_path` | empty | One location, such as `/app`, proxied to port 8082. |
| `keep_releases` | `5` | Sha directories kept under `releases/`. |
| `require_main_or_tag` | `false` | Fail unless the ref is `main` or a tag. |
| `test_rollback` | `false` | Finish the deploy, then restore the previous release. |
