# php2shell — CVE-2026-109618 / CVE-2026-109619

Two critical vulnerabilities in the PHP engine itself, published 2026-10-21
(CVSS v4.0 **9.2**, unauthenticated remote code execution). The public exploit
that chains them is called **php2shell**.

| CVE | Bug | Fixed in |
| --- | --- | --- |
| CVE-2026-109618 | RCE via OOM corruption — a fatal out-of-memory aborts PHP mid-request and leaves partially initialised request data behind, which request cleanup then treats as valid | 8.2.35, 8.3.36, 8.4.27, 8.5.12 |
| CVE-2026-109619 | RCE via stale global state — request-owned internal state survives after its memory is freed; the next request on the same worker can use it before it is re-initialised | same |

Every PHP release going back to 5.4 is affected by at least one of them. They
are reachable through a multipart request that stays under `post_max_size` while
still forcing large allocations (nested `files[...]` parts, `filename=""` parts
that PHP does not count against `max_file_uploads`), plus `session.upload_progress`
initialising a session *before* modules are activated.

## Why this project needed a port

`composer.json` pins `php >=7.3 <8.0`, and `Core\ErrorHandler` turns every
warning into a thrown `ErrorException` in CLI, so the installer only completes
on 7.3. The Docker image was `php:7.3-apache` → **PHP 7.3.33, vulnerable**.

7.3 reached end of life in December 2021: there is no fixed image to pull, and
the PHP project published source backports for 7.4, 8.0 and 8.1 only.

## What the patch does

`deploy/php-7.3-cve-2026-109618-109619.patch` is the official
`PHP-7.4-CVE-2026-109618-109619` fix ported onto 7.3.33: 15 files, ~250 lines.
150 of the 224 lines the upstream backport adds are present verbatim; the rest
are the same change written against 7.3's surrounding code.

Regenerate / re-check the port:

```bash
curl -LO https://museum.php.net/php7/php-7.3.33.tar.gz
tar -xzf php-7.3.33.tar.gz
cp -a php-7.3.33 pristine && cp -a php-7.3.33 patched

python3 deploy/build-patch.py patched            # edits the tree, asserting every anchor
python3 deploy/verify-patch.py pristine patched  # structural checks (see below)

git init patched && git -C patched apply --check <(diff -ruN ...)   # or just:
diff -ruN pristine patched > /tmp/new.patch
```

`deploy/build-patch.py` asserts the hit count of every edit, so a missed anchor
aborts instead of producing a half-patched interpreter. `deploy/verify-patch.py`
then checks the result without a compiler: exactly the intended 15 files differ,
no delimiter count changed (a truncated hunk shows up here), and each hunk's
invariant holds (reporter defined before use, `body_parts_limit` set before the
first decrement, the ini entry registered, the callback disabled, …).

The shape of the fix: **stop longjmp()-ing out of a failed allocation.**

| File | Change |
| --- | --- |
| `Zend/zend_alloc.c`, `zend_alloc.h` | new `zend_mm_safe_error_ex()` reports and `_exit(1)`s; `zend_mm_safe_error()` and every "possible integer overflow" path route through it instead of `zend_error_noreturn(E_ERROR)` + `zend_bailout()` |
| `Zend/zend_hash.c`, `zend_hash.h`, `zend_API.h` | `zend_new_array_singleton()` / `array_init_singleton()` — GPC roots no longer reserve a full 8-bucket table per nested key, so a small body cannot force a large allocation |
| `Zend/zend_types.h` | `HT_HASH_RESET` handles a one-bucket table (SSE path would overrun) |
| `main/rfc1867.c` | new `max_multipart_body_parts` limit; only `Content-Disposition`/`Content-Type` headers are kept, duplicates dropped; `substring_conf()` takes `size_t` |
| `ext/session/session.c` | the upload-progress callback is disabled outright (it is the pre-init session window the chains use; this game has no upload form) |
| `main/main.c` | superglobals are undefined after destruction; `PG(modules_activated)` reset at the end of request shutdown |
| `main/SAPI.c` | freed request fields set to `NULL` |
| `Zend/zend_execute_API.c` | error/exception handlers and the object store are reset in `shutdown_executor()`, including the fast-shutdown path |
| `Zend/zend_llist.c`, `zend_multiply.h`, `zend_strtod.c` | the remaining fatal-allocation call sites terminate instead of unwinding |

Not ported: the 7.4 patch also adds `ZSTR_MAX_LEN` overflow guards to the
`CONCAT` VM handlers. 7.3 has no `ZSTR_MAX_LEN`, and the underlying allocation
failure now terminates the worker, so that guard has nothing left to protect.

## What the deployment does

`deploy-travium-docker.sh` now, by default:

1. copies the patch next to the generated `Dockerfile`;
2. builds PHP 7.3.33 from the museum.php.net tarball, **verifying its sha256**
   (`9a369c32c6f52036b0a890f290327f148a1904ee66aa56e2c9a7546da6525ec8` — the
   value php.net publishes);
3. applies the patch with `patch --dry-run` first, then for real, then greps for
   four marker strings, so a skipped hunk fails the build;
4. configures with `--enable-option-checking=fatal` (a typo cannot silently drop
   an extension), `make install`s over the stock tree, and re-installs mysqli,
   pdo_mysql, gd, zip, mbstring, pcntl, opcache and redis against the new engine;
5. verifies the **running** binary: `php -v` says 7.3.33 and
   `ini_get("max_multipart_body_parts")` is not `false`.

On top of the engine patch, `php-hardening.ini` and the generated vhost apply
the vendor's temporary mitigations and the request-shape limits:

```ini
session.upload_progress.enabled = 0   ; the pre-init window
max_multipart_body_parts = 64         ; bound the part count
file_uploads = Off                    ; the game has no upload form
post_max_size = 16M                   ; bound the body
display_errors = Off                  ; no diagnostics before init
memory_limit = 512M                   ; finite: a container limit is the backstop
```

```apache
LimitRequestBody 16777216
RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500
TraceEnable Off
```

`memory_limit` stays finite on purpose. The vendor's mitigation is
`memory_limit=-1` (remove the controllable OOM), which is the right trade only
when you cannot patch: with a terminating OOM the failure is a killed worker, and
an unbounded heap is then the bigger risk.

## Verifying

```bash
./deploy-travium-docker.sh doctor          # includes a php2shell section
docker compose exec web php -v             # PHP 7.3.33
docker compose exec web php -i | grep max_multipart_body_parts
docker compose exec web php -m | grep -E 'redis|mysqli|gd|Zend OPcache'
```

`doctor` reports whether the *running* container is patched, not just whether
the files on disk would produce a patched image.

## What this does NOT fix

- **PHP 7.3.33 is from November 2021.** This patch closes these two CVEs. It
  does not include the fixes that landed in 7.3.34+ (`phar`, `filter`, `zlib`,
  and others) or anything found after 7.3 went EOL. Treat 7.3 as a legacy
  runtime.
- **The real fix is upgrading PHP.** The blocker is the application, not the
  deployment: `composer.json` pins `<8.0`, `Core\ErrorHandler` throws on notices
  in CLI, and 5 files do not parse on modern PHP at all
  (`Core/Village.php` uses the removed `a ? b : c ? d : e` nesting;
  `Plugins/securimage/*` use `$str{0}` string offsets). That migration is its own
  project.
- `--no-php-patch` builds the stock, vulnerable image. It exists for hosts where
  the source build fails. The ini/vhost mitigations still apply, but the PHP
  advisory is explicit that they are not a complete fix — the build prints a
  warning and `doctor` reports it.
