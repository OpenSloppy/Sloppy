---
layout: doc
title: Relay Deployment and Multi-Instance Access
---

# Relay Deployment and Multi-Instance Access

Sloppy Relay lets local Sloppy installations on different computers reach each other through one public rendezvous server. A typical personal setup uses a work Mac, a home Mac, and a small VPS:

```text
Work Sloppy ── encrypted mesh connection ──┐
                                           ├── VPS Relay
Home Sloppy ── encrypted mesh connection ──┘
```

The VPS routes authenticated mesh envelopes and keeps coordinator state plus eligible pending task and event envelopes. It does not need access to the local Core HTTP ports, project directories, model credentials, or node private keys. Synchronous Core RPC and live streams are not offline-queued.

Use this guide for production deployment and Apple-client behavior. See [SloppyNode Mesh](/guides/mesh) for shared-project ACLs, task lifecycle, RPC methods, and standalone `sloppy-node` commands.

## What the Relay Enables

When both Sloppy installations have joined the same relay, ClientNative can:

- discover the local and remote Sloppy instances;
- switch between named machines;
- show chats and projects from both machines in **All**;
- read and mutate remote agents, chats, projects, and tasks;
- stream agent-session updates;
- open a local terminal for the local instance and a relayed terminal for a remote instance;
- assign a Kanban task to a specific execution machine.

Remote Core requests use the mesh `core.http` RPC. Long-lived agent and terminal traffic uses multiplexed `stream.open`, `stream.chunk`, and `stream.close` envelopes. Resource identifiers are scoped by instance in ClientNative so identical local chat or project IDs do not collide.

## Relay and Mesh Responsibilities

| Component | Responsibility |
| --- | --- |
| VPS relay | Public TLS endpoint, invite acceptance, authenticated WebSocket routing, coordinator state, eligible pending envelopes, and audit data. |
| Work Sloppy | Local Core API, agents, chats, projects, tasks, terminal, node identity, and outbound relay connection. |
| Home Sloppy | Its own Core API and data, with a separate node identity and outbound relay connection. |
| ClientNative | Connects to one local Core, discovers the other Core through mesh, aggregates reads, and routes mutations to an explicit instance. |

The relay is transport infrastructure. Each computer keeps its own Sloppy data and executes work locally. Neither computer needs an inbound public port: both initiate an outbound `wss://` connection to the VPS.

## Requirements

- A Linux VPS with Docker, or Swift 6.2 for a native build.
- A DNS name such as `relay.example.com`, or a stable IP with a pinned TLS certificate.
- Public TCP ports `80` and `443` for certificate issuance and TLS traffic.
- Sloppy builds on the work and home computers that include mesh remote-Core support.
- One persistent disk or Docker volume for relay state.

External relay URLs must use `https://` or `wss://`. Sloppy intentionally rejects plaintext `http://` and `ws://` relay URLs outside loopback.

## IP-only Mobile Pairing

A DNS name is optional when every native client can reach the relay by a stable IP address. A public relay endpoint still requires TLS; advertise the IP endpoint in the runtime config:

```json
{
  "nodeMeshPublicURL": "https://203.0.113.10",
  "clientPublicURL": "https://203.0.113.10",
  "clientAlternateURLs": [
    "http://192.168.1.10:25101"
  ],
  "clientTLSFingerprint": "<sha256 fingerprint without separators>"
}
```

`clientPublicURL` is the Core endpoint placed in mobile setup codes. When it is absent, Sloppy falls back to `nodeMeshPublicURL`. `clientAlternateURLs` provides ordered fallback routes, and `clientTLSFingerprint` pins a directly exposed certificate so an iPhone, iPad, or Mac can authenticate a certificate issued by a private CA or for a raw IP.

For a Caddy-managed private certificate:

```text
https://203.0.113.10 {
    tls internal
    reverse_proxy 127.0.0.1:25101
}
```

Read the leaf-certificate SHA-256 fingerprint from a trusted machine and compare it with the certificate installed on the relay before saving it:

```bash
openssl s_client -connect 203.0.113.10:443 </dev/null 2>/dev/null \
  | openssl x509 -outform der \
  | shasum -a 256
```

Start the coordinator normally with `--relay-only`. To generate a QR from its Dashboard during setup, explicitly add `--gui`; an explicit GUI override wins over relay-only's default headless behavior:

```bash
sloppy run \
  --relay-only \
  --gui \
  --relay-public-url https://203.0.113.10
```

In **Settings → Connect Client**, enter the public HTTPS URL, then use **Detect & save** to let the relay read the endpoint's leaf certificate, calculate SHA-256, and persist the fingerprint. Review the detected value before generating the QR. The versioned setup code contains the primary URL, alternate URLs, expiry, certificate fingerprint, and a short-lived single-use bootstrap token. The native client exchanges that token for its own user session and stores the TLS pin for subsequent HTTP and WebSocket connections. Fingerprint detection requires `openssl`; the relay Docker image includes it.

The certificate pin protects transport identity; it does not make the current mesh discovery endpoint safe for unrestricted public exposure. Keep the IP endpoint behind the private-network or source-allowlist boundary described below until authenticated redacted discovery is implemented.

## Recommended Deployment: Docker and Caddy

::: warning Personal preview deployment

Do not expose the current discovery endpoint to the unrestricted Internet. `GET /v1/node/mesh` includes active invite tokens, while ClientNative discovery currently needs that response. Put the relay behind a private overlay network or a strict source-IP allowlist covering every trusted client. See [Public Discovery Caveat](#public-discovery-caveat).

:::

The relay is not a separate SwiftPM product. It is a mode of the main `sloppy` executable:

```bash
sloppy run --relay-only --relay-public-url https://relay.example.com
```

`--relay-only` disables the bundled Dashboard but keeps the Core API and mesh coordinator routes required for relay operation.

### 1. Build the Image

Build on the VPS from a released tag or a pinned commit:

```bash
git clone https://github.com/TeamSloppy/Sloppy.git
cd Sloppy
git checkout <release-tag-or-commit>

docker build \
  -f utils/docker/sloppy.Dockerfile \
  -t sloppy-relay:<version> \
  .
```

Building on the VPS avoids trying to cross-compile a Linux binary from macOS. The image uses Swift 6.2 for the build stage and Ubuntu 22.04 for the runtime stage.

### 2. Start the Relay

```bash
docker volume create sloppy-relay-data

docker run -d \
  --name sloppy-relay \
  --restart unless-stopped \
  -p 127.0.0.1:25101:25101 \
  -v sloppy-relay-data:/root/.sloppy \
  sloppy-relay:<version> \
  /usr/bin/sloppy run \
    --relay-only \
    --relay-public-url https://relay.example.com
```

Binding the published container port to `127.0.0.1` prevents direct Internet access to the unencrypted Core API. Caddy terminates TLS and is the only public entry point.

The Docker volume persists:

- the generated `sloppy.json`;
- coordinator mesh state at `/root/.sloppy/node/mesh.json`;
- SQLite and runtime state under `/root/.sloppy`;
- system logs and eligible pending task/event delivery data.

### 3. Configure Caddy

Point the domain at the VPS, install Caddy, and use a restricted route set. The example assumes the domain is already reachable only from a private overlay or trusted source IPs:

```text
relay.example.com {
    @relay {
        path /health /v1/node/mesh /v1/node/mesh/ws /v1/node/mesh/invites/accept
        # Replace these documentation ranges with trusted work, home, or VPN CIDRs.
        remote_ip 203.0.113.10/32 198.51.100.20/32 100.64.0.0/10
    }

    handle @relay {
        reverse_proxy 127.0.0.1:25101
    }

    handle {
        respond 404
    }
}
```

Caddy obtains and renews the certificate automatically and supports WebSocket upgrades without additional headers. Keep port `25101` closed in the VPS firewall; expose only `80` and `443`.

The public routes have distinct roles:

| Route | Purpose |
| --- | --- |
| `GET /health` | Process health probe. |
| `GET /v1/node/mesh` | Instance discovery and coordinator projection. |
| `POST /v1/node/mesh/invites/accept` | One-time registration of an invited node. |
| `WS /v1/node/mesh/ws` | Authenticated relay transport. |

Do not expose the full Core API unless the VPS itself is meant to be administered remotely and has an additional access-control layer.

### 4. Verify the Process

Check the process locally on the VPS:

```bash
curl http://127.0.0.1:25101/health
docker logs --tail 100 sloppy-relay
```

Then check TLS from an allowlisted work/home client:

```bash
curl https://relay.example.com/health
```

The health response should report `status: ok`. At startup, the relay log prints the public WebSocket URL:

```text
wss://relay.example.com/v1/node/mesh/ws
```

## Native Linux Build

Docker is the recommended deployment because it packages the Swift runtime and resource bundles together. For a native installation, install a complete Swift 6.2 toolchain plus Git, `pkg-config`, and SQLite development headers, then use the repository installer:

```bash
sudo apt-get update
sudo apt-get install -y git curl pkg-config libsqlite3-dev

git clone https://github.com/TeamSloppy/Sloppy.git
cd Sloppy
git checkout <release-tag-or-commit>
bash scripts/install.sh --server-only --no-prompt
```

Run the installed binary:

```bash
~/.local/bin/sloppy run \
  --relay-only \
  --relay-public-url https://relay.example.com
```

For a native background service, create a dedicated systemd unit whose `ExecStart` contains both relay flags. The generic `sloppy service install` command starts normal server mode and does not add `--relay-only` automatically.

Run the relay once while port `25101` is blocked by the host firewall, then stop it after it creates `~/.sloppy/sloppy.json`. In that generated file, set:

```json
"listen": {
  "host": "127.0.0.1",
  "port": 25101
}
```

The explicit loopback bind is required; the default host is `0.0.0.0`.

Example user unit at `~/.config/systemd/user/sloppy-relay.service`:

```ini
[Unit]
Description=Sloppy personal relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/sloppy run --config-path %h/.sloppy/sloppy.json --relay-only --relay-public-url https://relay.example.com
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

Enable it with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now sloppy-relay.service
journalctl --user -u sloppy-relay.service -f
```

Enable systemd lingering for the service account if it must remain active after logout.

## Create the Personal Mesh

Coordinator administration should stay on the VPS loopback interface. The examples below run on the VPS host while the container publishes `127.0.0.1:25101`.

Create the network once:

```bash
curl -sS \
  -X POST http://127.0.0.1:25101/v1/node/mesh/network \
  -H 'content-type: application/json' \
  -d '{"id":"personal","name":"Personal Mesh"}'
```

### Create the Work Invite

```bash
curl -sS \
  -X POST http://127.0.0.1:25101/v1/node/mesh/invites \
  -H 'content-type: application/json' \
  -d '{
    "networkId":"personal",
    "name":"work-machine",
    "roles":["worker"],
    "capabilities":[
      "run_agent",
      "git",
      "sloppy.core.remote",
      "sloppy.terminal.control"
    ],
    "ttlSeconds":86400
  }' | jq -r '.bundleToken'
```

### Create the Home Invite

Repeat the request with `"name":"home-machine"`. Create a separate invite for every machine; invite tokens are one-time credentials and should not be reused.

The returned `slp_mesh_...` value bundles the coordinator URL, network identity, and one-time invite. It does not contain the node private key.

## Join Work and Home Sloppy

Run the full Sloppy Core on both computers. Full multi-instance access requires `sloppy run`, not only the standalone computer-control `sloppy-node` daemon.

### Initialize Full-Access Identities

Before the first remote join on a clean machine, initialize its shared node identity with the capabilities required by full Core and terminal routing.

On the work computer:

```bash
sloppy node init \
  --name work-machine \
  --roles worker \
  --capabilities run_agent,git,sloppy.core.remote,sloppy.terminal.control
```

On the home computer, use the same command with `--name home-machine`.

This step is currently required because remote join preserves and submits the local identity capabilities; it does not apply the capabilities stored in the invite to a newly generated identity. `NodeMeshRelay` then authorizes using the registered capabilities rather than capabilities claimed later in `node.hello`.

If `~/.sloppy/node.json` already exists, inspect it with `sloppy node status`. Do not pass `--force` casually: it replaces the identity and invalidates any earlier coordinator registration. Revoke the old registration and create a new invite before intentionally replacing it.

### Join Through the Local Dashboard

Bootstrap each computer through its **local Dashboard**:

1. Keep the Dashboard Core API address pointed at that computer's local Sloppy Core.
2. Open Dashboard **Nodes**, choose **Join Remote Mesh**, and do not use **Accept invite**.
3. Paste that computer's `slp_mesh_...` invite.
4. Use a stable machine name such as `work-machine` or `home-machine`.
5. Confirm that the relay URL is `https://relay.example.com` and the node becomes online.

Joining creates or reuses the local identity, sends only its public identity to the coordinator, stores the relay URL locally, and starts the outbound relay connection. Replacing an existing identity requires an explicit force operation because doing so invalidates its previous relay registration.

Verify `sloppy.core.remote` and `sloppy.terminal.control` in the coordinator node record before testing ClientNative remote access.

::: warning ClientNative bootstrap limitation

ClientNative is the primary multi-instance client after the node has joined, but its current Mesh settings action calls the local coordinator invite-accept endpoint. It does not yet perform the remote-VPS join flow. Use the local Dashboard's **Join Remote Mesh** action for initial bootstrap, then return to ClientNative.

:::

### Disconnect the Manual Relay

On the computer whose manual relay connection you want to stop, open Dashboard **Nodes** and click **Disconnect relay** under **Local node**. The confirmation names that computer and the manual relay/coordinator address. Confirm to clear its saved `relayURL` and close the connection immediately; Core does not need a restart.

The node identity, signing/encryption keys, and Console binding are preserved. The node's registration remains in the coordinator registry and becomes offline when its socket closes. **Remove** is a different registry action and is not required to disconnect. Use **Join Remote Mesh** to establish a manual connection again.

## ClientNative Behavior

ClientNative is the primary Apple client for multi-instance access. It connects to the local Core API and treats relay nodes with the `sloppy.core.remote` capability as additional Sloppy instances.

The instance picker contains:

- **All** — aggregate chats and projects from every discovered instance;
- the local machine — direct Core API access;
- each remote machine — Core access routed through the relay;
- **Manage Instances…** — connection and mesh settings.

In **All**, read surfaces are merged and labeled with their source instance. Mutations cannot target an ambiguous aggregate: opening a chat or project preserves its source instance, while creation and task operations require or derive an explicit destination.

### Terminals

- A local project uses the native local terminal host.
- A remote project opens a `dashboard.terminal` mesh stream on the selected machine.
- Terminal access requires `sloppy.core.remote` on both peers and `sloppy.terminal.control` on the target.

### Kanban Execution Target

`executionNodeId` selects the machine that should execute a task. It is independent of `actorId`, which selects the agent. A local lifecycle worker skips tasks assigned to another machine instead of executing them on the wrong host.

## Security Model

Relay security has three layers:

1. **TLS transport** — public traffic uses HTTPS/WSS through Caddy or another TLS reverse proxy.
2. **Node authentication** — every node answers a nonce challenge signed by its persisted signing key. The coordinator accepts only registered public keys.
3. **End-to-end payload encryption** — sensitive `core.http`, `models.catalog`, and stream payloads use X25519 key agreement, HKDF-SHA256, and ChaCha20-Poly1305. Encryption keys are bound to the node signing identity. The relay retains routing metadata but cannot read the sealed body.

For a trusted LAN, Mesh clients also accept HTTP/WS relay endpoints on localhost or canonical numeric IPv4 addresses in `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`. Payload encryption is automatic and mandatory on these connections too: a missing peer key fails the request rather than sending plaintext. Coordinator discovery, node announcements, and other control messages are not all encrypted end to end, so public IP addresses and DNS hostnames continue to require HTTPS/WSS. This LAN exception is specific to Mesh transport and does not change native-client TLS pinning or public deployment requirements.

The local node private keys never leave their computers. Do not copy `~/.sloppy/node.json` between machines unless you intentionally want to move an identity.

### Capabilities

| Capability | Effect |
| --- | --- |
| `sloppy.core.remote` | Allows full remote Core request and stream access between trusted Sloppy instances. |
| `sloppy.terminal.control` | Allows the target to host a relayed terminal session. |
| `run_agent` | Allows agent execution workflows associated with a node. |
| `git` | Advertises Git/project execution support. |

Grant full Core and terminal capabilities only to machines owned by the same trusted user. Project-specific mesh permissions remain separate; see [Mesh Permissions](/guides/mesh#permissions).

The current remote-join path registers the capabilities submitted by the joining local identity instead of treating the invite capability list as an authoritative upper bound. This is acceptable only for the documented single-owner trust model. Capability intersection with invite grants is required before invites can safely be issued to mutually untrusted users or devices.

### Public Discovery Caveat

The current `GET /v1/node/mesh` response is an unauthenticated coordinator-state projection and includes invite metadata, including active invite tokens. An Internet client can poll the endpoint and consume a pending invite before the intended machine. Current multi-instance discovery also reads this endpoint.

Until Sloppy provides a redacted, authenticated public directory endpoint, operate the relay only behind a private overlay network or an allowlist containing every trusted client address. During bootstrap:

- create one short-lived invite at a time;
- join the intended machine immediately;
- revoke unused invites;
- keep VPN or source-IP restrictions active;
- do not expose the remaining coordinator management routes through Caddy.

An unrestricted open-Internet deployment is not safe with the current discovery API and must not be treated as a general multi-user service.

## Persistence, Backup, and Availability

The relay is designed for one personal VPS:

- `NodeMeshStore` persists coordinator state as JSON;
- eligible pending task and event delivery records survive restarts;
- active WebSocket connections are in memory and reconnect after restart;
- there is no built-in multi-relay replication, leader election, or HA failover.

Back up the Docker volume or, for a native install, the Sloppy workspace containing `node/mesh.json`. Treat backups as sensitive because they contain registered public identities, ACLs, audit records, and invite history.

## Upgrade and Rollback

Build images from immutable tags or commit hashes. To upgrade a Docker deployment:

```bash
git fetch --tags
git checkout <new-release-tag>
docker build -f utils/docker/sloppy.Dockerfile -t sloppy-relay:<new-version> .
```

Stop and replace the container with the same `sloppy-relay-data` volume and the same public relay URL. Do not delete the volume during an application rollback.

Before upgrading:

1. Back up the persistent volume.
2. Record the current image tag or digest.
3. Verify `/health` after replacement.
4. Confirm that both work and home nodes return online.
5. Open one remote chat and one remote terminal from ClientNative.

## Operations and Diagnostics

### Health and Logs

```bash
curl https://relay.example.com/health
docker logs --tail 200 sloppy-relay
docker logs -f sloppy-relay
```

Inspect coordinator state locally on the VPS:

```bash
curl -sS http://127.0.0.1:25101/v1/node/mesh | jq
curl -sS http://127.0.0.1:25101/v1/node/mesh/nodes | jq
curl -sS http://127.0.0.1:25101/v1/node/mesh/audit-log | jq
```

### A Node Does Not Appear

Check:

- the invite was created on this coordinator and has not expired;
- the local Core used **Join Remote Mesh**, rather than changing its API base to the VPS;
- the node's stored relay URL matches the public domain;
- DNS and `443/tcp` are reachable from that computer;
- the node has `sloppy.core.remote` in the coordinator registry;
- the relay audit log has no signature or key-binding rejection.

If `~/.sloppy/node.json` was replaced after registration, revoke or delete the old node record, create a new invite, and join again.

### WebSocket Authentication Fails

Authentication failures normally mean that the local private identity no longer matches the public key registered by the invite. They are not fixed by changing the ClientNative server address. Rejoin with a new invite and use force only when intentionally replacing the local identity.

### Remote Core Requests Are Forbidden

Both source and target nodes must advertise `sloppy.core.remote`. Terminal streams additionally require `sloppy.terminal.control` on the target. Project-scoped task and RPC operations may also require shared-project permissions.

### Remote Terminal Does Not Open

Confirm that:

- the target is a full Sloppy Core, not only `sloppy-node`;
- both nodes are online;
- the target has `sloppy.terminal.control`;
- ClientNative selected the remote instance or opened a project owned by it;
- the target project has a valid local checkout path.

### Restart Behavior

After a relay restart, online nodes reconnect automatically. In-flight streams and synchronous Core RPC end and must be reopened or retried. Eligible persisted task and event deliveries are replayed when the target reconnects.

## Production Checklist

- [ ] Relay is built from a pinned tag or commit.
- [ ] DNS points at the VPS.
- [ ] HTTPS certificate is valid.
- [ ] Only ports `80` and `443` are public.
- [ ] Core port `25101` is bound to loopback.
- [ ] Caddy exposes only required relay routes.
- [ ] Relay state is on a persistent volume.
- [ ] Volume backup and restore have been tested.
- [ ] Work and home use separate one-time invites.
- [ ] Both nodes show online.
- [ ] ClientNative lists **All**, the local instance, and the remote instance.
- [ ] Remote chat, mutation, agent stream, and terminal have been smoke-tested.
- [ ] Unused invites have been revoked.
