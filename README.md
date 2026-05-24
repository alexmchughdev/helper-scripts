# setupvnc.sh

Sets up `socat` TCP forwarders that expose internal container ports on your LAN.
**Every run creates two forwards:**

| Forward     | Container            | Route                                  |
|-------------|----------------------|----------------------------------------|
| `vnc`       | qemu container       | `<LAN-IP>:5900` → `<container>:5900`    |
| `fileshare` | `fileshare-external` | `<LAN-IP>:80` → `<container>:80`        |

```
VNC client  ──►  <LAN-IP>:5900  ──[socat]──►  <qemu container>:5900
browser     ──►  <LAN-IP>:80    ──[socat]──►  <fileshare-external>:80
```

## Where to run it

Run it from the **admin tools container**, via the Portainer console
(Containers → admin tools container → Console → `/bin/bash`, connect).

That is the only environment this script is built for. It is host-networked and
has the Docker socket, which is exactly what the script needs. It is not run on
the host, over SSH, or anywhere else.

## Install

1. Upload `setupvnc.sh` to `/var/lib` on the host via the file browser.
2. Open the admin tools container's console in Portainer — the host's
   `/var/lib` is mounted there at `/host/var/lib`.
3. Make it executable and run it:

   ```sh
   chmod +x /host/var/lib/setupvnc.sh && /host/var/lib/setupvnc.sh
   ```

`socat` is installed automatically via `apt-get` on first run if it isn't
already present.

## Usage

Interactive — detects/confirms the LAN IP, then sets up both forwards:

```sh
./setupvnc.sh
```

Non-interactive — pass the LAN details up front:

```sh
./setupvnc.sh --lan-ip 192.168.1.50 --lan-port 5900 --container-port 5900
```

Stop both forwarders:

```sh
./setupvnc.sh --stop
```

## Options

| Option                    | Description                                                  | Default |
|---------------------------|--------------------------------------------------------------|---------|
| `--lan-ip <ip>`           | LAN IP for `socat` to bind to. Prompts if omitted.           | —       |
| `--lan-port <port>`       | LAN port for the **VNC** forward.                            | `5900`  |
| `--container-port <port>` | VNC port inside the **qemu** container.                      | `5900`  |
| `--filter <name>`         | Substring matched against `docker ps` to find the **qemu** container. | `qemu`  |
| `--stop`                  | Kill every `socat` forwarder this script started.            | —       |
| `-h`, `--help`            | Show usage.                                                  | —       |

The flags above tune the **VNC** forward only. The `fileshare-external` forward
is fixed at port `80`; to change it, edit `FILESHARE_FILTER` / `FILESHARE_PORT`
at the top of the script.

## How it works

1. Detects the LAN IP — `eth0` first, then the source IP of the route to the
   internet — and asks you to confirm. Docker-bridge and link-local addresses
   are rejected.
2. For each forward (`vnc`, then `fileshare`): finds the container by name
   substring, reads its `172.x.x.x` bridge IP, checks the LAN port is free, and
   launches `socat` with `nohup` so it survives the script exiting.
3. Both PIDs go into one PID file; `--stop` kills all of them.

If one forward fails, the other is still attempted — the script just exits
non-zero and reports which failed. It also refuses to start if forwarders from
a previous run are still alive; run `--stop` first.

## Files

| Path                                  | Purpose                                       |
|---------------------------------------|-----------------------------------------------|
| `/tmp/setup-vnc-socat.pid`            | PIDs of the running `socat` processes (one per line). |
| `/tmp/setup-vnc-socat-vnc.log`        | Output of the VNC forward.                    |
| `/tmp/setup-vnc-socat-fileshare.log`  | Output of the fileshare forward.              |

## Troubleshooting

- **`No running container matched ...`** — the script prints what *is* running.
  For the qemu container, pass a substring via `--filter`; for the fileshare
  container, fix `FILESHARE_FILTER` at the top of the script.
- **`Something is already listening on port ...`** — stop that listener, or
  (VNC only) pick another port with `--lan-port`.
- **`Forwarders from a previous run are still active`** — run `./setupvnc.sh
  --stop` before starting again.
- **`socat failed to start`** — check the per-forward log in `/tmp/`; usually
  the LAN IP isn't actually assigned to an interface in the container.
