# setupvnc.sh

Sets up a `socat` TCP forwarder that exposes a qemu container's internal VNC
port on your LAN, so you can connect a VNC client to it from another machine.

```
VNC client  ──►  <LAN-IP>:<LAN-PORT>  ──[socat]──►  <container 172.x.x.x>:5900
```

## Where to run it

Run it from the **admin tools container**, via the Portainer console
(Containers → admin tools container → Console → `/bin/bash`, connect).

That is the only environment this script is built for. It is host-networked and
has the Docker socket, which is exactly what the script needs. It is not run on
the host, over SSH, or anywhere else.

## Install

Place `setupvnc.sh` in the admin tools container and make it executable:

```sh
chmod +x setupvnc.sh
```

`socat` is installed automatically via `apt-get` on first run if it isn't
already present.

## Usage

Interactive — it finds the container, detects a LAN IP, and asks you to confirm:

```sh
./setupvnc.sh
```

Non-interactive — pass everything up front:

```sh
./setupvnc.sh --lan-ip 192.168.1.50 --lan-port 5900 --container-port 5900
```

Stop the forwarder started earlier:

```sh
./setupvnc.sh --stop
```

## Options

| Option                    | Description                                                  | Default |
|---------------------------|--------------------------------------------------------------|---------|
| `--lan-ip <ip>`           | LAN IP for `socat` to bind to. Prompts if omitted.           | —       |
| `--lan-port <port>`       | Port to expose on the LAN.                                   | `5900`  |
| `--container-port <port>` | VNC port inside the target container.                        | `5900`  |
| `--filter <name>`         | Substring matched against `docker ps` to find the container. | `qemu`  |
| `--stop`                  | Kill the `socat` forwarder this script started.              | —       |
| `-h`, `--help`            | Show usage.                                                  | —       |

## How it works

1. Finds the running container whose `docker ps` line matches `--filter`.
2. Reads its `172.x.x.x` bridge IP from `docker inspect`.
3. Determines the LAN IP — `eth0` first, then the source IP of the route to the
   internet — and asks you to confirm. Docker-bridge and link-local addresses
   are rejected.
4. Refuses to start if something is already listening on the LAN port.
5. Launches `socat` with `nohup` so it survives the script exiting.

## Files

| Path                          | Purpose                                  |
|-------------------------------|------------------------------------------|
| `/tmp/setup-vnc-socat.pid`    | PID of the running `socat` process.       |
| `/tmp/setup-vnc-socat.log`    | `socat` output — check here if it fails.  |

## Troubleshooting

- **`No running container matched 'qemu'`** — the script prints what *is*
  running; pick a substring of the right one and pass it via `--filter`.
- **`Something is already listening on port 5900`** — stop that listener or
  choose another port with `--lan-port`.
- **`socat failed to start`** — see `/tmp/setup-vnc-socat.log`; usually the
  LAN IP isn't actually assigned to an interface in the container.
