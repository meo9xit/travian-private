# Travium — Travian T4.5 Private Server

[![Status](https://img.shields.io/badge/status-production-green)](https://travium.net/)
[![OS](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-blue)](#supported-os)
[![OS](https://img.shields.io/badge/Debian-11%20%7C%2012%20%7C%2013-blue)](#supported-os)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](#license)
[![Discord](https://img.shields.io/badge/chat-Discord-5865F2)](https://discord.gg/TCjyvcctDg)

A fast, stable Travian T4.5 clone with a one-click installer in a single command.

Join our discord:
**Discord:** [https://discord.gg/TCjyvcctDg](https://discord.gg/TCjyvcctDg)

## Features

* 1-click automated install and configuration
* Works on fresh VMs/VPS, no prior setup required
* Opinionated, production-ready defaults
* CloudPanel integration for easy management and faster loading times
* Installer command generator: [https://init.travium.net/](https://init.travium.net/)

---

## Quick start

1. **Prepare a clean server**

   * Pick a supported OS (below), log in as `root`.
2. **Point DNS or hosts**

   * Set A records to your server IP (examples below).
3. **Run the installer**

   ```bash
   bash <(curl -skL https://init.travium.net/install.sh) \
       --domain example.com
   ```
4. **Finish setup**

   * Open the CloudPanel link shown at the end of the install.
   * Create a database.
   * Open the installer URL, fill details, click **Run Installer**.

> Prefer a prefilled command? Use the generator: [https://init.travium.net/](https://init.travium.net/)

---

## Supported OS

* 🐧 Ubuntu 24.04 LTS
* 🐧 Ubuntu 22.04 LTS
* 🐧 Debian 13 LTS
* 🐧 Debian 12 LTS
* 🐧 Debian 11 LTS

> Important: Use a fresh machine.

---

## Requirements

* Clean VM/VPS with a supported OS
* Root access
* A domain you control
* Basic ability to copy-paste a command

---

## DNS / hosts setup

Point everything to your server IP. Replace `12.13.14.15` and `example.com`.

```
12.13.14.15 example.com www.example.com
12.13.14.15 server1.example.com server2.example.com     # add more game worlds as needed
12.13.14.15 api.example.com
12.13.14.15 cdn.example.com
12.13.14.15 install.example.com
12.13.14.15 voting.example.com
12.13.14.15 payment.example.com
```

If you’re just testing, you can use your local hosts file with the same lines.

---

## What the installer gives you

* CloudPanel ready to use
* Web vhosts, PHP, DB engine, and core services configured
* Game server scaffolding and routes
* Secure defaults and sensible limits

At the end you’ll see:

* **CloudPanel URL** and credentials
* **Installer URL** to finalize the game configuration

---

## Post-install checklist

1. Log in to **CloudPanel**
   Create a database:
   [https://www.cloudpanel.io/docs/v2/frontend-area/databases/](https://www.cloudpanel.io/docs/v2/frontend-area/databases/)

2. Visit the **Installer URL**
   Fill the form with your DB details, and any options you want.
   Click **Run Installer** and let it finish.

3. Open your domain and confirm the game is live.

---

## Security

### php2shell — CVE-2026-109618 / CVE-2026-109619 (fixed)

Two critical PHP engine vulnerabilities (unauthenticated RCE, CVSS 9.2,
published 21 October 2026). Every PHP release back to 5.4 is affected, so the
PHP 7.3 this game is pinned to is affected too, and 7.3 is end-of-life with no
fixed image to pull.

The Docker image is therefore **rebuilt from source with the fix compiled in**:
`deploy/php-7.3-cve-2026-109618-109619.patch` ports PHP's own 7.4 backport onto
7.3.33, and the build verifies the tarball sha256, the patch application and the
resulting binary. On top of that, `php-hardening.ini` and the generated Apache
vhost switch off the request shapes the exploit needs (upload progress,
multipart uploads, unbounded parts, oversized bodies).

Check what a running container actually has:

```bash
./deploy-travium-docker.sh doctor
docker compose exec web php -i | grep max_multipart_body_parts
```

Details, the full change list and the residual risk (7.3 is still a legacy
runtime — the real fix is moving to PHP 8): [docs/php2shell.md](docs/php2shell.md).

`--no-php-patch` falls back to the stock, vulnerable image for hosts where the
source build fails. The mitigations still apply, but they are not a complete fix.

---

## Contributing

* Fork, branch, commit
* Keep PRs focused and tested

---

## Credits

Core authors and contributors will be listed here.
If you shipped a fix or feature, you’ll get your shout-out.

---

## License

MIT
