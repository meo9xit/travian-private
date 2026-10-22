#!/usr/bin/env bash
#
# deploy-travium-docker.sh - deploy the ORIGINAL Travium (Travian T4.5) PHP game
# with Docker on Ubuntu (or any Docker host).
#
# Everything is served from ONE port on whatever address you reach the box by:
# a LAN ip, a public ip, localhost or your own domain. No *.lvh.me, no
# cdn./api./portal. subdomains, no DNS records to add.
#
#   /          the game world
#   /portal/   the Angular portal (register + login + activation)
#   /api/      the registration API used by the portal
#   /cdn/      the asset pack (Travian css/js/images)
#
# Those are relative, so they follow whatever host the player typed:
#   * asset urls     - config.php "cdnBaseUrl" => "/cdn/..."
#   * portal api url - main-*.bundle.js         => location.origin + "/api/v1/"
#   * Register link  - src/mainInclude.php      => "/portal/?server=1#register"
#
# Usage:
#   chmod +x deploy-travium-docker.sh
#   ./deploy-travium-docker.sh install                       # auto-detect the ip
#   ./deploy-travium-docker.sh install --host 192.168.1.50 --port 80
#   ./deploy-travium-docker.sh install --host game.example.com --tls --acme-email me@example.com
#
# Commands:
#   install                    full deploy (default)
#   install-world [--force]    only the world steps (new world or repair)
#   set-port N                 move the whole install to another host port
#                              (keeps the world data)
#   bots [count]               create fake (AI) players with a village each,
#                              default 25. They grow on their own while the
#                              automation engine runs (see: engine start)
#   passwd [user] <password>   set a login password (default: Multihunter).
#                              With no argument it lists the accounts.
#   doctor                     check docker, disk, port and - most useful after a
#                              failed build - whether the image can fetch its apt
#                              packages from the Debian archive
#   up | down | restart | status | config | logs [service] | shell [service] | db
#   engine start|stop|status|logs
#   creds                      print urls and passwords
#   reset | uninstall          remove containers AND the database volume
#
# Options:
#   --host HOST       ip or domain players use (default: this machine's first ip)
#   --port N          host port, any 1-65535. Default 80, or 443 with --tls.
#                     Everything (game, /portal/, /api/, /cdn/) is served there,
#                     so one open port is enough: --port 8080 -> http://host:8080/
#   --src PATH        source tree (default: parent dir of this script)
#   --deploy-dir PATH generated deployment files (default: <src>/../travium-deploy)
#   --world ID        world folder + database name (default: game)
#   --admin-pass P    Multihunter password (default: generated). Save it - it is
#                     printed again by 'creds' and stored in the deployment .env.
#   --map-size N      map size (default 100 -> 201x201 tiles)
#   --speed N         game speed (default 1)
#   --start "WHEN"    world start time (default: now)
#   --db-root-pass P  MySQL root password (default: generated)
#   --db-pass P       game database user password (default: generated)
#   --tls             add a Caddy container with automatic HTTPS (domains only)
#   --acme-email E    contact address for Let's Encrypt
#   --no-build        skip the image build
#   --build-network N network for the image build: host (default) or default.
#                     host is the default because a stock Ubuntu container resolves
#                     through 127.0.0.53, which fails inside the build namespace
#                     ("Temporary failure resolving 'archive.debian.org'").
#   --no-engine       do not start the automation daemon
#   --no-php-patch    do NOT rebuild PHP 7.3.33 with the CVE-2026-109618 /
#                     CVE-2026-109619 fix. Fallback for when the source rebuild
#                     fails on your host; the php.ini / Apache mitigations are
#                     still applied, but they are not a complete fix.
#   --force           reinstall the world (DROPS its database) even if installed
#   --dry-run         only write the deployment files, do not touch Docker
#   --yes             never ask for confirmation
#   -h | --help       this text
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- defaults ---
SRC_DIR=""
DEPLOY_DIR=""
HOST=""
PORT=""
WORLD=""
ADMIN_PASS=""
ADMIN_EMAIL=""
MAP_SIZE=100
SPEED=1
ROUND_LENGTH=60
START_TIME=""
DB_ROOT_PASS=""
DB_PASS=""
DB_NAME=""
DB_USER="travium"
BUILD=1
ENGINE=1
FORCE=0
DRY_RUN=0
ASSUME_YES=0
TLS=0
ACME_EMAIL=""
PHP_IMAGE_TAG="travium-php:7.3"
BUILD_NETWORK="host"
PHP_CVE_PAT=1
COMMAND=""
POSITIONAL=()

# ---------------------------------------------------------------- logging ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi
log()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN} ok ${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}fail${C_RESET} $*" >&2; exit 1; }
step() { printf '\n%s\n' "${C_BOLD}--- $* ---${C_RESET}"; }
usage() { awk 'NR>1 && /^set -Eeuo pipefail$/{exit} NR>1' "$SCRIPT_DIR/$SCRIPT_NAME" | sed -e 's/^#\{1,2\}//' -e 's/^ //'; exit 0; }

# ---------------------------------------------------------------- parsing ----
while [ $# -gt 0 ]; do
    case "$1" in
        install|install-world|set-port|port|bots|bots-add|passwd|password|doctor|diag|up|down|restart|logs|status|ps|creds|config|shell|db|engine|reset|uninstall|help)
            COMMAND="$1"; shift ;;
        --host) HOST="${2:-}"; shift 2 ;;
        --port|--http-port) PORT="${2:-}"; shift 2 ;;
        --world) WORLD="${2:-}"; shift 2 ;;
        --src) SRC_DIR="${2:-}"; shift 2 ;;
        --deploy-dir) DEPLOY_DIR="${2:-}"; shift 2 ;;
        --admin-pass) ADMIN_PASS="${2:-}"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="${2:-}"; shift 2 ;;
        --map-size) MAP_SIZE="${2:-}"; shift 2 ;;
        --speed) SPEED="${2:-}"; shift 2 ;;
        --round-length) ROUND_LENGTH="${2:-}"; shift 2 ;;
        --start) START_TIME="${2:-}"; shift 2 ;;
        --db-root-pass) DB_ROOT_PASS="${2:-}"; shift 2 ;;
        --db-pass) DB_PASS="${2:-}"; shift 2 ;;
        --db-name) DB_NAME="${2:-}"; shift 2 ;;
        --db-user) DB_USER="${2:-}"; shift 2 ;;
        --acme-email) ACME_EMAIL="${2:-}"; shift 2 ;;
        --build-network) BUILD_NETWORK="${2:-}"; shift 2 ;;
        --tls) TLS=1; shift ;;
        --no-build) BUILD=0; shift ;;
        --no-php-patch) PHP_CVE_PAT=0; shift ;;
        --no-engine) ENGINE=0; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        --*) die "unknown option: $1   (try --help)" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
COMMAND="${COMMAND:-install}"

# First usable ip of this machine, so a fresh install has a working --host.
# Tolerates hosts without iproute2 (the substitutions must not trip set -e).
detect_host() {
    local h=""
    if command -v ip >/dev/null 2>&1; then
        h="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    fi
    if [ -z "$h" ] && command -v hostname >/dev/null 2>&1; then
        h="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    [ -n "$h" ] || h="127.0.0.1"
    printf '%s' "$h"
}

# Work out the scheme, the port suffix and every absolute url from HOST/PORT/TLS.
# Relative urls (assets, portal api, Register link) do not depend on this, so a
# port change never breaks the pages a player clicks - only mail links and the
# world list use these.
compute_urls() {
    SCHEME="http"; [ "$TLS" = "1" ] && SCHEME="https"
    PORT_SUFFIX=":$PORT"
    [ "$PORT" = "80" ] && PORT_SUFFIX=""
    [ "$SCHEME" = "https" ] && [ "$PORT" = "443" ] && PORT_SUFFIX=""
    BASE_URL="$SCHEME://$HOST$PORT_SUFFIX"
    INDEX_URL="$BASE_URL/portal/"
    GAME_WORLD_URL="$BASE_URL/"

    # ip literal (v4/v6) or a name? Let's Encrypt cannot issue for an ip, and an
    # ip is not a valid mail domain either.
    case "$HOST" in
        *[!0-9.]*) IS_IP=0; [ "${HOST#\[}" != "$HOST" ] && IS_IP=1 ;;
        *) IS_IP=1 ;;
    esac
    if [ "$IS_IP" = "1" ]; then
        MAIL_FROM="noreply@travium.local"
    else
        MAIL_FROM="noreply@$HOST"
    fi
}

# Any port is allowed: validate_port <value>
validate_port() {
    case "${1:-}" in
        ''|*[!0-9]*) die "--port must be a number (got '${1:-}')" ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        die "--port must be between 1 and 65535 (got $1)"
    fi
}

# Warn (do not fail) when something already listens on the requested host port,
# because that is the usual reason 'docker compose up' fails.
warn_if_port_busy() {
    local busy=0
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$" && busy=1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$" && busy=1
    fi
    [ "$busy" = "1" ] && warn "something is already listening on port $PORT - pick another with --port, or stop that service"
    return 0
}

# Read a value previously written to the deployment .env (used to keep the port
# and the passwords of an existing deployment). Defined early because the paths
# section below calls it.
old_env() { [ -f "$DEPLOY_DIR/.env" ] && sed -n "s/^$1=//p" "$DEPLOY_DIR/.env" | head -n1 | sed -e 's/^"//' -e 's/"$//' || true; }

# ------------------------------------------------------------------ paths ----
if [ -z "$SRC_DIR" ]; then
    if [ -f "$SCRIPT_DIR/src/bootstrap.php" ]; then
        SRC_DIR="$SCRIPT_DIR"
    elif [ -f "$SCRIPT_DIR/../src/bootstrap.php" ]; then
        SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
    else
        die "cannot find the game source - pass --src /path/to/travium"
    fi
fi
SRC_DIR="$(cd "$SRC_DIR" && pwd -P)"
[ -f "$SRC_DIR/src/bootstrap.php" ] || die "--src is not the game source (no src/bootstrap.php): $SRC_DIR"
[ -f "$SRC_DIR/server.tpl/include/env.php" ] || die "server.tpl is missing from $SRC_DIR"
[ -n "$DEPLOY_DIR" ] || DEPLOY_DIR="$(cd "$SRC_DIR/.." && pwd -P)/travium-deploy"

if [ -z "$HOST" ]; then
    HOST="$(detect_host)"
fi
HOST="${HOST#http://}"; HOST="${HOST#https://}"; HOST="${HOST%%/*}"
[ -n "$WORLD" ] || WORLD="game"
WORLD="$(printf '%s' "$WORLD" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
[ -n "$WORLD" ] || die "--world must contain [a-z0-9-]"
[ -n "$DB_NAME" ] || DB_NAME="$WORLD"

# Port: one port serves everything. Defaults to 80, or 443 with --tls (that is
# where Caddy terminates HTTPS). Any other value works too, e.g.
#   --port 8080   ->  http://host:8080/
#   --tls --port 8443 -> https://host:8443/  (plus :80 for the ACME challenge)
# An existing deployment keeps whatever port it was given, so re-running
# 'install' (or 'set-port') does not silently move the site back to 80.
if [ -z "$PORT" ] && [ "$(old_env TLS)" = "$TLS" ]; then
    PORT="$(old_env PORT)"
fi
if [ -z "$PORT" ]; then
    if [ "$TLS" = "1" ]; then PORT=443; else PORT=80; fi
fi
validate_port "$PORT"
compute_urls
if [ "$TLS" = "1" ] && [ "$IS_IP" = "1" ]; then
    die "--tls needs a real domain (Let's Encrypt cannot issue a certificate for $HOST). Use http://$HOST:$PORT/ without --tls."
fi

# ---------------------------------------------------------------- helpers ----
rand() { # alphanumeric from /dev/urandom; head closes the pipe (SIGPIPE) so drop pipefail locally
    local n="${1:-24}"
    ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" )
    printf '\n'
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
compose() { docker compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/docker-compose.yml" "$@"; }
confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    [ -t 0 ] || return 0
    printf '%s [y/N] ' "$1"; read -r a
    case "$a" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
sql_root()   { compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" -e "$1"; }
sql_db()     { compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" "$1" -e "$2"; }
sql_scalar() { compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" -N -B "$1" -e "$2" 2>/dev/null | tr -d '\r'; }
write_file() { local p="$1"; mkdir -p "$(dirname "$p")"; cat >"$p"; chmod 0644 "$p"; }

check_docker() {
    need_cmd docker
    docker compose version >/dev/null 2>&1 || die "the 'docker compose' v2 plugin is required. Ubuntu: sudo apt install docker-compose-plugin"
    docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon - is it running, and is your user in the 'docker' group? (sudo usermod -aG docker \$USER && newgrp docker)"
}

# ================================================================ file gen ===
ensure_env_file() {
    mkdir -p "$DEPLOY_DIR"
    [ -n "$DB_ROOT_PASS" ] || DB_ROOT_PASS="$(old_env DB_ROOT_PASS)"; [ -n "$DB_ROOT_PASS" ] || DB_ROOT_PASS="$(rand 20)"
    [ -n "$DB_PASS" ]      || DB_PASS="$(old_env DB_PASS)";           [ -n "$DB_PASS" ]      || DB_PASS="$(rand 20)"
    [ -n "$ADMIN_PASS" ]   || ADMIN_PASS="$(old_env ADMIN_PASS)";     [ -n "$ADMIN_PASS" ]   || ADMIN_PASS="$(rand 12)"
    [ -n "$START_TIME" ]   || START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

    write_file "$DEPLOY_DIR/.env" <<EOF
# Generated by $SCRIPT_NAME - keep this file: it holds the passwords.
# Sourced by load_env_file(), so every value is shell-quoted.
HOST="$HOST"
PORT="$PORT"
SCHEME="$SCHEME"
TLS="$TLS"
ACME_EMAIL="$ACME_EMAIL"
BASE_URL="$BASE_URL"
INDEX_URL="$INDEX_URL"
GAME_WORLD_URL="$GAME_WORLD_URL"
MAIL_FROM="$MAIL_FROM"
WORLD="$WORLD"
WORLD_DIR="$SRC_DIR/servers/$WORLD"
SRC_DIR="$SRC_DIR"
MAP_SIZE="$MAP_SIZE"
SPEED="$SPEED"
ROUND_LENGTH="$ROUND_LENGTH"
START_TIME="$START_TIME"
ADMIN_EMAIL="$ADMIN_EMAIL"
DB_ROOT_PASS="$DB_ROOT_PASS"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
PHP_IMAGE_TAG="$PHP_IMAGE_TAG"
ENGINE="$ENGINE"
EOF
    chmod 0600 "$DEPLOY_DIR/.env"
    ok "settings      $DEPLOY_DIR/.env"
}

# The same sources/package logic the Dockerfile uses, as a standalone script so
# 'doctor' can show what the image build will do (and why apt would exit 100).
gen_apt_probe() {
    write_file "$DEPLOY_DIR/apt-probe.sh" <<'EOF'
#!/bin/bash
# Run inside php:7.3-apache: checks that the image build's apt step can succeed.
set -u
. /etc/os-release
suite="${VERSION_CODENAME:-bullseye}"
case "$suite" in
    buster|stretch|jessie) sec="$suite/updates" ;;
    *) sec="$suite-security" ;;
esac
printf 'deb http://archive.debian.org/debian %s main\ndeb http://archive.debian.org/debian-security %s main\n' \
    "$suite" "$sec" > /etc/apt/sources.list
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\nAcquire::ForceIPv4 "true";\n' \
    > /etc/apt/apt.conf.d/99-archive
echo "release : $PRETTY_NAME"
echo "sources :"
grep -v '^#' /etc/apt/sources.list | grep -v '^$' | sed 's/^/          /'
echo "apt-get update:"
if apt-get update 2>&1 | tail -6 | sed 's/^/          /'; then :; fi
if ! apt-cache policy libc6 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    echo "          ==> NO PACKAGE INDEX AT ALL: this container cannot resolve or"
    echo "              reach archive.debian.org. That is a DNS/network problem of"
    echo "              the docker host, not a missing package."
fi
echo "packages:"
for p in libpng-dev libjpeg62-turbo-dev libfreetype6-dev libzip-dev libonig-dev \
         redis-server redis-tools unzip default-mysql-client; do
    v="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
    printf '          %-26s %s\n' "$p" "${v:-MISSING}"
done
EOF
    chmod 0755 "$DEPLOY_DIR/apt-probe.sh"
}

# Helper that creates fake (AI) players - the game's own 'bots': access=3, a
# starting village, a country flag and a random last login. It is written into
# the world's include/ dir (inside the mounted tree) so 'bots' can call it:
#   docker compose exec web php /var/www/app/servers/<world>/include/make-bots.php 30
# The names come from the game's own pool (src/schema/users.sqlite), the same one
# Core\Automation::addFakeUsers() uses; a built-in list covers a missing pool.
# These bots then grow on their own: the automation engine's AIProgress jobs run
# AI::doSomethingRandom() (building upgrades + troop training) and found new
# villages, as long as config.fakeAccountProcess stays 1.
gen_bots_helper() {
    local world_dir="$SRC_DIR/servers/$WORLD"
    [ -d "$world_dir/include" ] || return 0
    write_file "$world_dir/include/make-bots.php" <<'EOF'
<?php
// Create fake (AI) players for this world - generated by deploy-travium-docker.sh
// Usage: php make-bots.php [count]        (default 25, max 500)
if (PHP_SAPI !== 'cli') { exit("CLI only\n"); }
require __DIR__ . "/env.php";
require (IS_DEV ? SRC_PATH_DEV : SRC_PATH_PROD) . "/bootstrap.php";

use Core\Config;
use Core\Database\DB;

$count = isset($argv[1]) ? (int)$argv[1] : 25;
if ($count < 1) { $count = 1; }
if ($count > 500) { $count = 500; }

$db = DB::getInstance();
$before = (int)$db->fetchScalar("SELECT COUNT(*) FROM users WHERE access=3");

// The game keeps a pool of ready-made player names in a small sqlite db.
// (sqlite3 ships with the php image; if it is missing we fall back.)
$names = [];
$pool = SRC_PATH_PROD . "/schema/users.sqlite";
if (class_exists('SQLite3') && is_file($pool)) {
    $sqlite = new SQLite3($pool);
    $res = $sqlite->query("SELECT username FROM users ORDER BY RANDOM() LIMIT " . ($count * 3));
    while ($row = $res->fetchArray(SQLITE3_ASSOC)) {
        if (!empty($row['username'])) { $names[] = $row['username']; }
    }
    $sqlite->close();
}
if (sizeof($names) < $count) {
    $fallback = ['An', 'Binh', 'Chi', 'Dung', 'Giang', 'Ha', 'Hai', 'Hieu', 'Hoa', 'Hung',
        'Khanh', 'Lan', 'Linh', 'Long', 'Mai', 'Minh', 'Nam', 'Nga', 'Nhung', 'Phong',
        'Phuong', 'Quan', 'Quang', 'Quynh', 'Son', 'Tam', 'Thao', 'Thu', 'Thuy', 'Tien',
        'Trang', 'Trinh', 'Tuan', 'Tu', 'Van', 'Viet', 'Vinh', 'Yen'];
    while (sizeof($names) < $count * 3) {
        $names[] = $fallback[mt_rand(0, sizeof($fallback) - 1)] . mt_rand(10, 99);
    }
}
shuffle($names);

$register = new \Model\RegisterModel();
$created = 0;
try {
    // addFakeUser() skips names that already exist or are blacklisted, so hand it
    // batches of the remaining names and stop once the target is reached.
    foreach (array_chunk($names, 25) as $chunk) {
        $remaining = $count - $created;
        if ($remaining <= 0) { break; }
        $chunk = array_slice($chunk, 0, $remaining);
        if (!sizeof($chunk)) { break; }
        $created += $register->addFakeUser($chunk);
    }
} catch (Throwable $e) {
    fwrite(STDERR, "creating bots failed: " . $e->getMessage() . "\n");
    fwrite(STDERR, "  (check that " . CONFIG_CUSTOM_FILE . " defines fakeUsersCountryCodes)\n");
    exit(1);
}

$after = (int)$db->fetchScalar("SELECT COUNT(*) FROM users WHERE access=3");
$villages = (int)$db->fetchScalar("SELECT COUNT(*) FROM vdata v, users u WHERE v.owner=u.id AND u.access=3");
printf("created %d bot(s) this run - world now has %d bots with %d village(s)\n", $created, $after, $villages);
if ($created == 0) {
    printf("nothing created: names may already be taken, or the map has no free spot\n");
}
printf("they grow on their own while the automation engine runs: %s engine status\n", basename($argv[0]));
EOF
    chmod 0644 "$world_dir/include/make-bots.php"
}

gen_dockerfile() {
    if [ "$PHP_CVE_PAT" = "1" ]; then
        gen_dockerfile_patched
    else
        gen_dockerfile_plain
    fi
}

# ---------------------------------------------------------------------------
# Default: rebuild PHP 7.3.33 in place with the php2shell fix
# (CVE-2026-109618 / CVE-2026-109619) compiled into the engine.
#
# Why a rebuild and not an update: php:7.3-apache is the last 7.3 image that
# will ever be published (7.3 went EOL in December 2021), so there is no fixed
# image to pull. The PHP security team shipped minimal source backports for
# 7.4, 8.0 and 8.1 only. The flaw is in the engine, and 7.3.33 shares those
# code paths, so deploy/php-7.3-cve-2026-109618-109619.patch ports the fix onto
# 7.3.33. deploy/build-patch.py regenerates that patch from a pristine tree.
#
# The build happens inside the runtime image (not a second stage) because the
# base image loads PHP as an Apache module: `make install` has to land in
# exactly the /usr/local tree and re-run apxs against exactly the apache2 that
# will load it. Copying that tree between stages only risks a mismatched module
# path. The toolchain is purged in the same layer that used it.
# ---------------------------------------------------------------------------
gen_dockerfile_patched() {
    write_file "$DEPLOY_DIR/Dockerfile" <<'EOF'
# PHP 7.3.33 runtime for the ORIGINAL Travium source, rebuilt from source so the
# php2shell fixes (CVE-2026-109618 / CVE-2026-109619) are compiled in.
#
# The PHP version is not cosmetic: composer.json pins php >=7.3 <8.0 and
# Core\ErrorHandler turns every warning into a thrown ErrorException in CLI, so
# the installer aborts on 7.4 ("Trying to access array offset on value of type
# null" is a 7.4 diagnostic). bootstrap.php also dies without the redis
# extension, and Core\Caching\Caching connects to redis on the container's own
# loopback, so the daemon runs inside this image.
FROM php:7.3-apache

# The Debian release behind php:7.3-apache is old enough to have been moved to
# archive.debian.org (bullseye for recent pulls, buster for older ones), and the
# image ships snapshot.debian.org URLs, so build sources.list from the actual
# release instead of patching theirs. Retries + IPv4 keep a flaky mirror or a
# broken IPv6 route from failing the build ('apt-get install' then exits 100).
RUN set -eux; \
    . /etc/os-release; \
    suite="${VERSION_CODENAME:-bullseye}"; \
    case "$suite" in \
        buster|stretch|jessie) sec="$suite/updates" ;; \
        *) sec="$suite-security" ;; \
    esac; \
    printf 'deb http://archive.debian.org/debian %s main\ndeb http://archive.debian.org/debian-security %s main\n' \
        "$suite" "$sec" > /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\nAcquire::ForceIPv4 "true";\n' \
        > /etc/apt/apt.conf.d/99-archive; \
    apt-get update; \
    if ! apt-cache policy libc6 | grep -q 'Candidate: [0-9]'; then \
        echo ""; \
        echo "*** apt-get update downloaded NO package index."; \
        echo "*** The build container cannot resolve/reach archive.debian.org:"; \
        echo "***   Temporary failure resolving 'archive.debian.org'"; \
        echo "***"; \
        echo "*** That is the docker HOST's DNS, not a missing package. Two fixes:"; \
        echo "***  1. build with host networking (this script already does: it runs"; \
        echo "***     'docker build --network=host', override with --build-network)"; \
        echo "***  2. or give the daemon working DNS:"; \
        echo "***       cat /etc/docker/daemon.json   # look before you write"; \
        echo "***       echo '{\"dns\":[\"1.1.1.1\",\"8.8.8.8\"]}' | sudo tee /etc/docker/daemon.json"; \
        echo "***       sudo systemctl restart docker"; \
        echo "***"; \
        echo "*** Diagnose with: ./deploy-travium-docker.sh doctor"; \
        exit 1; \
    fi

# Build deps. The libraries are the ones the configure flags and the extension
# builds below actually need (gd -> png/jpeg/freetype, zip -> libzip,
# mbstring -> oniguruma, argon2 for password_hash, plus the ones PHP refuses to
# configure without: libxml2, sqlite3, curl, openssl) and apache2-dev for apxs.
# redis-server/-tools and default-mysql-client are runtime, installed here so
# the image keeps one apt layer: Core\Database\DB::backup() shells out to
# mysqldump, and Core\Caching\Caching connects to redis on the container's own
# loopback.
RUN set -eux; \
    pkgs="build-essential autoconf pkg-config patch ca-certificates curl xz-utils \
          apache2-dev libxml2-dev libsqlite3-dev libcurl4-openssl-dev libssl-dev \
          zlib1g-dev libpng-dev libjpeg62-turbo-dev libfreetype6-dev libzip-dev \
          libonig-dev libargon2-dev \
          redis-server redis-tools unzip default-mysql-client"; \
    apt-get install -y --no-install-recommends $pkgs \
    || { \
        echo "apt-get install failed - refreshing indexes and retrying once"; \
        apt-get update || true; \
        apt-get install -y --no-install-recommends $pkgs || { \
            echo "=== apt diagnostics ==="; \
            . /etc/os-release; echo "release: $PRETTY_NAME"; \
            grep -v '^#' /etc/apt/sources.list | grep -v '^$'; \
            for p in $pkgs; do printf '%-26s %s\n' "$p" "$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"; done; \
            exit 100; \
        }; \
    }; \
    rm -rf /var/lib/apt/lists/*

# --- the php2shell fix ------------------------------------------------------
# The patch is a repo file, not generated here, so what gets compiled is
# reviewable and pinned. Every step is checked, because a silently skipped hunk
# would leave the interpreter vulnerable while the build still succeeds:
#   * the tarball sha256 is the one php.net publishes for 7.3.33,
#   * `patch --dry-run` must accept every hunk before anything is written,
#   * after patching, the sources must contain the markers the fix introduces.
# The .docker-extracted marker stops docker-php-ext-install (used below) from
# re-extracting the stock tarball over the patched tree.
COPY php-7.3-cve-2026-109618-109619.patch /usr/src/php-cve.patch

ARG PHP_VERSION=7.3.33
ARG PHP_SHA256=9a369c32c6f52036b0a890f290327f148a1904ee66aa56e2c9a7546da6525ec8
RUN set -eux; \
    curl -fsSL -o /tmp/php.tar.gz "https://museum.php.net/php7/php-${PHP_VERSION}.tar.gz"; \
    echo "${PHP_SHA256}  /tmp/php.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/src/php; \
    tar -xzf /tmp/php.tar.gz -C /usr/src/php --strip-components=1; \
    rm -f /tmp/php.tar.gz; \
    cd /usr/src/php; \
    patch -p1 --dry-run < /usr/src/php-cve.patch; \
    patch -p1 < /usr/src/php-cve.patch; \
    grep -q 'zend_mm_safe_error_ex' Zend/zend_alloc.c; \
    grep -q 'zend_new_array_singleton' Zend/zend_hash.c; \
    grep -q 'max_multipart_body_parts' main/rfc1867.c; \
    grep -q 'rfc1867_enabled) || true' ext/session/session.c; \
    touch /usr/src/php/.docker-extracted; \
    echo "php2shell backport applied to PHP ${PHP_VERSION}"

# Same feature set the stock php:7.3-apache image was built with (so the Apache
# module keeps loading into the same apache2), plus nothing the game does not
# need. --with-libdir is what makes configure find the multiarch libraries on
# Debian; the official image passes it for 7.x.
# --enable-option-checking=fatal: a typo in a flag fails the build instead of
# silently dropping something the game needs at runtime.
RUN set -eux; \
    cd /usr/src/php; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    ./configure \
        --build="$gnuArch" \
        --with-libdir="lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
        --sysconfdir=/usr/local/etc \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-openssl \
        --with-zlib \
        --with-apxs2 \
        --disable-cgi \
        --disable-phpdbg; \
    make -j"$(nproc)"; \
    make install

# Extensions the game needs, compiled against the freshly installed engine:
#   mysqli    - Core\Database\DB uses `new \mysqli(...)`, not PDO
#   pdo_mysql - Core\Database\DBI and the installer use PDO
#   gd        - InstallerModel / map + hero images
#   zip       - installer / asset handling
#   mbstring  - functions.general.php
#   pcntl     - src/AutomationEngine.php (pcntl_fork, pcntl_signal)
#   opcache   - speed
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/; \
    docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql gd zip mbstring pcntl opcache

# php-redis 5.3.7 is the last release that supports PHP 7.3.
RUN set -eux; \
    pecl install redis-5.3.7; \
    docker-php-ext-enable redis

# integrations/install/index.php shells out to a hardcoded /usr/bin/php7.3.
RUN ln -sf /usr/local/bin/php /usr/bin/php7.3

RUN a2enmod rewrite headers setenvif alias

# The toolchain stays: purging the -dev packages would also remove the runtime
# libraries gd/zip/mbstring link against (libpng16-16, libzip, libonig) unless
# they are reinstalled by hand, and a wrong guess there turns into a 500 at
# runtime instead of a build error. The image is a game server, not a shared
# host, so the extra ~200 MB is the cheaper trade.
RUN rm -rf /usr/src/php /usr/src/php-cve.patch /tmp/pear /var/lib/apt/lists/*

# php2shell: prove the *loaded* interpreter is the rebuilt one. These read the
# running binary, not a file on disk, so a stale module cannot pass them.
RUN set -eux; \
    php -v | head -n1 | grep -q 'PHP 7\.3\.33'; \
    php -r 'exit(ini_get("max_multipart_body_parts") === false ? 1 : 0);' \
        || { echo "*** max_multipart_body_parts is missing: the php2shell patch is NOT in this build"; exit 1; }; \
    php -m | grep -qx redis; \
    php -m | grep -qx mysqli; \
    php -m | grep -qx gd; \
    php -m | grep -qx mbstring; \
    echo "runtime php $(php -r 'echo PHP_VERSION;') carries the php2shell fix"

WORKDIR /var/www/app
EXPOSE 80
EOF
    ok "Dockerfile    PHP 7.3.33 rebuilt with the php2shell fix"
}

# Fallback for --no-php-patch: the stock php:7.3-apache binaries, which are
# still vulnerable to CVE-2026-109618 / CVE-2026-109619. Only the php.ini and
# Apache mitigations generated by gen_php_hardening / gen_vhost apply.
gen_dockerfile_plain() {
    write_file "$DEPLOY_DIR/Dockerfile" <<'EOF'
# PHP 7.3 runtime for the ORIGINAL Travium source.
#
# WARNING: this image runs the stock php:7.3-apache binaries, which ARE
# vulnerable to CVE-2026-109618 and CVE-2026-109619 (php2shell). It is only
# generated with --no-php-patch. The php.ini and Apache mitigations this script
# writes reduce exposure but do not remove the vulnerability - rebuild without
# --no-php-patch to get the patched interpreter.
#
# The version is not cosmetic: composer.json pins php >=7.3 <8.0 and
# Core\ErrorHandler turns every warning into a thrown ErrorException in CLI, so
# the installer aborts on 7.4 ("Trying to access array offset on value of type
# null" is a 7.4 diagnostic). bootstrap.php also dies without the redis
# extension, and Core\Caching\Caching connects to redis on the container's own
# loopback, so the daemon runs inside this image.
FROM php:7.3-apache

# The Debian release behind php:7.3-apache is old enough to have been moved to
# archive.debian.org (bullseye for recent pulls, buster for older ones), and the
# image ships snapshot.debian.org URLs, so build sources.list from the actual
# release instead of patching theirs. Retries + IPv4 keep a flaky mirror or a
# broken IPv6 route from failing the build ('apt-get install' then exits 100).
RUN set -eux; \
    . /etc/os-release; \
    suite="${VERSION_CODENAME:-bullseye}"; \
    case "$suite" in \
        buster|stretch|jessie) sec="$suite/updates" ;; \
        *) sec="$suite-security" ;; \
    esac; \
    printf 'deb http://archive.debian.org/debian %s main\ndeb http://archive.debian.org/debian-security %s main\n' \
        "$suite" "$sec" > /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\nAcquire::ForceIPv4 "true";\n' \
        > /etc/apt/apt.conf.d/99-archive; \
    apt-get update; \
    if ! apt-cache policy libc6 | grep -q 'Candidate: [0-9]'; then \
        echo ""; \
        echo "*** apt-get update downloaded NO package index."; \
        echo "*** The build container cannot resolve/reach archive.debian.org:"; \
        echo "***   Temporary failure resolving 'archive.debian.org'"; \
        echo "***"; \
        echo "*** That is the docker HOST's DNS, not a missing package. Two fixes:"; \
        echo "***  1. build with host networking (this script already does: it runs"; \
        echo "***     'docker build --network=host', override with --build-network)"; \
        echo "***  2. or give the daemon working DNS:"; \
        echo "***       cat /etc/docker/daemon.json   # look before you write"; \
        echo "***       echo '{\"dns\":[\"1.1.1.1\",\"8.8.8.8\"]}' | sudo tee /etc/docker/daemon.json"; \
        echo "***       sudo systemctl restart docker"; \
        echo "***"; \
        echo "*** Diagnose with: ./deploy-travium-docker.sh doctor"; \
        exit 1; \
    fi

# Build libs for gd (map + hero images), zip, mbstring; redis-server/-tools for
# the daemon and CLI; default-mysql-client because Core\Database\DB::backup()
# shells out to mysqldump. One retry, and a readable diagnostic if it still
# fails, so a bad mirror does not leave just "exit code: 100".
RUN set -eux; \
    pkgs="libpng-dev libjpeg62-turbo-dev libfreetype6-dev libzip-dev libonig-dev redis-server redis-tools unzip default-mysql-client"; \
    apt-get install -y --no-install-recommends $pkgs \
    || { \
        echo "apt-get install failed - refreshing indexes and retrying once"; \
        apt-get update || true; \
        apt-get install -y --no-install-recommends $pkgs || { \
            echo "=== apt diagnostics ==="; \
            . /etc/os-release; echo "release: $PRETTY_NAME"; \
            grep -v '^#' /etc/apt/sources.list | grep -v '^$'; \
            for p in $pkgs; do printf '%-26s %s\n' "$p" "$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"; done; \
            exit 100; \
        }; \
    }; \
    rm -rf /var/lib/apt/lists/*

# mysqli + pdo_mysql: Core\Database\DB uses mysqli, DBI and the installer use PDO.
# pcntl: src/AutomationEngine.php forks. opcache: speed.
RUN docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-install -j"$(nproc)" mysqli pdo_mysql gd zip mbstring pcntl opcache

# php-redis 5.3.7 is the last release supporting PHP 7.3.
RUN pecl install redis-5.3.7 \
    && docker-php-ext-enable redis

# integrations/install/index.php shells out to a hardcoded /usr/bin/php7.3.
RUN ln -sf /usr/local/bin/php /usr/bin/php7.3

RUN a2enmod rewrite headers setenvif alias

WORKDIR /var/www/app
EXPOSE 80
EOF
    warn "Dockerfile    built WITHOUT the php2shell fix (--no-php-patch)"
}

# The interpreter patch is a repo file. Copy it next to the generated Dockerfile
# so `docker build` can COPY it; fail loudly rather than emit a Dockerfile whose
# COPY refers to a file that is not there.
gen_php_cve_patch() {
    local src="$SCRIPT_DIR/deploy/php-7.3-cve-2026-109618-109619.patch"
    [ "$PHP_CVE_PAT" = "1" ] || return 0
    [ -f "$src" ] || die "missing the php2shell patch: $src (run from a full checkout, or use --no-php-patch)"
    cp -f "$src" "$DEPLOY_DIR/php-7.3-cve-2026-109618-109619.patch"
    chmod 0644 "$DEPLOY_DIR/php-7.3-cve-2026-109618-109619.patch"
    ok "php2shell     $(basename "$src") ($(wc -l <"$src" | tr -d ' ') lines)"
}

# php.ini hardening, mounted into conf.d. Two jobs:
#   1. the vendor's temporary mitigations for php2shell, which still matter as
#      defence in depth even with the patched engine;
#   2. the request-shape limits that make the exploit primitives (unbounded
#      multipart parts, controllable OOM) hard to reach in the first place.
# This game has no upload form, so uploads are switched off entirely.
gen_php_hardening() {
    write_file "$DEPLOY_DIR/php-hardening.ini" <<'EOF'
; Hardening for CVE-2026-109618 / CVE-2026-109619 ("php2shell") and general
; request limits - generated by deploy-travium-docker.sh.
;
; The engine itself is patched (see the Dockerfile). These settings are the
; vendor's documented mitigations plus limits for the request shapes the
; exploits need, so a second bug in the same family still has no way in.

; --- php2shell mitigations -------------------------------------------------
; Session upload progress initialises a session while the request body is still
; being parsed, before modules are activated. The patched engine no longer
; leaves state behind on that path, and this turns the feature off as well:
; nothing in this game uses it.
session.upload_progress.enabled = 0
session.upload_progress.cleanup = On

; Cap the multipart parts a request may declare. Default would be
; max_input_vars + max_file_uploads; a fixed small number is stricter.
max_multipart_body_parts = 64

; Uploads are not used by the game: no form has enctype="multipart/form-data"
; and nothing calls move_uploaded_file(). Zero disables file uploads, which
; removes the multipart parse path the exploits abuse.
file_uploads = Off
max_file_uploads = 0

; The OOM trigger needs a request that can push PHP over memory_limit. These
; keep a single request small; memory_limit itself stays finite so one bad
; request cannot exhaust the host (the container's memory limit is the second
; wall). The vendor's mitigation is memory_limit=-1 - that only makes sense on
; an unpatched engine, where the alternative is leaving the RCE reachable.
post_max_size = 16M
upload_max_filesize = 8M
max_input_vars = 2000
max_input_nesting_level = 32
max_execution_time = 120

; --- general ----------------------------------------------------------------
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
allow_url_include = Off
allow_url_fopen = On

; Sessions: the game sets its own cookie parameters, but a strict, HttpOnly,
; SameSite default costs nothing.
session.use_strict_mode = 1
session.use_only_cookies = 1
session.cookie_httponly = 1
session.cookie_samesite = Lax

; No diagnostic may be emitted before request initialisation - that is the
; window php2shell abuses. Deprecations from old code would do exactly that.
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
EOF
    ok "php.ini       php-hardening.ini"
}

# Server-scoped Apache hardening. These directives are illegal inside a
# <VirtualHost>, so they go in their own conf-enabled file. Mounted read-only.
gen_apache_hardening() {
    write_file "$DEPLOY_DIR/000-travium-hardening.conf" <<'EOF'
# Server-level hardening - generated by deploy-travium-docker.sh.
# Confirmed in conf-enabled/ so it is read before the vhost.

# Do not advertise the exact version: banner grabbing is the first step of most
# scans, and this is a game server, not a target.
ServerTokens Prod
ServerSignature Off

# TRACE echoes the request back, including headers. Nothing here uses it.
TraceEnable Off

# php2shell: the exploit needs a request that stays under post_max_size while
# still being large and slow to parse. These bound header/line size and the time
# a client may take to send a request, so a worker cannot be pinned mid-parse.
<IfModule mod_reqtimeout.c>
    RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500
</IfModule>

# Defaults are generous (100 headers, 8190 bytes each); tighten them. The game
# sends a handful of cookies and normal form posts.
LimitRequestFields 64
LimitRequestFieldSize 4096
LimitRequestLine 4096
EOF
    ok "apache       000-travium-hardening.conf"
}

gen_mail_capture() {
    write_file "$DEPLOY_DIR/mail-capture.sh" <<'EOF'
#!/bin/sh
# Stand-in for /usr/sbin/sendmail. php:7.3-apache ships no MTA, so mail() returns
# false, PHPMailer throws "Could not instantiate mail function." and
# RegisterCtrl::register() aborts *after* inserting the activation row but
# *before* handing activate.php?token=... back to the portal.
# Capture the message locally and exit 0 - all mail() inspects.
LOG=/tmp/php-mail.log
{
    printf '\n===== %s =====\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    cat
} >> "$LOG" 2>/dev/null
exit 0
EOF
    chmod 0755 "$DEPLOY_DIR/mail-capture.sh"
    write_file "$DEPLOY_DIR/php-mail-capture.ini" <<'EOF'
; Send local mail to the capture wrapper (see mail-capture.sh).
; Read it with:  docker compose exec web cat /tmp/php-mail.log
sendmail_path = "/bin/sh /usr/local/bin/mail-capture.sh -t -i"
EOF
    ok "mail capture  mail-capture.sh + php-mail-capture.ini"
}

gen_vhost() {
    local tls_env=""
    if [ "$TLS" = "1" ]; then
        tls_env="        # Caddy terminates TLS in front of us; tell the game it is https so
        # WebService::getProtocol() builds https:// links.
        SetEnvIf X-Forwarded-Proto \"^https\$\" HTTPS=on
"
    fi
    # max_multipart_body_parts only exists once the engine patch is compiled in.
    # mod_php aborts the whole server on a php_value for an unknown directive
    # ("Invalid php_value directive"), so the line is emitted only when it will
    # resolve. The ini file carries the same setting for the patched build.
    local php2shell_ini=""
    if [ "$PHP_CVE_PAT" = "1" ]; then
        php2shell_ini="    # Bounds the number of multipart parts (the patch adds this ini entry).
    php_value max_multipart_body_parts 64
"
    fi
    write_file "$DEPLOY_DIR/apache-vhost.conf" <<EOF
# Single-host layout, rendered by $SCRIPT_NAME for world '$WORLD'.
#
#   /          the game world          -> servers/$WORLD/public  (front controller)
#   /portal/   the portal (Angular)    -> homepage/
#   /api/      the registration API    -> integrations/api/     (front controller)
#   /cdn/      the asset pack          -> integrations/cdn/
#
# Everything is relative, so the same install works over a LAN ip, a public ip,
# localhost or a domain. This is the only vhost, which means Apache also serves
# it for a Host header it does not recognise - plain ip access just works.
#
# Depth matters: server.tpl/include/env.php computes SRC_PATH_PROD as
# dirname(__DIR__,3)."/src", so include/ must sit three levels below the repo
# root - /var/www/app/servers/$WORLD/include -> /var/www/app.
<VirtualHost *:80>
    ServerName $HOST
    DocumentRoot /var/www/app/servers/$WORLD/public

    # --- php2shell / request-shape limits -----------------------------------
    # CVE-2026-109618 is reachable through a request whose *declared* length
    # stays under post_max_size while the bytes actually consumed do not (chunked
    # or lengthless HTTP/2 bodies), which is how the exploit reaches memory_limit.
    # Apache is the layer that can see the real size, so cap it here as well as
    # in php-hardening.ini. The game has no upload form; 16M is generous.
    LimitRequestBody 16777216
    # Slow/malformed multipart bodies that keep a worker busy are the other half
    # of the trick: a worker that times out mid-parse is a worker whose request
    # state is torn down early.
    Timeout 60
    <IfModule mod_reqtimeout.c>
        RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500
    </IfModule>

    # No TRACE: it reflects request headers and nothing here needs it.
    # (TraceEnable itself is server-level, so it lives in 000-travium-hardening.conf
    #  written by gen_apache_hardening, not inside this vhost.)    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
        Header unset X-Powered-By
    </IfModule>

    # PHP diagnostics must never reach a client: a warning printed before the
    # request is fully initialised is exactly the window the exploits use.
    php_flag display_errors Off
    php_flag display_startup_errors Off
    php_value session.upload_progress.enabled 0
$php2shell_ini    php_admin_flag file_uploads Off
    php_admin_value post_max_size 16M
    # php_value, not php_admin_value: the map, backup and installer pages raise
    # this themselves with ini_set("memory_limit", -1). An admin value would
    # make those ini_set() calls silently fail and break the map generator.
    php_value memory_limit 512M

    Alias /cdn /var/www/app/integrations/cdn
    Alias /portal /var/www/app/homepage
    Alias /api /var/www/app/integrations/api

    <Directory /var/www/app/servers/$WORLD/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        DirectoryIndex index.php
$tls_env
        # Front controller: no dorf1.php on disk, src/mainInclude.php derives the
        # page from REQUEST_URI.
        RewriteEngine On
        RewriteBase /
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule ^ index.php [L,QSA]
    </Directory>

    <Directory /var/www/app/integrations/cdn>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    <Directory /var/www/app/homepage>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.html
        # The portal bundle is patched by hand and keeps its hashed file name,
        # so never let a browser reuse a cached copy.
        <IfModule mod_headers.c>
            Header set Cache-Control "no-store, must-revalidate"
            Header unset ETag
        </IfModule>
        FileETag None
    </Directory>

    <Directory /var/www/app/integrations/api>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.php
$tls_env
        # /api/v1/... -> /api/index.php; integrations/api/index.php strips the
        # /api prefix before routing.
        RewriteEngine On
        RewriteBase /api/
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule ^ index.php [L,QSA]
    </Directory>

    # include/ holds the db config, the mail templates and the vendored
    # Twig/FastRoute tree - not a public entry point. PHP still require()s these
    # files straight off disk.
    <Directory /var/www/app/integrations/api/include>
        Require all denied
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/game-error.log
    CustomLog \${APACHE_LOG_DIR}/game-access.log combined
</VirtualHost>
EOF
    ok "vhost         $HOST:$PORT  (/, /portal/, /api/, /cdn/)"
}

gen_compose() {
    # 'ports' must stay a valid YAML list, so in TLS mode the web container gets
    # an explicit empty list instead of a comment-only block.
    local ports_block
    if [ "$TLS" = "1" ]; then
        # Caddy owns the published ports: nothing is exposed for the web
        # container (that also leaves $PORT free for the HTTPS listener, so
        # --port 443 does not clash with port 80).
        ports_block="      []   # with --tls Caddy publishes $PORT (https) + 80 (ACME); it proxies web:80"
    else
        ports_block="      - '${PORT}:80'   # everything: /  /portal/  /api/  /cdn/"
    fi
    write_file "$DEPLOY_DIR/docker-compose.yml" <<EOF
# Generated by $SCRIPT_NAME - host=$HOST port=$PORT world=$WORLD
services:
  db:
    image: mysql:5.7
    container_name: ${WORLD}-db
    restart: unless-stopped
    command:
      # The schema was written for the loose MySQL 5.7 behaviour (zero dates,
      # non-strict inserts).
      - --sql-mode=
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --max_allowed_packet=256M
    environment:
      MYSQL_ROOT_PASSWORD: "$DB_ROOT_PASS"
    volumes:
      - db-data:/var/lib/mysql
    healthcheck:
      test: ['CMD', 'mysqladmin', 'ping', '-h', '127.0.0.1', '-uroot', '-p$DB_ROOT_PASS']
      interval: 5s
      timeout: 5s
      retries: 60

  web:
    build:
      context: .
      dockerfile: Dockerfile
    image: $PHP_IMAGE_TAG
    container_name: ${WORLD}-web
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
$ports_block
    volumes:
      - $SRC_DIR:/var/www/app
      - ./apache-vhost.conf:/etc/apache2/sites-available/000-default.conf:ro
      - ./mail-capture.sh:/usr/local/bin/mail-capture.sh:ro
      - ./php-mail-capture.ini:/usr/local/etc/php/conf.d/zz-mail-capture.ini:ro
      # php2shell mitigations + request limits. Mounted rather than baked in so
      # a rebuilt image cannot silently lose them.
      - ./php-hardening.ini:/usr/local/etc/php/conf.d/zz-php-hardening.ini:ro
      # Server-scoped Apache directives (TraceEnable, ServerTokens, reqtimeout).
      - ./000-travium-hardening.conf:/etc/apache2/conf-enabled/000-travium-hardening.conf:ro
    working_dir: /var/www/app
    environment:
      TRAVIUM_WORLD: "$WORLD"
      TRAVIUM_ENGINE: "$ENGINE"
    command:
      - bash
      - -lc
      - |
        set -e
        echo "starting redis..."
        redis-server --daemonize yes --save '' --appendonly no
        until redis-cli ping >/dev/null 2>&1; do sleep 0.3; done
        echo "redis is up"
        if [ "\$\$TRAVIUM_ENGINE" = "1" ] && [ -f "/var/www/app/servers/\$\$TRAVIUM_WORLD/include/engine.php" ]; then
          # The automation engine is what finishes buildings, troop training,
          # hero adventures, attacks and the AI bots. It loads the whole game
          # config at startup, so on a FIRST deploy it dies instantly: the world
          # schema does not exist yet (the installer only runs afterwards) and
          # nothing restarts it - leaving a server where every countdown reaches
          # zero and nothing happens. Hence a supervisor that keeps it alive and
          # retries, guarded by a pid file so orphans cannot double-process.
          echo "starting the automation engine for \$\$TRAVIUM_WORLD..."
          (
            ENGINE_PIDFILE=/tmp/engine.pid
            while true; do
              if [ -f "\$\$ENGINE_PIDFILE" ] && kill -0 "\$\$(cat "\$\$ENGINE_PIDFILE")" 2>/dev/null; then
                sleep 15
                continue
              fi
              TRAVIUM_UNDER_SYSTEMD=1 php "/var/www/app/servers/\$\$TRAVIUM_WORLD/include/engine.php" &
              echo \$\$! > "\$\$ENGINE_PIDFILE"
              wait \$\$!
              echo "[\$\$(date '+%Y-%m-%d %H:%M:%S')] engine exited, restarting in 15s"
              rm -f "\$\$ENGINE_PIDFILE"
              sleep 15
            done
          ) >>/tmp/engine.log 2>&1 &
          sleep 1
        fi
        apache2-foreground
EOF
    if [ "$TLS" = "1" ]; then
        # Publish the HTTPS listener on --port (443 by default) and 80 for the
        # ACME HTTP challenge / http->https redirect.
        local tls_ports="      - '${PORT}:${PORT}'"
        [ "$PORT" != "80" ] && tls_ports="$tls_ports
      - '80:80'"
        cat >>"$DEPLOY_DIR/docker-compose.yml" <<EOF

  caddy:
    image: caddy:2-alpine
    container_name: ${WORLD}-caddy
    restart: unless-stopped
    depends_on:
      - web
    ports:
$tls_ports
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
EOF
    fi
    cat >>"$DEPLOY_DIR/docker-compose.yml" <<EOF

volumes:
  db-data:
EOF
    [ "$TLS" = "1" ] && printf '  caddy-data:\n  caddy-config:\n' >>"$DEPLOY_DIR/docker-compose.yml"
    ok "compose       docker-compose.yml ($([ "$TLS" = "1" ] && echo 'web + db + caddy' || echo 'web + db'))"
}

gen_caddyfile() {
    [ "$TLS" = "1" ] || return 0
    # Caddy listens on the port in its site address: 443 (implied) or whatever
    # --port was set to, so https://host:8443/ works too.
    local site="$HOST"
    [ "$PORT" != "443" ] && site="$HOST:$PORT"
    write_file "$DEPLOY_DIR/Caddyfile" <<EOF
# Automatic HTTPS for the whole install. Every path (/portal/, /api/, /cdn/)
# goes to the same Apache container, which is why one certificate is enough.
# $HOST must resolve here and ports 80 and $PORT must be reachable.
{
    email ${ACME_EMAIL:-admin@$HOST}
}

$site {
    encode zstd gzip
    reverse_proxy web:80 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Real-IP {remote_host}
    }
}
EOF
    ok "Caddyfile     automatic HTTPS on $HOST:$PORT"
}

gen_global_config() {
    local backup=""
    # Keep the FIRST backup of a hand-edited config.php. Overwriting it on every
    # run means the second run backs up the file the first run generated, and the
    # original is gone - which is exactly how a local config gets lost.
    if [ -f "$SRC_DIR/config.php" ]; then
        if [ ! -f "$SRC_DIR/config.php.orig" ]; then
            cp -f "$SRC_DIR/config.php" "$SRC_DIR/config.php.orig"
            backup=" (previous file saved as config.php.orig)"
        else
            backup=" (original kept as config.php.orig)"
        fi
    fi
    write_file "$SRC_DIR/config.php" <<EOF
<?php
// Global (out-of-game) configuration - generated by $SCRIPT_NAME.
//
// src/config.php loads this plus the world's connection.php (CONNECTION_FILE)
// and merges both into \$config->db / \$config->settings / \$config->game.
//
// SINGLE-HOST layout: the game, the portal (/portal/), the API (/api/) and the
// asset pack (/cdn/) are all served from one port on $HOST. The three things
// that used to bake a hostname into the pages are relative now:
//   asset urls      'cdnBaseUrl'          -> "/cdn/..."
//   portal api url  main-*.bundle.js      -> location.origin + "/api/v1/"
//   Register link   src/mainInclude.php   -> "/portal/?server=1#register"
// so the same install works over a LAN ip, a public ip or a domain.
global \$globalConfig;
\$globalConfig = [];
\$globalConfig['staticParameters'] = [];
\$globalConfig['dataSources'] = [];

// --- absolute urls: only mail templates and the world list need these -------
\$globalConfig['staticParameters']['indexUrl'] = '$INDEX_URL';
\$globalConfig['staticParameters']['forumUrl'] = '$INDEX_URL';
\$globalConfig['staticParameters']['answersUrl'] = '$INDEX_URL';
\$globalConfig['staticParameters']['helpUrl'] = '$INDEX_URL';
\$globalConfig['staticParameters']['adminEmail'] = '${ADMIN_EMAIL:-admin@travium.local}';

// --- assets: root-relative, served by the Alias /cdn ------------------------
// Leave this key out to get the upstream //cdn.<domain> behaviour instead.
\$globalConfig['staticParameters']['cdnBaseUrl'] = '/cdn';

// Captcha is disabled for this deployment (see the patches in
// src/functions.general.php and src/Core/Session.php); these keys are inert.
\$globalConfig['staticParameters']['recaptcha_public_key'] = 'local_recaptcha_public';
\$globalConfig['staticParameters']['recaptcha_private_key'] = 'local_recaptcha_private';

// --- main database (maindb): world list, payments, activation codes ---------
\$globalConfig['dataSources']['globalDB']['hostname'] = 'db';
\$globalConfig['dataSources']['globalDB']['username'] = '$DB_USER';
\$globalConfig['dataSources']['globalDB']['password'] = '$DB_PASS';
\$globalConfig['dataSources']['globalDB']['database'] = 'maindb';
\$globalConfig['dataSources']['globalDB']['charset'] = 'utf8mb4';

// --- mail --------------------------------------------------------------------
// driver=local goes through PHP mail(); the container has no MTA, so
// php-mail-capture.ini points sendmail_path at a wrapper that appends every
// message to /tmp/php-mail.log. Switch to driver=smtp + smtp_* to really send.
// from_email must be a valid address (PHPMailer validates it) - an ip is not.
\$globalConfig['mailer'] = [
    'driver' => 'local',
    'from_email' => '$MAIL_FROM',
    'from_name' => 'Travium',
    'smtp_host' => '',
    'smtp_user' => '',
    'smtp_pass' => '',
    'smtp_port' => '587',
    'smtp_encryption' => 'tls',
    'smtp_auth' => true,
];

// --- voting (only used with the voting integration) -------------------------
\$globalConfig['voting'] = [
    'secret' => '$(rand 32)',
    'gtop100' => '$INDEX_URL',
    'topg' => '$INDEX_URL',
    'arenatop100' => '$INDEX_URL',
];

// --- misc -------------------------------------------------------------------
\$globalConfig['installer_key'] = '$(rand 24)';
\$globalConfig['staticParameters']['default_language'] = 'en';
\$globalConfig['staticParameters']['default_timezone'] = 'UTC';
\$globalConfig['staticParameters']['default_direction'] = 'LTR';
\$globalConfig['staticParameters']['default_dateFormat'] = 'y.m.d';
\$globalConfig['staticParameters']['default_timeFormat'] = 'H:i';
\$globalConfig['staticParameters']['session_timeout'] = 6 * 3600;
\$globalConfig['staticParameters']['default_payment_location'] = 2;
\$globalConfig['staticParameters']['global_css_class'] = 'travium';

// --- asset pack -------------------------------------------------------------
// get_gpack_version() returns 'default' and get_gpack_cdn_mainPage_url()
// hardcodes a17a8f72, which must match the checked-out integrations/cdn tree.
\$globalConfig['staticParameters']['gpacks'] = [
    'default' => 'a17a8f72',
    'list' => [
        'a17a8f72' => ['hash' => 'a17a8f72', 'name' => 'Travian T4.5', 'isNew' => true],
        '68597666' => ['hash' => '68597666', 'name' => 'Travian T4.4 Seasonized', 'isNew' => false],
        'd11cb434' => ['hash' => 'd11cb434', 'name' => 'Travian T4.4 Seasonized v2', 'isNew' => false],
        '3f73c13f' => ['hash' => '3f73c13f', 'name' => 'Travian T4.6', 'isNew' => false],
        '29c89d54' => ['hash' => '29c89d54', 'name' => 'Travian T4.6', 'isNew' => true],
        'TravianOld' => ['hash' => 'TravianOld', 'name' => 'Travian T4.4 Classic', 'isNew' => false],
    ],
];

\$globalConfig['cachingServers'] = ['memcached' => [['127.0.0.1', 11211]]];
EOF
    ok "config.php    $SRC_DIR/config.php$backup"
}

gen_world_files() {
    local world_dir="$SRC_DIR/servers/$WORLD"
    if [ -d "$world_dir" ] && [ "$FORCE" = "1" ]; then
        local archive="${world_dir}-$(date +%s)"
        warn "archiving the existing world to $archive"
        mv "$world_dir" "$archive"
    fi
    if [ ! -d "$world_dir" ]; then
        mkdir -p "$world_dir"
        cp -a "$SRC_DIR/server.tpl/." "$world_dir/"
    fi
    mkdir -p "$world_dir/backups"

    write_file "$world_dir/include/env.php" <<'EOF'
<?php
define("IS_DEV", true);
define("SRC_PATH_PROD", dirname(__DIR__,3) . "/src");
define("SRC_PATH_DEV", dirname(__DIR__,3) . "/src");
define("PUBLIC_PATH", dirname(__DIR__) . "/public/");
define("CONNECTION_FILE", __DIR__ . '/connection.php');
define("CONFIG_CUSTOM_FILE", __DIR__ . '/config.custom.php');
define("ERROR_LOG_FILE", __DIR__ . '/error_log.log');
define("GLOBAL_CONFIG_FILE", dirname(__DIR__, 3) . '/config.php');
define("BACKUP_PATH", dirname(__DIR__) . '/backups/');
define("FILTERING_PATH", SRC_PATH_PROD . '/filtering/');
// Where the portal (homepage/) is mounted on this host; the game's Register
// link redirects here. See src/mainInclude.php.
define("REGISTER_PATH", '/portal/');
EOF

    write_file "$world_dir/include/connection.php" <<EOF
<?php
// Per-world settings - generated by $SCRIPT_NAME.
// src/config.php reads this file through CONNECTION_FILE (env.php) and merges it
// into \$config->db / \$config->settings / \$config->game.
global \$connection;
\$connection = [
    'speed' => '$SPEED',
    'round_length' => '$ROUND_LENGTH',
    'worldId' => '$WORLD',
    'secure_hash_code' => '$(rand 32)',
    'title' => '$WORLD',
    'gameWorldUrl' => '$GAME_WORLD_URL',
    'serverName' => '$WORLD',
    'auto_reinstall' => '0',
    'auto_reinstall_start_after' => '0',
    'engine_filename' => 'engine.php',
    'database' => [
        'hostname' => 'db',
        'username' => '$DB_USER',
        'password' => '$DB_PASS',
        'database' => '$DB_NAME',
        'charset' => 'utf8mb4',
    ],
];
EOF

    write_file "$world_dir/include/config.custom.php" <<'EOF'
<?php
// Per-world gameplay overrides, loaded last (src/config/config.after.php).
global $globalConfig, $config;

// Gold and quality-of-life options.
$config->game->protection_time = 24 * 3600;

// --- gold ---------------------------------------------------------------
// Unlimited gold: Session::loadData() overwrites gift_gold with a huge number
// for every logged-in player, so every premium feature is free and the UI shows
// "Unlimited" instead of a balance. Flip to true if you want that.
$config->custom->serverIsFreeGold = false;

// Gold as a gift: startGold goes to every new account, dailyGold is added to
// every player once a day by the automation engine (Core\Automation). Prices
// below override src/config/config.custom.php.
$config->gold->startGold = 100;
$config->gold->dailyGold = 25;
$config->gold->plusGold = 25;                 // one Plus account
$config->gold->goldClubGold = 250;            // gold club
$config->gold->productionBoostGold = 15;      // +25% production
$config->gold->finishNowGold = 2;             // finish a building instantly
$config->gold->exchangeResourcesGold = 3;     // NPC trader
$config->gold->completeDemolishGold = 10;     // demolish completely
$config->gold->invitePlayerGold = 0;          // reward for inviting a friend

// The ACP "Gifts" page (admin.php?action=gifts) - gift gold to one player or to
// everyone, gift resources, fill storage - is gated on this value, but the ACP
// overwrites it per admin session (src/admin/include/Core/Dispatcher.php). Those
// tools therefore stay "Disabled by admin." until interruption mode is switched
// on for that session, once per login:
//     admin.php?allowInterruption
//   or click "(System time)" in the ACP footer (the legacy ?AmirhosseinMatini
//   link, whose handler used to be commented out).
// This line only covers code paths outside the ACP.
$config->custom->allowInterruptionInGame = true;

// --- premium features players can buy with gold -------------------------
// The stock config leaves most of these off (buyResources/buyTroops/buyAnimal
// are even force-disabled below 1000x speed), so enable them here.
//
// Paid auto raid: the player pays autoRaidGold once and from then on every
// village marked in any of their farm lists is attacked automatically, every N
// minutes (N is the player's choice, 5..1440), for the rest of the round.
// The panel appears on the farm list page (build.php?gid=16&tt=99).
$config->custom->autoRaidPremiumEnabled = true;
$config->gold->autoRaidGold = 250;
$config->extraSettings->buyResources['enabled'] = true;   // buy resources
$config->extraSettings->buyTroops['enabled'] = true;      // buy troops
$config->extraSettings->buyAnimal['enabled'] = true;      // buy animals
$config->extraSettings->buyBuildings['enabled'] = true;   // instant buildings
$config->extraSettings->upgradeToMaxLevel->enabled = true;
$config->extraSettings->upgradeStorageToMaxLevel->enabled = true;
$config->extraSettings->smithyMaxLevel->enabled = true;
$config->extraSettings->addFarms->enabled = true;         // extra farm lists
$config->extraSettings->generalOptions->finishTraining->enabled = true;
$config->extraSettings->generalOptions->fasterTraining->enabled = true;
$config->extraSettings->generalOptions->cancelTrainingQueue->enabled = true;
$config->extraSettings->generalOptions->buyAdventure->enabled = true;
$config->extraSettings->generalOptions->increaseStorage->enabled = true;
$config->extraSettings->generalOptions->oneHourOfProduction->enabled = true;
$config->extraSettings->generalOptions->smithyUpgradeAllToMax->enabled = true;
$config->extraSettings->generalOptions->academyResearchAll->enabled = true;
$config->extraSettings->generalOptions->rallyPointTo20->enabled = true;
// "Upgrade Resources Fields to level N" are buyBuildings packages, not
// generalOptions entries: the payment wizard renders the packages and
// premiumFeature::buyBuildings() executes them. Enabling the generalOptions
// keys above did nothing (their handlers are commented out in
// Controller/Ajax/premiumFeature.php), so the level-30 button stayed dead.
$config->extraSettings->buyBuildings['packages']['upgradeAllResourcesTo20']->enabled = true;
$config->extraSettings->buyBuildings['packages']['upgradeAllResourcesTo30']->enabled = true;
$config->extraSettings->power->atkBonus->enabled = true;  // +attack power
$config->extraSettings->power->atkBonus->duration = 3;    // hours
$config->extraSettings->power->defBonus->enabled = true;  // +defence power
$config->extraSettings->power->defBonus->duration = 3;    // hours
// Hourly protection packages stay gated by src/config/config.custom.php, which
// enables them until the WW plans are released.

// Fake (AI) players - the game's bots.
//
// Country flags: Core\Model\AutomationModel::getRandomCountryFlag() reads this
// property directly, and src/config/config.official.php (which would define it)
// is never required, so without it every bot creation raises an undefined
// property warning - fatal in CLI, where Core\ErrorHandler turns warnings into
// exceptions.
$config->fakeUsersCountryCodes = ['VN', 'US', 'DE', 'GB', 'SG'];

// src/config/config.custom.php sets fakeUsersCount to a random 40-100. The
// automation engine uses it once, on the first run after the server starts
// (Core\Automation::setUpNewServer) to populate a fresh world. Set it to 0 to
// leave the population to './deploy-travium-docker.sh bots N'.
// $config->fakeUsersCount = 0;
EOF

    [ -f "$world_dir/include/error_log.log" ] || : >"$world_dir/include/error_log.log"
    ok "world         $world_dir"
}

gen_all_files() {
    step "generating deployment files ($DEPLOY_DIR)"
    ensure_env_file
    gen_dockerfile
    gen_php_cve_patch
    gen_php_hardening
    gen_apache_hardening
    gen_apt_probe
    gen_mail_capture
    gen_vhost
    gen_compose
    gen_caddyfile
    # These three write into the source tree, not into $DEPLOY_DIR, and they
    # carry this deployment's database passwords. A --dry-run must not touch
    # them: it is how you look at what would be generated, not a deploy.
    if [ "$DRY_RUN" = "1" ]; then
        warn "config.php and servers/$WORLD/ are left untouched (dry run)"
    else
        gen_global_config
        gen_world_files
        gen_bots_helper
    fi
    echo
}

# ================================================================== docker ===
start_stack() {
    step "starting containers"
    if [ "$BUILD" = "1" ]; then
        log "building the PHP image - the first build downloads apt packages and pecl-redis (a few minutes)"
        # Build with the host network on purpose. On a stock Ubuntu box the
        # container's /etc/resolv.conf points at systemd-resolved (127.0.0.53),
        # which nothing listens on inside the build's network namespace, so
        # apt fails with "Temporary failure resolving 'archive.debian.org'"
        # and then reports a misleading "Unable to locate package".
        # Override with --build-network default if you really want the bridge.
        if [ "$BUILD_NETWORK" != "default" ]; then
            if ! docker build --network="$BUILD_NETWORK" -t "$PHP_IMAGE_TAG" "$DEPLOY_DIR"; then
                warn "build failed with --network=$BUILD_NETWORK"
                warn "if the log mentions 'Temporary failure resolving', fix the daemon DNS:"
                warn "  echo '{\"dns\":[\"1.1.1.1\",\"8.8.8.8\"]}' | sudo tee /etc/docker/daemon.json && sudo systemctl restart docker"
                die "image build failed"
            fi
        else
            docker build -t "$PHP_IMAGE_TAG" "$DEPLOY_DIR" || die "image build failed"
        fi
    fi
    compose up -d
    ok "containers started"
}

wait_for_db() {
    step "waiting for MySQL"
    local i=0
    until compose exec -T db mysqladmin ping -h 127.0.0.1 -uroot -p"$DB_ROOT_PASS" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -gt 150 ] && die "MySQL did not become ready (docker compose logs db)"
        sleep 2
    done
    ok "MySQL is up"
}

create_databases() {
    step "databases and the game user"
    sql_root "CREATE DATABASE IF NOT EXISTS \`maindb\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sql_root "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sql_root "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
    sql_root "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
    sql_root "GRANT ALL PRIVILEGES ON \`maindb\`.* TO '$DB_USER'@'%';"
    sql_root "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
    sql_root "FLUSH PRIVILEGES;"
    ok "maindb + $DB_NAME + user $DB_USER"
}

import_sql() { # import_sql <file-relative-to-src> <database>
    log "importing $1 -> $2"
    compose exec -T db mysql -uroot -p"$DB_ROOT_PASS" "$2" <"$SRC_DIR/$1"
}

maindb_ready() {
    [ "$(sql_scalar maindb "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='maindb' AND table_name='gameServers'")" = "1" ] && echo 1 || echo 0
}

import_global_schema() {
    step "global schema (maindb.sql)"
    import_sql "maindb.sql" "maindb"
    ok "maindb: $(sql_scalar maindb 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=SCHEMA()') tables"
}

world_installed() {
    [ "$(sql_scalar "$DB_NAME" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME' AND table_name='config'")" = "1" ] || { echo 0; return; }
    sql_scalar "$DB_NAME" "SELECT installed FROM config LIMIT 1"
}

import_world_schema() {
    step "world schema (src/schema/T4.4.sql)"
    import_sql "src/schema/T4.4.sql" "$DB_NAME"
    ok "world DB: $(sql_scalar "$DB_NAME" 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=SCHEMA()') tables"
}

register_world() {
    step "registering the world"
    local start_ts
    start_ts="$(date -d "$START_TIME" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$START_TIME" +%s 2>/dev/null || true)"
    [ -n "$start_ts" ] || die "cannot parse --start '$START_TIME' (use 'YYYY-MM-DD HH:MM:SS')"

    local existing
    existing="$(sql_scalar maindb "SELECT id FROM gameServers WHERE worldId='$WORLD' LIMIT 1" || true)"
    if [ -n "$existing" ]; then
        WORLD_UNIQUE_ID="$existing"
        sql_db maindb "UPDATE gameServers SET gameWorldUrl='$GAME_WORLD_URL', configFileLocation='/var/www/app/servers/$WORLD/include/connection.php', speed=$SPEED, roundLength=$ROUND_LENGTH, startTime=$start_ts WHERE id=$existing;"
        log "gameServers already lists worldId=$WORLD (id=$existing) - refreshed its urls"
    else
        sql_db maindb "INSERT INTO gameServers
            (worldId, speed, name, version, gameWorldUrl, startTime, roundLength,
             preregistration_key_only, promoted, hidden, configFileLocation, activation)
            VALUES ('$WORLD', $SPEED, '$WORLD', 0, '$GAME_WORLD_URL', $start_ts, $ROUND_LENGTH,
                    0, 0, 0, '/var/www/app/servers/$WORLD/include/connection.php', 0);"
        WORLD_UNIQUE_ID="$(sql_scalar maindb "SELECT id FROM gameServers WHERE worldId='$WORLD' LIMIT 1")"
    fi
    [ -n "$WORLD_UNIQUE_ID" ] || die "could not read gameServers.id"
    ok "worldUniqueId $WORLD_UNIQUE_ID   gameWorldUrl $GAME_WORLD_URL"

    if [ "$(sql_scalar "$DB_NAME" 'SELECT COUNT(*) FROM config')" = "0" ]; then
        sql_db "$DB_NAME" "INSERT INTO config
            (startTime, map_size, worldUniqueId, installed, loginInfoTitle, loginInfoHTML, message)
            VALUES ($start_ts, $MAP_SIZE, $WORLD_UNIQUE_ID, 0, '', '', '');"
        ok "config row created (map $MAP_SIZE)"
    else
        sql_db "$DB_NAME" "UPDATE config SET worldUniqueId=$WORLD_UNIQUE_ID, startTime=$start_ts, map_size=$MAP_SIZE;"
        log "config row updated"
    fi
}

fix_permissions() {
    step "permissions for www-data (uid 33)"
    # A bind mount keeps host ownership while Apache runs as www-data. These are
    # the paths the game writes: the world's error/automation log and backups, the
    # filtering lists edited from the ACP, and the API's Twig cache.
    compose exec -T web bash -lc "
        set -e
        for p in \
            /var/www/app/servers/$WORLD/include \
            /var/www/app/servers/$WORLD/backups \
            /var/www/app/src/filtering \
            /var/www/app/integrations/api/include/Templates/Cache ; do
            [ -e \"\$p\" ] || continue
            chown -R www-data:www-data \"\$p\" 2>/dev/null || true
            chmod -R u+rwX,g+rwX \"\$p\" 2>/dev/null || true
        done
        touch /var/www/app/servers/$WORLD/include/error_log.log
        chown www-data:www-data /var/www/app/servers/$WORLD/include/error_log.log 2>/dev/null || true
        echo ok
    " >/dev/null
    ok "writable paths are writable by the web server"
}

run_world_installer() {
    step "world installer (map, Natars, WW villages, Multihunter)"
    log "this generates the whole map - a minute or two on a 201x201 world"
    compose exec -T web php "/var/www/app/servers/$WORLD/include/install.php" install "$ADMIN_PASS"
    step "updater (patch level)"
    compose exec -T web php "/var/www/app/servers/$WORLD/include/update.php" || warn "updater returned non-zero (often harmless on a fresh world)"
    fix_permissions
    local installed
    installed="$(sql_scalar "$DB_NAME" 'SELECT installed FROM config LIMIT 1')"
    [ "$installed" = "1" ] || die "the installer did not finish (config.installed=$installed) - read servers/$WORLD/include/error_log.log"
    ok "world installed"
    restart_engine
}

# The automation engine finishes buildings, troop training, hero adventures,
# attacks and runs the bots. It reads the whole game config when it starts, so
# starting it before the world exists (which is what a container boot does on a
# first deploy) kills it - and then every countdown reaches zero and nothing
# happens. So: (re)start it once the world is installed, and say so loudly if it
# is not up.
#
# Only php processes running engine.php match. The container's supervisor is a
# bash subshell whose command line also contains the path, so the pattern is
# anchored to the beginning of the command line - a broader one killed the
# supervisor together with the engine, leaving nothing to restart it.
engine_pattern() {
    printf '^php .*include/engine\\.php'
}

engine_pids() {
    compose exec -T web bash -lc "pgrep -f '$(engine_pattern)' 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r' || echo 0
}

restart_engine() {
    [ "$ENGINE" = "1" ] || { log "automation engine disabled (--no-engine)"; return 0; }
    step "automation engine"
    compose exec -T web bash -lc "pkill -f '$(engine_pattern)' 2>/dev/null; sleep 1; rm -f /tmp/engine.pid; true" >/dev/null 2>&1 || true
    compose exec -T web bash -lc "
        cd /var/www/app
        setsid env TRAVIUM_UNDER_SYSTEMD=1 php '/var/www/app/servers/$WORLD/include/engine.php' >>/tmp/engine.log 2>&1 < /dev/null &
        sleep 2
        exit 0
    " >/dev/null 2>&1 || true
    local pids
    pids="$(engine_pids)"
    if [ "${pids:-0}" -gt 0 ] 2>/dev/null; then
        ok "engine running ($pids processes) - buildings, training, adventures and bots are processed"
    else
        warn "the automation engine is NOT running."
        warn "  Without it every countdown finishes and nothing happens (troops never"
        warn "  arrive, hero adventures never resolve, buildings never complete)."
        warn "  Check: $SCRIPT_NAME logs web   and   servers/$WORLD/include/automation.log"
        warn "  Start: $SCRIPT_NAME engine start"
    fi
}

verify_http() {
    step "verification"
    local failed=0

    # Nothing is published for the web container when Caddy fronts it, so in TLS
    # mode ask the app from inside the container instead of from the host.
    http_body() { # <path>
        if [ "$TLS" = "1" ]; then
            compose exec -T web php -r "echo @file_get_contents('http://127.0.0.1$1') ?: '';" 2>/dev/null || true
        else
            curl -fsS --max-time 25 "http://127.0.0.1:$PORT$1" 2>/dev/null || true
        fi
    }
    check_url() { # <label> <path> <expect-substring|->
        local label="$1" path="$2" expect="$3" body
        body="$(http_body "$path")"
        if [ -n "$body" ] && { [ "$expect" = "-" ] || printf '%s' "$body" | grep -q -- "$expect"; }; then
            ok "$label   ok"
        else
            warn "$label   no usable response on $path"
            failed=1
        fi
    }
    check_url "game    " "/"                                        "Travian"
    check_url "portal  " "/portal/"                                 "app-root"
    check_url "api     " "/api/v1/loadConfig"                       "defaultLang"
    check_url "cdn     " "/cdn/a17a8f72/mainPage/lang/en-US/compact.css" "-"
    check_url "register" "/anmelden.php"                            "actor"

    if [ "$TLS" = "1" ]; then
        log "HTTPS is served by Caddy: $BASE_URL/  (DNS for $HOST must point here, ports 80 and $PORT open)"
    fi
    [ "$failed" = "0" ] || warn "some checks failed - inspect: $SCRIPT_NAME logs web"
}

print_summary() {
    cat <<EOF

${C_BOLD}Deployment ready${C_RESET}

  game      $BASE_URL/
  portal    $BASE_URL/portal/            <- registration
  api       $BASE_URL/api/v1/
  assets    $BASE_URL/cdn/
  admin     $BASE_URL/admin.php          (log in as an admin first)

  Reachable at that url from this machine, your LAN and (with the port open /
  a DNS record) the internet. Nothing else needs configuring: the paths are
  relative, so a LAN ip, a public ip or a domain all work.

  admin account   Multihunter / $ADMIN_PASS
  game database   $DB_NAME   (user $DB_USER)
  main database   maindb
  deployment      $DEPLOY_DIR
  captured mail   docker compose -f $DEPLOY_DIR/docker-compose.yml exec web cat /tmp/php-mail.log

  ${C_BOLD}Log in${C_RESET}
    game login    $BASE_URL/login.php
    admin panel   $BASE_URL/admin.php
    admin account Multihunter / $ADMIN_PASS      <- generated unless you passed --admin-pass
                  change it any time with: $SCRIPT_NAME passwd <new-password>
    gift gold     $BASE_URL/admin.php?action=gifts
                  (enable once per admin session at $BASE_URL/admin.php?allowInterruption,
                   or click "(System time)" in the ACP footer)

  ${C_BOLD}Next steps${C_RESET}
    $SCRIPT_NAME status              container state
    $SCRIPT_NAME logs web            follow the web logs
    $SCRIPT_NAME creds               urls + passwords
    $SCRIPT_NAME bots 30             add fake (AI) players to play against
    $SCRIPT_NAME passwd              list accounts, or reset a password
    $SCRIPT_NAME engine status       automation daemon (bots, Natars, backups)
    $SCRIPT_NAME set-port 9000       move everything to another port (keeps the world)
    $SCRIPT_NAME install --host X    repoint the absolute urls (mail links) at another address
    $SCRIPT_NAME install-world --force   rebuild this world from scratch

EOF
}

print_creds() {
    cat <<EOF
deployment     : $DEPLOY_DIR
source tree    : $SRC_DIR
served at      : $BASE_URL/   (game, /portal/, /api/, /cdn/)
world          : $WORLD   (database $DB_NAME, user $DB_USER)
admin account  : Multihunter / $ADMIN_PASS
mysql root     : $DB_ROOT_PASS
game db pass   : $DB_PASS
mail from      : $MAIL_FROM
EOF
}

load_env_file() {
    local f="$DEPLOY_DIR/.env"
    [ -f "$f" ] || die "no deployment found in $DEPLOY_DIR - run: $SCRIPT_NAME install"
    # shellcheck disable=SC1090
    set -a; . "$f"; set +a
    [ -n "${PHP_IMAGE_TAG:-}" ] || PHP_IMAGE_TAG="travium-php:7.3"
    [ -n "${PORT:-}" ] || PORT=80
    [ -n "${BASE_URL:-}" ] || BASE_URL="http://${HOST:-127.0.0.1}"
}

# ============================================================ the installer ===
do_install() {
    check_docker
    gen_all_files
    if [ "$DRY_RUN" = "1" ]; then
        ok "dry run - files are in $DEPLOY_DIR, Docker was not touched"
        ok "would serve everything on $BASE_URL/ (port $PORT)"
        return 0
    fi
    warn_if_port_busy
    start_stack
    wait_for_db
    create_databases

    if [ "$FORCE" = "1" ]; then
        warn "--force: dropping maindb and $DB_NAME"
        sql_root "DROP DATABASE IF EXISTS \`maindb\`; CREATE DATABASE \`maindb\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        sql_root "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        sql_root "GRANT ALL PRIVILEGES ON \`maindb\`.* TO '$DB_USER'@'%';"
        sql_root "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES;"
    fi

    if [ "$(maindb_ready)" = "1" ]; then
        log "maindb is already imported"
    else
        import_global_schema
    fi

    if [ "$FORCE" != "1" ] && [ "$(world_installed)" = "1" ]; then
        warn "this world is already installed - nothing to do."
        warn "re-run with --force to wipe and reinstall it, or use '$SCRIPT_NAME install-world'."
        register_world
    else
        [ "$FORCE" != "1" ] && sql_db maindb "DELETE FROM gameServers WHERE worldId='$WORLD';"
        import_world_schema
        register_world
        run_world_installer
    fi
    fix_permissions
    verify_http
    print_summary
}

do_install_world() {
    load_env_file
    check_docker
    gen_world_files
    compose up -d >/dev/null
    wait_for_db
    if [ "$FORCE" = "1" ]; then
        warn "--force: dropping $DB_NAME and its gameServers row"
        sql_root "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        sql_root "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES;"
        sql_db maindb "DELETE FROM gameServers WHERE worldId='$WORLD';"
    elif [ "$(world_installed)" = "1" ]; then
        warn "already installed - use --force to rebuild"; return 0
    fi
    import_world_schema
    register_world
    run_world_installer
    verify_http
    print_summary
}

do_reset() {
    load_env_file
    check_docker
    confirm "This removes the containers AND the database volume of '$WORLD'. Continue?" || die "cancelled"
    compose down -v
    ok "removed - '$SCRIPT_NAME install' deploys it again"
}

# Diagnose a host before/after a failed deploy: docker itself, disk/memory, the
# requested port and - the usual culprit for "apt-get ... exit code 100" - what
# the php:7.3-apache image can actually fetch from the Debian archive.
do_doctor() {
    check_docker
    if [ -f "$DEPLOY_DIR/.env" ]; then load_env_file; else [ -n "$PORT" ] || PORT=80; fi

    step "docker"
    docker version --format 'client  {{.Client.Version}}' 2>/dev/null || true
    docker version --format 'server  {{.Server.Version}}' 2>/dev/null || warn "cannot read the server version"
    docker compose version 2>/dev/null | sed 's/^/compose /' || true
    docker info --format 'driver  {{.Driver}}   cpus {{.NCPU}}   memory {{.MemTotal}}' 2>/dev/null || true

    step "host"
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "os      $PRETTY_NAME"; else uname -a; fi
    echo "kernel  $(uname -r)"
    { df -h / 2>/dev/null | awk 'NR==2{print "disk    "$4" free of "$2}'; } || true
    { free -m 2>/dev/null | awk 'NR==2{print "memory  "$7" MB available"}'; } || true

    step "port"
    echo "port    $PORT"
    warn_if_port_busy

    step "php2shell (CVE-2026-109618 / CVE-2026-109619)"
    if [ "$PHP_CVE_PAT" = "1" ]; then
        ok "the next build patches PHP 7.3.33 and rebuilds it from source"
        if [ -f "$SCRIPT_DIR/deploy/php-7.3-cve-2026-109618-109619.patch" ]; then
            echo "patch   $(wc -l <"$SCRIPT_DIR/deploy/php-7.3-cve-2026-109618-109619.patch" | tr -d ' ') lines, $(grep -c '^--- a/' "$SCRIPT_DIR/deploy/php-7.3-cve-2026-109618-109619.patch") files"
        else
            warn "deploy/php-7.3-cve-2026-109618-109619.patch is missing - the build will fail"
        fi
        # Is the container that is running right now the patched one?
        if compose ps web >/dev/null 2>&1 && [ -n "$(compose ps -q web 2>/dev/null)" ]; then
            if compose exec -T web php -r 'exit(ini_get("max_multipart_body_parts") === false ? 1 : 0);' >/dev/null 2>&1; then
                ok "the running container IS patched: $(compose exec -T web php -r 'echo PHP_VERSION;' 2>/dev/null)"
            else
                warn "the running container is NOT patched - rebuild it:"
                warn "  $SCRIPT_NAME install          (rebuilds the image, keeps the world data)"
            fi
        else
            log "no running web container to inspect"
        fi
    else
        warn "--no-php-patch is in effect: the image will be VULNERABLE to php2shell"
    fi

    step "dns inside containers (the cause of 'Temporary failure resolving')"
    log "resolv.conf a normal container gets:"
    docker run --rm alpine cat /etc/resolv.conf 2>/dev/null | sed 's/^/          /' || warn "could not run alpine"
    log "resolving archive.debian.org with the default bridge network:"
    if docker run --rm alpine sh -c 'getent hosts archive.debian.org' 2>/dev/null | sed 's/^/          /'; then
        ok "the default network can resolve it"
    else
        warn "the default network CANNOT resolve it - this is why apt exits 100"
    fi
    log "resolving with host networking (what the build uses by default):"
    if docker run --rm --network=host alpine sh -c 'getent hosts archive.debian.org' 2>/dev/null | sed 's/^/          /'; then
        ok "host networking resolves it - 'install' will build fine"
    else
        warn "host networking cannot resolve it either: fix the host's DNS"
        warn "  cat /etc/resolv.conf;  nslookup archive.debian.org"
        warn "  or set a resolvable DNS for the daemon in /etc/docker/daemon.json"
    fi

    step "base image + apt (the step that reports exit code 100)"
    gen_apt_probe
    # Feed the probe over stdin: no container path appears on the command line,
    # which keeps MSYS/Git-Bash from rewriting it into a Windows path.
    # --network=host matches how the real build runs (see start_stack).
    if ! docker run --rm -i --network="$BUILD_NETWORK" php:7.3-apache bash -s <"$DEPLOY_DIR/apt-probe.sh"; then
        warn "could not run the probe - is the php:7.3-apache image pullable from this host?"
    fi

    step "reading the result"
    cat <<EOF
Every package above needs a version. If any says MISSING, or apt-get update
printed "Temporary failure resolving", the build container has no working DNS:

  * on Ubuntu this is usually systemd-resolved: the container's /etc/resolv.conf
    points at 127.0.0.53, where nothing answers inside the container
  * the deploy script builds with 'docker build --network=host' for exactly this
    reason (change it with --build-network default)
  * permanent fix for the daemon:
        cat /etc/docker/daemon.json                      # look first
        echo '{"dns":["1.1.1.1","8.8.8.8"]}' | sudo tee /etc/docker/daemon.json
        sudo systemctl restart docker

Then re-run: $SCRIPT_NAME install
EOF
}

# Set a login password. The game stores sha1(password) in users.password
# (unsalted), so this is the whole job - no need to re-run the installer.
#   ./deploy-travium-docker.sh passwd            -> list the accounts that log in
#   ./deploy-travium-docker.sh passwd admin123   -> reset Multihunter's password
#   ./deploy-travium-docker.sh passwd meo9xit pw -> reset another account
do_passwd() {
    load_env_file
    check_docker
    local user="${POSITIONAL[0]:-}" pass="${POSITIONAL[1]:-}"

    if [ -z "$user" ]; then
        step "accounts in '$DB_NAME' that can log in"
        sql_db "$DB_NAME" "SELECT id, name, access, IF(access=2,'admin',IF(access=0,'player','player')) AS kind FROM users WHERE access<3 ORDER BY id"
        echo
        log "usage: $SCRIPT_NAME passwd [user] <new-password>    (default user: Multihunter)"
        log "the AI bots (access=3) cannot log in - there are $(sql_scalar "$DB_NAME" "SELECT COUNT(*) FROM users WHERE access=3") of them"
        return 0
    fi

    # One argument means "reset Multihunter".
    if [ -z "$pass" ]; then
        pass="$user"
        user="Multihunter"
    fi

    case "$user" in
        *[!A-Za-z0-9_.\ -]*) die "unexpected character in the user name: '$user'" ;;
    esac

    local hash
    hash="$(printf '%s' "$pass" | sha1sum | awk '{print $1}')"
    [ -n "$hash" ] || die "cannot hash the password (is sha1sum installed?)"

    [ "$(sql_scalar "$DB_NAME" "SELECT COUNT(*) FROM users WHERE name='$user'")" = "1" ] \
        || die "no account named '$user' in $DB_NAME - run '$SCRIPT_NAME passwd' to list them"

    sql_db "$DB_NAME" "UPDATE users SET password='$hash' WHERE name='$user'"
    ok "password updated for '$user'"
    log "log in at   $BASE_URL/login.php      (the game login, not the portal sign-up)"
    log "admin panel $BASE_URL/admin.php      (Multihunter or an access=2 account)"
}

# Populate the world with fake (AI) players. They are ordinary accounts with
# access=3 and a village, and they grow by themselves while the automation
# engine runs (AI::doSomethingRandom + village expansion), which is also what
# makes the rankings and the map look alive.
do_bots() {
    load_env_file
    check_docker
    local n="${POSITIONAL[0]:-25}"
    case "$n" in ''|*[!0-9]*) die "usage: $SCRIPT_NAME bots [count]   (e.g. $SCRIPT_NAME bots 30)" ;; esac
    [ "$n" -ge 1 ] || die "count must be at least 1"
    gen_bots_helper
    step "creating $n fake player(s)"
    compose exec -T web php "/var/www/app/servers/$WORLD/include/make-bots.php" "$n"
    ok "done - see statistiken.php (Show fake users) or the map for the new villages"
    if [ "$(engine_pids)" = "0" ]; then
        warn "the automation engine is not running, so the bots will not grow."
        warn "start it with: $SCRIPT_NAME engine start"
    fi
}

# Change the port (or any other generated setting) without touching the world
# data: regenerate the files, recreate the container with the new mapping, point
# the absolute urls at the new address and verify.
do_set_port() {
    # Take the requested port before load_env_file() sources .env (which would
    # otherwise overwrite it with the current value).
    local req_port="${POSITIONAL[0]:-}"
    [ -n "$req_port" ] || req_port="$PORT"
    load_env_file
    check_docker
    PORT="$req_port"
    [ -n "$PORT" ] || die "usage: $SCRIPT_NAME set-port <port>   (e.g. $SCRIPT_NAME set-port 9000)"
    validate_port "$PORT"
    compute_urls
    if [ "$TLS" = "1" ] && [ "$IS_IP" = "1" ]; then
        die "--tls is enabled but HOST=$HOST is an ip - rerun '$SCRIPT_NAME install --host <domain> --tls' instead"
    fi
    warn_if_port_busy
    gen_all_files
    if [ "$DRY_RUN" = "1" ]; then
        ok "dry run - files are in $DEPLOY_DIR, Docker was not touched"
        ok "would serve everything on $BASE_URL/ (port $PORT)"
        return 0
    fi
    load_env_file                     # pick up the freshly written .env
    step "applying the new port"
    compose up -d
    wait_for_db
    register_world
    verify_http
    print_summary
}

do_engine() {
    load_env_file
    check_docker
    case "${POSITIONAL[0]:-status}" in
        start|restart)
            restart_engine ;;
        stop)
            compose exec -T web bash -lc "pkill -f '$(engine_pattern)' 2>/dev/null; rm -f /tmp/engine.pid; true" >/dev/null 2>&1 || true
            warn "engine stopped - countdowns will now finish with nothing happening"
            warn "  the container's supervisor will start it again within 15 seconds;"
            warn "  to keep it down, start the stack with --no-engine instead" ;;
        status)
            local pids
            pids="$(engine_pids)"
            if [ "${pids:-0}" -gt 0 ] 2>/dev/null; then
                ok "engine running ($pids processes)"
                compose exec -T web bash -lc "pgrep -fa 'include/engine.php' | head -n 5" 2>/dev/null | sed 's/^/    /'
            else
                warn "engine is NOT running"
                warn "  buildings, troop training, hero adventures and the bots are not processed"
                warn "  start it with: $SCRIPT_NAME engine start"
            fi ;;
        logs)
            compose exec -T web bash -lc "echo '--- /tmp/engine.log'; tail -n 60 /tmp/engine.log 2>/dev/null; echo '--- automation.log'; tail -n 40 /var/www/app/servers/$WORLD/include/automation.log 2>/dev/null || true" ;;
        *) die "engine: use start|stop|restart|status|logs" ;;
    esac
}

# =================================================================== main =====
case "$COMMAND" in
    install)         do_install ;;
    install-world)   do_install_world ;;
    set-port|port)   do_set_port ;;
    bots|bots-add)   do_bots ;;
    passwd|password) do_passwd ;;
    doctor|diag)     do_doctor ;;
    up)              load_env_file; check_docker; compose up -d ;;
    down)            load_env_file; check_docker; compose down ;;
    restart)         load_env_file; check_docker; compose restart ;;
    logs)            load_env_file; check_docker; if [ -n "${POSITIONAL[0]:-}" ]; then compose logs -f --tail=200 "${POSITIONAL[0]}"; else compose logs -f --tail=200; fi ;;
    status|ps)       load_env_file; check_docker; compose ps ;;
    config)          load_env_file; check_docker; compose config ;;
    creds)           load_env_file; print_creds ;;
    shell)           load_env_file; check_docker; if [ -n "${POSITIONAL[0]:-}" ]; then compose exec "${POSITIONAL[0]}" bash; else compose exec web bash; fi ;;
    db)              load_env_file; check_docker; compose exec db mysql -uroot -p"$DB_ROOT_PASS" ;;
    engine)          do_engine ;;
    reset|uninstall) do_reset ;;
    help)            usage ;;
    *)               die "unknown command: $COMMAND (try --help)" ;;
esac
