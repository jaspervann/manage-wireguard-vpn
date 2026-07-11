#!/usr/bin/env bash
# Shared parsing and validation helpers for the WireGuard toolkit.

ipv4_to_int() {
    local ip=$1 a b c d
    IFS=. read -r a b c d <<< "$ip"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
    printf '%u\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

normalize_ipv6() {
    local address=${1,,} left right missing part output='' index
    local -a left_parts=() right_parts=() parts=()
    address=${address%/*}
    [[ $address == *:* ]] || return 1
    if [[ $address == *::* ]]; then
        left=${address%%::*}; right=${address#*::}
        [[ -z $left ]] || IFS=: read -r -a left_parts <<< "$left"
        [[ -z $right ]] || IFS=: read -r -a right_parts <<< "$right"
        missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
        (( missing >= 1 )) || return 1
        parts=("${left_parts[@]}")
        for ((index = 0; index < missing; index++)); do parts+=(0); done
        parts+=("${right_parts[@]}")
    else
        IFS=: read -r -a parts <<< "$address"
        (( ${#parts[@]} == 8 )) || return 1
    fi
    for part in "${parts[@]}"; do
        [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1
        printf -v part '%04x' "$((16#$part))"
        output+="${output:+:}$part"
    done
    printf '%s\n' "$output"
}

validate_endpoint() {
    local endpoint=$1 label
    local -a labels=()
    [[ -n $endpoint && $endpoint != *[[:space:]]* ]] || die 'endpoint must not be empty or contain whitespace'
    if [[ $endpoint =~ ^\[([0-9A-Fa-f:]+)\]$ ]]; then
        normalize_ipv6 "${BASH_REMATCH[1]}" >/dev/null || die "invalid bracketed IPv6 endpoint: $endpoint"
        return 0
    fi
    [[ $endpoint != *:* ]] || die 'IPv6 endpoints must be bracketed and must not include a port'
    if [[ $endpoint =~ ^[0-9.]+$ ]]; then
        ipv4_to_int "$endpoint" >/dev/null || die "invalid IPv4 endpoint: $endpoint"
        return 0
    fi
    [[ ${#endpoint} -le 253 && $endpoint =~ ^[A-Za-z0-9.-]+$ && $endpoint != *..* ]] || \
        die "invalid endpoint hostname: $endpoint"
    IFS=. read -r -a labels <<< "$endpoint"
    for label in "${labels[@]}"; do
        [[ -n $label && ${#label} -le 63 && $label != -* && $label != *- ]] || \
            die "invalid endpoint hostname label: $label"
    done
}
