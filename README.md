# Docker Containerization: Flask Application

## Overview
This project packages a simple Flask web application into a Docker image so it
runs identically on any machine with Docker installed, independent of the host's
Python version, installed packages, or operating system. It covers writing a
Dockerfile, building an image, running a container with port mapping, managing
the container lifecycle, optimizing the build for size and rebuild speed, and
running the container as an unprivileged user.

The problem containerization solves here is concrete: this app needs Python 3.12
and seven specific package versions. Without a container, running it on another
machine means reproducing that environment by hand. With one, the environment
ships *with* the application as a single artifact.

## Environment
- Windows 11 with WSL2 (Ubuntu)
- Docker Engine with BuildKit (`v0.31.2`)
- Python 3.12.3 on the host (inside a `venv/`), Python 3.12.14 inside the image
- Flask 3.1.3

## Project Structure
```
docker-flask-project/
├── app.py                # The Flask application
├── requirements.txt      # Pinned Python dependencies
├── Dockerfile            # Image build instructions
├── .dockerignore         # Excludes files from the build context
├── .gitignore
├── README.md             # This file
├── screenshots/          # Evidence of each step
└── venv/                 # Host virtual environment (not copied into the image)
```

## The Application

```python
from flask import Flask

app = Flask(__name__)

@app.route("/")
def home():
    return "Hello from inside a Docker container!"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

**`host="0.0.0.0"` is the critical detail.** Flask's default is `127.0.0.1`,
which binds only to the loopback interface. Inside a container, that means the
server would accept connections *from within the container itself* and nowhere
else — port mapping would forward traffic to the container, and Flask would
refuse it. Binding to `0.0.0.0` tells Flask to listen on all network interfaces,
which is what allows traffic arriving from the Docker bridge to reach it.

This is one of the most common reasons a containerized web app appears to start
correctly but returns connection-refused from the host.

## Dependencies

```
blinker==1.9.0
click==8.5.0
Flask==3.1.3
itsdangerous==2.2.0
Jinja2==3.1.6
MarkupSafe==3.0.3
Werkzeug==3.1.9
```

Every version is pinned exactly, including transitive dependencies that Flask
pulls in rather than only `Flask` itself. Two reasons:

1. **Reproducibility.** A build run six months from now installs the same
   versions as today. A floating constraint like `Flask>=3.1` would not.
2. **Cache stability.** Docker caches the `pip install` layer based on the
   contents of `requirements.txt`. Pinned versions mean that file only changes
   when dependencies are deliberately updated, so the layer stays cached across
   ordinary code changes.

## The Dockerfile

```dockerfile
# 1. Base image: Python 3.12, slim variant (smaller than the full image)
FROM python:3.12-slim

# 2. Set the working directory inside the container
WORKDIR /app

# 3. Copy only the dependency file first (not the whole app yet)
COPY requirements.txt .

# 4. Install dependencies
#    Runs as root because writing to system site-packages requires it.
RUN pip install --no-cache-dir -r requirements.txt

# 5. Create an unprivileged user to run the application
RUN useradd --create-home --shell /bin/bash appuser \
    && chown -R appuser:appuser /app

# 6. Copy the application code, owned by the unprivileged user
COPY --chown=appuser:appuser . .

# 7. Drop privileges. Everything from here on runs as appuser, including CMD.
USER appuser

# 8. Document which port the container listens on
EXPOSE 5000

# 9. The command that runs when the container starts
CMD ["python", "app.py"]
```

### Line by line

**`FROM python:3.12-slim`** — the base image every subsequent layer builds on.
The `slim` variant ships a minimal Debian userland with Python, omitting
documentation, build toolchains, and packages a running app does not need. The
full `python:3.12` image is several times larger.

**`WORKDIR /app`** — sets the working directory for all following instructions
and for the container at runtime. Without it, every `COPY` and the final `CMD`
would need absolute paths, and the app would land in the filesystem root.

**`COPY requirements.txt .` before `COPY . .`** — this ordering is the single
most important performance decision in the file, explained under
[Build optimization](#build-optimization) below.

**`RUN pip install --no-cache-dir -r requirements.txt`** — `--no-cache-dir`
stops pip from retaining downloaded wheels in `~/.cache/pip`. That cache exists
to speed up *future* installs on a long-lived machine; inside an image layer it
is dead weight that is never read again, so it is pure size overhead.

**`RUN useradd ... && chown`, `COPY --chown`, `USER appuser`** — the privilege
drop, explained in [Running as a non-root user](#running-as-a-non-root-user).

**`EXPOSE 5000`** — documentation, not behaviour. It records which port the
image expects to serve on, visible via `docker inspect`. It does **not** open or
publish the port — `-p` at run time does that. An image with `EXPOSE` and no
`-p` is unreachable from the host.

**`CMD ["python", "app.py"]`** — the default command run when a container starts.
The JSON array ("exec form") runs the binary directly rather than wrapping it in
a shell, which means the process receives signals properly — relevant because
`docker stop` sends `SIGTERM`, and a shell-wrapped process may not forward it.

## Running as a non-root user

By default, processes inside a container run as `root`. That root is namespaced
and not equivalent to root on the host, but it is still the wrong default: if the
application is compromised, root inside the container is a materially better
position from which to attempt a container escape, write to mounted volumes, or
install tooling than an unprivileged account would be. Dropping privileges is
inexpensive defense in depth.

Three ordering details make this work correctly:

**`USER` comes after `pip install`.** Installing into system site-packages
requires write access to a root-owned directory. Switching users before the
install makes it fail with a permission error.

**`COPY --chown=appuser:appuser . .`** — without this, copied files are owned by
root. The application can still *read* them, but any runtime write (a log file, a
SQLite database, a cache directory) would fail. Setting ownership at copy time is
cheaper than a separate `chown` layer, which would duplicate every file's storage
in a new layer.

**`USER` comes before `CMD`.** `USER` applies to every instruction *after* it,
and determines the identity of the container's main process. Placed after `CMD`
it would have no effect on the running application at all.

### A constraint worth knowing

Unprivileged users cannot bind to ports below 1024. This app uses port 5000, so
there is no issue. An app serving on port 80 inside the container would fail to
start as a non-root user — the usual solutions are to listen on a high port
internally and map it (`-p 80:8080`), or to grant the
`CAP_NET_BIND_SERVICE` capability explicitly.

### Verifying it worked

```bash
docker exec flask-container whoami
```
```
appuser
```

```bash
docker exec flask-container id
```
```
uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)
```

A `uid` of `1000` rather than `0` confirms the process is unprivileged.

## The .dockerignore

```
venv/
__pycache__/
*.pyc
.git/
.gitignore
screenshots/
docs/
*.md
.env
```

Before any instruction runs, Docker packages the build context — everything in
the project directory — and sends it to the daemon. Without this file, `COPY . .`
would copy `venv/` (a host-specific virtual environment that is useless inside a
container that has its own Python), the entire `.git/` history, and the
`screenshots/` evidence folder into the image.

The measured effect is in the optimization section: the application layer is
**20.5 kB**.

Excluding `.env` is a habit worth keeping even though this project has no secrets:
anything copied into an image layer is recoverable by anyone who can pull that
image, including after a later instruction deletes it.

## Build and run

```bash
# Build the image, tagging it flask-docker-app
docker build -t flask-docker-app .

# Run a container in the background with port 5000 published
docker run -d -p 5000:5000 --name flask-container flask-docker-app

# Confirm it is running
docker ps
```

### What the run flags do
| Flag | Meaning |
|---|---|
| `-d` | Detached — runs in the background instead of occupying the terminal |
| `-p 5000:5000` | Publishes `host_port:container_port`, forwarding host traffic into the container |
| `--name flask-container` | A fixed, memorable name instead of a Docker-generated random one |

`-p` is what makes `EXPOSE 5000` usable. Container networking is isolated by
default — a deliberate security boundary, not an obstacle — and `-p` is the
explicit opt-in that punches a hole through it.

## Verification

```bash
curl http://localhost:5000
```
```
Hello from inside a Docker container!
```

```bash
docker logs flask-container
```
```
 * Serving Flask app 'app'
 * Debug mode: off
WARNING: This is a development server. Do not use it in a production deployment.
 * Running on all addresses (0.0.0.0)
 * Running on http://127.0.0.1:5000
 * Running on http://172.17.0.2:5000
172.17.0.1 - - [01/Oct/2026 08:40:43] "GET / HTTP/1.1" 200 -
```

The source IP in the access log, **`172.17.0.1`**, is the Docker bridge gateway —
the host's address *as seen from inside the container*. That is the proof the
request genuinely crossed the host/container boundary through the port mapping,
rather than hitting some other process already listening on port 5000.

The container's own address, `172.17.0.2`, confirms it is attached to the default
bridge network.

**Note on the development-server warning.** Flask's built-in server is
single-threaded and not hardened for production traffic. A production image would
replace `CMD ["python", "app.py"]` with a WSGI server such as Gunicorn
(`CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]`). It is left as-is here
because the assignment's scope is containerization, not production serving — but
the warning is accurate and should not be ignored in a real deployment.

## Container lifecycle

```bash
docker stop flask-container    # graceful shutdown (SIGTERM, then SIGKILL on timeout)
docker ps -a                   # list ALL containers, including stopped ones
docker start flask-container   # restart the same container
docker rm flask-container      # delete the container (must be stopped, or use -f)
```

Two distinctions worth holding onto:

**`docker ps` vs `docker ps -a`.** Plain `ps` shows only *running* containers. A
stopped container vanishes from that listing while still existing on disk, which
is a common source of "where did my container go".

**`docker run` vs `docker start`.** `run` creates a *new* container from an image
every time it is called. `start` resumes an existing one. This is why re-running
`docker run --name flask-container ...` without removing the previous container
fails with `Conflict. The container name "/flask-container" is already in use` —
the name is taken by the stopped container, which still exists.

Stopping the container also tears down the port mapping, so `curl
http://localhost:5000` fails with connection-refused while it is stopped, and
succeeds again after `docker start` — with no rebuild required, because the image
and the container filesystem are unchanged.

## Build optimization

### Layer caching through instruction order

Docker builds images as a stack of layers, one per instruction, and caches each
one. When a layer's inputs change, that layer and **every layer after it** are
rebuilt. Instruction order therefore determines how much work an ordinary code
change costs.

The naive ordering:
```dockerfile
COPY . .
RUN pip install -r requirements.txt    # re-runs on EVERY code change
```
Because `COPY . .` includes `app.py`, editing a single line of application code
changes that layer, which invalidates the `pip install` layer below it and
reinstalls every dependency from scratch.

The ordering used here:
```dockerfile
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=appuser:appuser . .       # only this re-runs on a code change
```
Dependencies change rarely; application code changes constantly. Putting the
rarely-changing step first means the expensive install stays cached.

### Measured result

`docker history flask-docker-app` after editing application code:

| Layer | Size | Created |
|---|---|---|
| `CMD ["python" "app.py"]` | 0 B | 20 seconds ago |
| `EXPOSE [5000/tcp]` | 0 B | 20 seconds ago |
| `COPY . .` | **20.5 kB** | 20 seconds ago |
| `RUN pip install --no-cache-dir -r …` | 15.3 MB | **30 minutes ago** |
| `COPY requirements.txt .` | 12.3 kB | 30 minutes ago |
| `WORKDIR /app` | 8.19 kB | 30 minutes ago |

The timestamp split is the optimization working. Application code changed, the
top three layers rebuilt, and the 15.3 MB dependency install was reused from a
build 30 minutes earlier. Rebuild time after a code change: **4.2 seconds**.

### Size reduction

| | Before `.dockerignore` | After |
|---|---|---|
| Disk usage | 225 MB | **198 MB** |
| Content size | 54.1 MB | **48.2 MB** |

`CONTENT SIZE` approximates what a registry push or pull transfers; `DISK USAGE`
is the extracted layers on disk plus image-store overhead. The two measure
different things and both are worth watching — the first is distribution cost,
the second is local footprint.

### Where the remaining size actually is

| Source | Size |
|---|---|
| Debian `trixie` base rootfs | 87.6 MB |
| Python 3.12.14 | 41.4 MB |
| apt dependencies | 4.95 MB |
| `pip install` (Flask + deps) | 15.3 MB |
| Application code | 20.5 kB |

Roughly **90% of the image is the base image**, and only ~15 MB comes from
anything this project controls. The application itself is rounding error.

### Alpine: considered and rejected

The obvious next step would be `python:3.12-alpine`, with a base around 50 MB
instead of 134 MB. It is not used here deliberately.

Alpine links against `musl` libc rather than `glibc`. Python packages distributing
precompiled wheels build them against `glibc`, so on Alpine pip often cannot use
the prebuilt wheel and falls back to compiling from source — which requires a
build toolchain in the image, lengthens builds substantially, and can fail
outright. Pure-Python Flask would be fine today, but adding a single dependency
like `psycopg2`, `numpy`, or `pandas` later turns a 50 MB saving into a
significantly worse build. For a project expected to grow, `slim` is the better
default.

### Multi-stage builds: considered and rejected

A multi-stage build compiles dependencies in a full image, then copies only the
installed packages into a slim runtime image, discarding the build toolchain.
It is the standard answer for compiled languages and for Python projects with
C extensions.

Here it would save very little. Nothing in this dependency set compiles — Flask
and its dependencies are pure Python, installed from wheels with no build step —
so there is no build toolchain to discard. The only recoverable weight would be
pip itself and its metadata, a few megabytes against a 198 MB image dominated by
the base layers. The added Dockerfile complexity is not worth that trade for this
project, though it would be the first thing to revisit if a compiled dependency
were introduced.

## Troubleshooting log

| Problem | Cause | Fix |
|---|---|---|
| `docker run` failed with `pull access denied for flask-docker-app, repository does not exist` even though `docker images` listed the image | Two Docker contexts existed (`default` on a Unix socket, `desktop-linux` on a Windows named pipe). The build and the run resolved against different image stores, so `docker run` could not find the image locally and fell back to attempting a Docker Hub pull. `docker image inspect` confirmed it: `No such image`. | `docker context use default`, then rebuild and run within that one context. `docker context ls` shows which is active; `docker buildx ls` shows which builders are reachable. |
| `touch app.py` did not invalidate the `COPY . .` layer as expected | BuildKit hashes file **contents**, not modification timestamps. `touch` changes only mtime, so the hash was unchanged and the cache hit was correct. | Test cache boundaries with a real content change (`echo "# test" >> app.py`), not `touch`. |
| First build took 77.1 s and appeared slow | 73.4 s of that was `load metadata for docker.io/library/python:3.12-slim` — a registry round trip to resolve the image digest, not build work. | Nothing to fix. The next build took 4.2 s with the same Dockerfile once metadata was cached locally. Diagnose slow builds by reading the per-step timings rather than the total. |

## Commands reference

```bash
# Build
docker build -t flask-docker-app .

# Run
docker run -d -p 5000:5000 --name flask-container flask-docker-app

# Inspect
docker ps                        # running containers
docker ps -a                     # all containers, including stopped
docker images flask-docker-app   # image size
docker history flask-docker-app  # per-layer size breakdown
docker logs flask-container      # application output
docker exec flask-container whoami  # confirm the non-root user

# Lifecycle
docker stop flask-container
docker start flask-container
docker rm flask-container

# Verify
curl http://localhost:5000
```

## Completion Checklist
- [x] **Task 1** — Flask application and `requirements.txt` prepared, with all
      dependencies pinned to exact versions
- [x] **Task 2** — Dockerfile authored with base image, working directory,
      dependency installation, code copy, and startup command
- [x] **Task 3** — Image built and tagged as `flask-docker-app`
- [x] **Task 4** — Container run with `-p 5000:5000`, verified with `curl` and
      confirmed by the bridge-gateway source IP in the access log
- [x] **Task 5** — Lifecycle exercised: `stop`, `start`, `rm`, and the
      run-vs-start distinction
- [x] **Task 6** — Build optimized: slim base image, dependency-before-code layer
      ordering, `--no-cache-dir`, and `.dockerignore`; 225 MB → 198 MB, with a
      4.2 s cached rebuild verified via `docker history` timestamps
- [x] **Security** — Container runs as the unprivileged `appuser` (uid 1000)
      rather than root, verified with `docker exec flask-container whoami`
