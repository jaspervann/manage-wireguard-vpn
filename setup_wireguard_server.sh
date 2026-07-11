#!/usr/bin/env bash
# Install and configure a small, file-based WireGuard management toolkit.
# Supported platforms: Debian 12+ and Ubuntu 22.04+.

set -euo pipefail
IFS=$'\n\t'

readonly WG_DIR=/etc/wireguard
readonly WG_CONFIG=/etc/wireguard/wg0.conf
readonly BIN_DIR=/usr/local/bin
readonly SYSCTL_FILE=/etc/sysctl.d/99-wireguard-forwarding.conf
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
[[ -r $SCRIPT_DIR/wireguard-toolkit-common.sh ]] || {
    printf '[!] Missing shared library: %s\n' "$SCRIPT_DIR/wireguard-toolkit-common.sh" >&2
    exit 1
}
# shellcheck source=wireguard-toolkit-common.sh
source "$SCRIPT_DIR/wireguard-toolkit-common.sh"

log() { printf '[+] %s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Run this installer as root (for example: sudo $0)."
}

check_platform() {
    # shellcheck source=/dev/null
    source /etc/os-release
    case ${ID:-} in
        debian) (( ${VERSION_ID%%.*} >= 12 )) || die 'Debian 12 or newer is required.' ;;
        ubuntu) (( ${VERSION_ID%%.*} >= 22 )) || die 'Ubuntu 22.04 or newer is required.' ;;
        *) die 'Only Debian 12+ and Ubuntu 22.04+ are supported.' ;;
    esac
}

install_packages() {
    log 'Installing WireGuard and qrencode.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        wireguard qrencode iptables iproute2 util-linux coreutils mawk sed grep procps
}

validate_command_sources() {
    local script_dir command
    script_dir=$SCRIPT_DIR
    for command in wg-add-client wg-remove-client wg-list-clients wireguard-toolkit-common.sh; do
        [[ -f $script_dir/$command && -r $script_dir/$command ]] || \
            die "Required command file is missing or unreadable: $script_dir/$command"
        bash -n "$script_dir/$command" || die "Command file has invalid Bash syntax: $script_dir/$command"
    done
}

validate_bootstrap_tools() {
    local command
    for command in awk grep sed tr install flock; do
        command -v "$command" >/dev/null 2>&1 || \
            die "Required base-system command is unavailable: $command"
    done
}

warn_stale_artifacts() {
    local artifact
    local -a artifacts=()
    shopt -s nullglob
    artifacts=("$WG_DIR"/.wg0.conf.* "$WG_DIR"/.remove-client.* "$WG_DIR"/.public.key.*)
    shopt -u nullglob
    for artifact in "${artifacts[@]}"; do
        printf '[!] Stale transaction artifact found; review it manually: %s\n' "$artifact" >&2
    done
    (( ${#artifacts[@]} == 0 )) || die 'Refusing to continue while stale transaction artifacts exist.'
}

detect_external_interface() {
    ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

detect_endpoint() {
    local endpoint=${WG_ENDPOINT:-}
    if [[ -n $endpoint ]]; then
        validate_endpoint "$endpoint"
        printf '%s\n' "$endpoint"
        return 0
    fi

    endpoint=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
    [[ -n $endpoint ]] || die 'Unable to detect an endpoint. Set WG_ENDPOINT to the public IP or hostname.'
    is_public_ipv4 "$endpoint" || die "Detected endpoint '$endpoint' is not a public IPv4 address. Set WG_ENDPOINT to the public IP or hostname."
    validate_endpoint "$endpoint"
    printf '%s\n' "$endpoint"
}


is_public_ipv4() {
    local ip=$1 a b c d
    IFS=. read -r a b c d <<< "$ip"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
    (( a != 169 || b != 254 )) || return 1
    (( a != 172 || b < 16 || b > 31 )) || return 1
    (( a != 192 || b != 168 )) || return 1
    (( a != 100 || b < 64 || b > 127 )) || return 1
}

prepare_server_private_key() {
    if [[ -e $WG_CONFIG && ! -s $WG_DIR/private.key ]]; then
        die "$WG_CONFIG exists but $WG_DIR/private.key is missing or empty. Refusing to generate a mismatched server key."
    fi
    if [[ ! -s $WG_DIR/private.key ]]; then
        umask 077
        wg genkey > "$WG_DIR/private.key"
    fi
    chmod 600 "$WG_DIR/private.key"
}

config_value() {
    local key=$1
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value=substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$WG_CONFIG"
}


validate_existing_config_structure() {
    [[ -e $WG_CONFIG ]] || return 0
    local addresses listen_port endpoint ipv4_cidr ipv4 bits value base size ipv6_cidr

    grep -Eiq '^[[:space:]]*SaveConfig[[:space:]]*=[[:space:]]*(true|yes|1)[[:space:]]*$' "$WG_CONFIG" && \
        die "$WG_CONFIG must not enable SaveConfig."
    addresses=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/ { printf "%s%s", separator, $2; separator="," } END { print "" }' "$WG_CONFIG")
    ipv4_cidr=$(tr ',' '\n' <<< "$addresses" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'index($0, ".") { print; exit }')
    [[ $ipv4_cidr == */* ]] || die "$WG_CONFIG must contain an IPv4 interface address."
    ipv4=${ipv4_cidr%/*}; bits=${ipv4_cidr#*/}
    [[ $bits =~ ^[0-9]+$ ]] || die "$WG_CONFIG contains an invalid IPv4 prefix."
    bits=$((10#$bits))
    (( bits >= 1 && bits <= 30 )) || die "$WG_CONFIG IPv4 prefix must be between /1 and /30."
    value=$(ipv4_to_int "$ipv4") || die "$WG_CONFIG contains an invalid IPv4 interface address."
    base=$(( value & (0xFFFFFFFF << (32 - bits)) )); size=$((1 << (32 - bits)))
    (( value > base && value < base + size - 1 )) || \
        die "$WG_CONFIG IPv4 interface address must not be the network or broadcast address."
    ipv6_cidr=$(tr ',' '\n' <<< "$addresses" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'index($0, ":") { print; exit }')
    [[ $ipv6_cidr == */64 && ${ipv6_cidr%/*} == *::* ]] || \
        die "$WG_CONFIG must contain a compressed /64 IPv6 interface address."
    normalize_ipv6 "${ipv6_cidr%/*}" >/dev/null || die "$WG_CONFIG contains an invalid IPv6 interface address."
    listen_port=$(config_value ListenPort)
    if ! [[ $listen_port =~ ^[1-9][0-9]{0,4}$ ]] || ! (( 10#$listen_port <= 65535 )); then
        die "$WG_CONFIG must contain a numeric ListenPort between 1 and 65535."
    fi
    endpoint=$(sed -n 's/^# Endpoint: //p' "$WG_CONFIG" | head -n 1)
    [[ -n $endpoint ]] || die "$WG_CONFIG must contain a '# Endpoint: HOST' comment."
    validate_endpoint "$endpoint"
    [[ -n $(config_value PrivateKey) ]] || die "$WG_CONFIG must contain an interface PrivateKey."
    awk '
        /^# Client: / {
            name=substr($0, 11)
            if (length(name) > 64 || name !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) {
                print "Invalid client comment: " name > "/dev/stderr"; exit 1
            }
            if (++seen[name] > 1) { print "Duplicate client comment: " name > "/dev/stderr"; exit 1 }
        }
    ' "$WG_CONFIG" || die "$WG_CONFIG contains duplicate client names."
}


validate_existing_server_key() {
    [[ -e $WG_CONFIG ]] || return 0
    local config_private expected_public config_public
    config_private=$(config_value PrivateKey)
    [[ -n $config_private ]] || die "$WG_CONFIG must contain an interface PrivateKey."
    expected_public=$(wg pubkey < "$WG_DIR/private.key")
    config_public=$(wg pubkey <<< "$config_private" 2>/dev/null) || die "$WG_CONFIG contains an invalid PrivateKey."
    [[ $config_public == "$expected_public" ]] || \
        die "The PrivateKey in $WG_CONFIG does not match $WG_DIR/private.key."
}

write_server_public_key() {
    local public_key temporary
    public_key=$(wg pubkey < "$WG_DIR/private.key")
    temporary=$(mktemp "$WG_DIR/.public.key.XXXXXX")
    trap 'rm -f "$temporary"' EXIT
    trap 'rm -f "$temporary"; exit 130' INT TERM HUP
    if ! printf '%s\n' "$public_key" > "$temporary" || \
        ! chmod 644 "$temporary" || ! mv "$temporary" "$WG_DIR/public.key"; then
        die "Unable to write $WG_DIR/public.key."
    fi
    trap - EXIT INT TERM HUP
}

has_nat_rule() {
    local phase=$1 tool=$2 action=$3 external_interface=$4
    awk -F= -v phase="$phase" -v tool="$tool" -v action="$action" -v interface="$external_interface" '
        $1 ~ "^[[:space:]]*" phase "[[:space:]]*$" {
            count=split($2, token, /[[:space:]]+/)
            for (index=1; index <= count - 8; index++) {
                if (token[index] == tool && token[index+1] == "-t" && token[index+2] == "nat" &&
                    token[index+3] == action && token[index+4] == "POSTROUTING" &&
                    token[index+5] == "-o" && token[index+6] == interface &&
                    token[index+7] == "-j" && token[index+8] == "MASQUERADE") { found=1; exit }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$WG_CONFIG"
}

validate_existing_nat() {
    [[ -e $WG_CONFIG ]] || return 0
    local external_interface=$1
    if ! has_nat_rule PostUp iptables -A "$external_interface" && \
        ! has_nat_rule PostUp iptables -I "$external_interface"; then
        die "$WG_CONFIG requires: iptables -t nat -A POSTROUTING -o $external_interface -j MASQUERADE"
    fi
    if ! has_nat_rule PostUp ip6tables -A "$external_interface" && \
        ! has_nat_rule PostUp ip6tables -I "$external_interface"; then
        die "$WG_CONFIG requires: ip6tables -t nat -A POSTROUTING -o $external_interface -j MASQUERADE"
    fi
    has_nat_rule PreDown iptables -D "$external_interface" || \
        die "$WG_CONFIG requires: iptables -t nat -D POSTROUTING -o $external_interface -j MASQUERADE"
    has_nat_rule PreDown ip6tables -D "$external_interface" || \
        die "$WG_CONFIG requires: ip6tables -t nat -D POSTROUTING -o $external_interface -j MASQUERADE"
}

derive_ipv6_prefix() {
    local hex
    hex=$(wg pubkey < "$WG_DIR/private.key" | base64 -d | od -An -tx1 | tr -d ' \n')
    printf 'fd%s:%s:%s\n' "${hex:26:2}" "${hex:28:4}" "${hex:32:4}"
}

write_server_config() {
    local external_interface=$1 endpoint=$2 ipv6_prefix=$3 private_key
    private_key=$(<"$WG_DIR/private.key")

    if [[ -e $WG_CONFIG ]]; then
        log "Keeping existing $WG_CONFIG."
        return
    fi

    umask 077
    cat > "$WG_CONFIG" <<EOF
# Managed by the WireGuard management toolkit. Peer blocks may be edited manually.
# Endpoint: ${endpoint}
[Interface]
PrivateKey = ${private_key}
Address = 10.8.0.1/24, ${ipv6_prefix}::1/64
ListenPort = 51820
MTU = 1420
PostUp = iptables -t nat -C POSTROUTING -o ${external_interface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${external_interface} -j MASQUERADE
PostUp = ip6tables -t nat -C POSTROUTING -o ${external_interface} -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o ${external_interface} -j MASQUERADE
PreDown = iptables -t nat -D POSTROUTING -o ${external_interface} -j MASQUERADE 2>/dev/null || true
PreDown = ip6tables -t nat -D POSTROUTING -o ${external_interface} -j MASQUERADE 2>/dev/null || true
EOF
    chmod 600 "$WG_CONFIG"
}

enable_forwarding() {
    cat > "$SYSCTL_FILE" <<'EOF'
# Required for routing traffic between WireGuard and the public interface.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null
}

configure_ufw() {
    local external_interface=$1
    local listen_port

    # Do not install or enable UFW. If the administrator already uses it, add
    # only the rules required for WireGuard and preserve all existing policy.
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active' || return 0

    listen_port=$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$WG_CONFIG")
    if ! [[ $listen_port =~ ^[1-9][0-9]{0,4}$ ]] || ! (( 10#$listen_port <= 65535 )); then
        die "Unable to determine a valid ListenPort from $WG_CONFIG."
    fi
    log 'Active UFW firewall detected; allowing WireGuard traffic.'
    ufw allow "$listen_port/udp" comment 'WireGuard'
    ufw route allow in on wg0 out on "$external_interface" comment 'WireGuard forwarding'
}


install_commands() {
    local script_dir
    script_dir=$SCRIPT_DIR
    install -d -m 755 /usr/local/lib/wireguard-toolkit
    install -m 644 "$script_dir/wireguard-toolkit-common.sh" /usr/local/lib/wireguard-toolkit/common.sh
    install -m 755 "$script_dir/wg-add-client" "$BIN_DIR/wg-add-client"
    install -m 755 "$script_dir/wg-remove-client" "$BIN_DIR/wg-remove-client"
    install -m 755 "$script_dir/wg-list-clients" "$BIN_DIR/wg-list-clients"
}

main() {
    require_root
    check_platform
    validate_command_sources
    validate_bootstrap_tools
    install -d -m 700 "$WG_DIR" "$WG_DIR/clients" "$WG_DIR/keys"
    exec 8>"$WG_DIR/.toolkit.lock"; flock -x 8
    validate_existing_config_structure
    warn_stale_artifacts
    install_packages
    prepare_server_private_key
    validate_existing_server_key
    local interface endpoint prefix
    interface=$(detect_external_interface)
    [[ -n $interface ]] || die 'Unable to find the default network interface.'
    validate_existing_nat "$interface"
    if [[ -e $WG_CONFIG ]]; then
        endpoint=$(sed -n 's/^# Endpoint: //p' "$WG_CONFIG" | head -n 1)
    else
        endpoint=$(detect_endpoint)
    fi
    write_server_public_key
    prefix=$(derive_ipv6_prefix)
    write_server_config "$interface" "$endpoint" "$prefix"
    enable_forwarding
    configure_ufw "$interface"
    install_commands
    systemctl enable --now wg-quick@wg0.service
    log 'WireGuard is ready. Add a client with: sudo wg-add-client CLIENT'
}

main "$@"
