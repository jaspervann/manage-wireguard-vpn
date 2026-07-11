# WireGuard management toolkit

A small, file-based WireGuard server and client-management toolkit written in
Bash. It targets Debian 12+ and Ubuntu 22.04+ and has no Docker, database, or
web UI dependencies.

## Install the server

Run the installer as root on a host with a default network route:

```bash
sudo ./setup_wireguard_server.sh
```

Keep `setup_wireguard_server.sh`, `wg-add-client`, `wg-remove-client`,
`wg-list-clients`, and `wireguard-toolkit-common.sh` in the same directory when
installing. The installer copies the three commands into `/usr/local/bin` and
their shared parsing library into `/usr/local/lib/wireguard-toolkit`; the
commands do not inherit variables from the installer.

The endpoint defaults to the source IPv4 address selected for internet traffic,
but only when that address is public. If the detected address is private or
otherwise non-public, installation stops and requires `WG_ENDPOINT`. On a NATed
server, or when using a DNS name, provide the public endpoint explicitly.
Bracket an IPv6 endpoint, as required by WireGuard configuration syntax.

```bash
sudo WG_ENDPOINT=vpn.example.com ./setup_wireguard_server.sh
```

The installer:

- installs WireGuard, `qrencode`, and the required firewall tooling;
- creates `/etc/wireguard/wg0.conf` without `SaveConfig`;
- enables IPv4 and IPv6 forwarding and NAT;
- detects an active UFW firewall and adds the WireGuard listener and forwarding
  rules without enabling, disabling, or resetting UFW;
- enables and starts `wg-quick@wg0`;
- installs `wg-add-client`, `wg-remove-client`, and `wg-list-clients` in
  `/usr/local/bin`.

If `/etc/wireguard/wg0.conf` already exists, the installer preserves and
validates it rather than overwriting it. Installation stops if it does not meet
these requirements:

- not enable `SaveConfig` (`SaveConfig = false` is accepted);
- contain compatible IPv4 and compressed `/64` IPv6 interface addresses;
- contain a numeric `ListenPort`;
- contain a `# Endpoint: HOST` comment using a hostname, IPv4 address, or
  bracketed IPv6 address without an embedded port;
- use unique `# Client: NAME` comments whose names contain only letters,
  digits, `_`, or `-` and are at most 64 characters;
- contain toolkit-compatible NAT `PostUp` and `PreDown` rules using the order
  `iptables -t nat -A|-I POSTROUTING -o INTERFACE -j MASQUERADE` for startup and
  `iptables -t nat -D POSTROUTING -o INTERFACE -j MASQUERADE` for shutdown,
  with equivalent `ip6tables` rules; the installer does not inject NAT rules
  into a preserved configuration;
- use the private key stored in `/etc/wireguard/private.key`, so that
  `/etc/wireguard/public.key` and generated client configurations identify the
  correct server.

If UFW is installed and active, the installer idempotently allows the configured
WireGuard UDP port (`51820` by default) and forwarding from `wg0` to the detected
external interface. It does not install or enable UFW and leaves unrelated
rules unchanged. You must still allow the configured UDP port in any separate
provider firewall or security group.

## Manage clients

Add a named client:

```bash
sudo wg-add-client iphone
```

This allocates the next free IPv4 and IPv6 addresses, writes the client
configuration and PNG QR code beneath `/etc/wireguard/clients`, stores its keys
beneath `/etc/wireguard/keys`, prints a terminal QR code, and reloads WireGuard
without interrupting existing peers.

IPv6 allocation expects the WireGuard interface to use a compressed `/64`
address such as `fd12:3456:789a::1/64`. Managed client addresses use host IDs
from `::2` through `::ffff` within that subnet.

Client configuration files and PNG QR codes contain the client's private and
preshared keys. Keep them confidential; the toolkit stores them with mode
`600` beneath the root-only `/etc/wireguard` directory.

List configured clients and live transfer data, sorted by IPv4 address:

```bash
sudo wg-list-clients
```

Remove a client and all of its generated files:

```bash
sudo wg-remove-client iphone
```

Configuration changes are serialized with a lock. Adds and removals update
`wg0.conf` atomically and roll back if the live `syncconf` reload fails.

## Files

```text
/etc/wireguard/
├── .toolkit.lock
├── wg0.conf
├── private.key
├── public.key
├── clients/
│   ├── iphone.conf
│   └── iphone.png
└── keys/
    ├── iphone.key
    ├── iphone.pub
    └── iphone.psk
```

The hidden `.toolkit.lock` file serializes management operations. After an
unclean termination such as `SIGKILL` or a power loss, the installer and the
add/remove commands warn about hidden transaction artifacts (`.wg0.conf.*`,
`.remove-client.*`, or `.public.key.*`). The installer and mutation commands
refuse to continue until these files are reviewed and recovered or removed
manually; the toolkit does not delete potential recovery data automatically.
