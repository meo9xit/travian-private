#!/usr/bin/env python3
"""Regenerate php-7.3-cve-2026-109618-109619.patch from a pristine PHP 7.3.33 tree.

The PHP security team published source backports for 7.4, 8.0 and 8.1 but not
for 7.3 (EOL). This script applies the same fix - taken from the official
PHP-7.4-CVE-2026-109618-109619 commit - to 7.3.33, adapted to the places where
7.3 differs (shutdown_executor layout, no ZSTR_MAX_LEN / VM concat guards,
php_mime_get_hdr_value declared after its first use, int vs uint32_t line
numbers).

Usage:
    curl -LO https://museum.php.net/php7/php-7.3.33.tar.gz
    tar -xzf php-7.3.33.tar.gz
    python3 deploy/build-patch.py php-7.3.33        # edits the tree in place

The result is already committed as
deploy/php-7.3-cve-2026-109618-109619.patch; this script exists so the port can
be re-derived and reviewed. Every edit asserts its hit count, so a missed anchor
aborts instead of producing a half-patched interpreter.
"""
import io
import re
import sys

ROOT = sys.argv[1]
FAILS = []


def read(p):
    with io.open(ROOT + "/" + p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(p, s):
    with io.open(ROOT + "/" + p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def sub(path, old, new, count=1):
    """Literal replace with an exact expected hit count."""
    src = read(path)
    n = src.count(old)
    if n != count:
        FAILS.append("%s: wanted %d hit(s), got %d :: %r" % (path, count, n, old[:60]))
        return
    write(path, src.replace(old, new))
    print("  ok  %-26s %d" % (path, n))


def resub(path, pattern, repl, count=1):
    src = read(path)
    new, n = re.subn(pattern, repl, src, flags=re.M)
    if n != count:
        FAILS.append("%s: wanted %d regex hit(s), got %d :: %r" % (path, count, n, pattern[:60]))
        return
    write(path, new)
    print("  ok  %-26s %d" % (path, n))


# =========================================================== Zend/zend_alloc.h
sub("Zend/zend_alloc.h",
    "\nEND_EXTERN_C()\n",
    "\nZEND_API ZEND_COLD ZEND_NORETURN void zend_mm_safe_error_ex(const char *format, ...);\n\nEND_EXTERN_C()\n")

# =========================================================== Zend/zend_alloc.c
sub("Zend/zend_alloc.c",
    '#include "zend_bitset.h"\n',
    '#include "zend_bitset.h"\n#include "zend_compile.h"\n#include "zend_execute.h"\n')

# OOM must kill the process. The old code raised E_ERROR and longjmp()ed back
# into PHP, which is exactly the "abort handling and leave request state
# half-initialised" primitive the CVE abuses.
sub("Zend/zend_alloc.c",
    'static ZEND_COLD ZEND_NORETURN void zend_mm_panic(const char *message)\n'
    '{\n'
    '\tfprintf(stderr, "%s\\n", message);\n'
    '/* See http://support.microsoft.com/kb/190351 */\n'
    '#ifdef ZEND_WIN32\n'
    '\tfflush(stderr);\n'
    '#endif\n'
    '#if ZEND_DEBUG && defined(HAVE_KILL) && defined(HAVE_GETPID)\n'
    '\tkill(getpid(), SIGSEGV);\n'
    '#endif\n'
    '\texit(1);\n'
    '}\n',
    'static ZEND_COLD ZEND_NORETURN void zend_mm_panic(const char *message)\n'
    '{\n'
    '\tfprintf(stderr, "%s\\n", message);\n'
    '/* See http://support.microsoft.com/kb/190351 */\n'
    '#ifdef ZEND_WIN32\n'
    '\tfflush(stderr);\n'
    '#endif\n'
    '#if ZEND_DEBUG && defined(HAVE_KILL) && defined(HAVE_GETPID)\n'
    '\tkill(getpid(), SIGSEGV);\n'
    '#endif\n'
    '\t_exit(1);\n'
    '}\n'
    '\n'
    '/* Report an unrecoverable allocation failure and terminate. Never returns\n'
    ' * into PHP: a longjmp() out of an allocation leaves whatever the caller was\n'
    ' * building half-initialised, which is the state CVE-2026-109618 corrupts. */\n'
    'ZEND_API ZEND_COLD ZEND_NORETURN void zend_mm_safe_error_ex(const char *format, ...)\n'
    '{\n'
    '\tzend_string *script_filename = NULL;\n'
    '\tuint32_t script_lineno = 0;\n'
    '\n'
    '\tif (zend_is_executing()) {\n'
    '\t\tscript_filename = zend_get_executed_filename_ex();\n'
    '\t\tscript_lineno = zend_get_executed_lineno();\n'
    '\t} else if (zend_is_compiling()) {\n'
    '\t\tscript_filename = zend_get_compiled_filename();\n'
    '\t\tscript_lineno = (uint32_t) zend_get_compiled_lineno();\n'
    '\t}\n'
    '\n'
    '\tva_list args;\n'
    '\tva_start(args, format);\n'
    '\n'
    '\tchar buf[1024];\n'
    '\tvsnprintf(buf, sizeof(buf), format, args);\n'
    '\n'
    '\tva_end(args);\n'
    '\n'
    '\tfprintf(stderr,\n'
    '\t\t\t"\\nFatal error: %s in %s on line %d\\n",\n'
    '\t\t\tbuf,\n'
    '\t\t\tscript_filename ? ZSTR_VAL(script_filename) : "Unknown",\n'
    '\t\t\tscript_lineno);\n'
    '\n'
    '\t/* See http://support.microsoft.com/kb/190351 */\n'
    '# ifdef ZEND_WIN32\n'
    '\tfflush(stderr);\n'
    '# endif\n'
    '\n'
    '\t_exit(1);\n'
    '}\n')

# The memory_limit handler now funnels into the terminating reporter.
sub("Zend/zend_alloc.c",
    '{\n'
    '\n'
    '\theap->overflow = 1;\n'
    '\tzend_try {\n'
    '\t\tzend_error_noreturn(E_ERROR,\n'
    '\t\t\tformat,\n'
    '\t\t\tlimit,\n'
    '#if ZEND_DEBUG\n'
    '\t\t\tfilename,\n'
    '\t\t\tlineno,\n'
    '#endif\n'
    '\t\t\tsize);\n'
    '\t} zend_catch {\n'
    '\t}  zend_end_try();\n'
    '\theap->overflow = 0;\n'
    '\tzend_bailout();\n'
    '\texit(1);\n'
    '}\n',
    '{\n'
    '\t(void) heap;\n'
    '\n'
    '\tzend_mm_safe_error_ex(format, limit,\n'
    '#if ZEND_DEBUG\n'
    '\t\tfilename,\n'
    '\t\tlineno,\n'
    '#endif\n'
    '\t\tsize);\n'
    '}\n')

resub("Zend/zend_alloc.c",
      r'zend_error_noreturn\(E_ERROR, "Possible integer overflow in memory allocation',
      'zend_mm_safe_error_ex("Possible integer overflow in memory allocation', count=5)

sub("Zend/zend_alloc.c",
    '\tfprintf(stderr, "Out of memory\\n");\n\texit(1);\n',
    '\tfprintf(stderr, "Out of memory\\n");\n\t_exit(1);\n')

# =========================================================== Zend/zend_hash.c
resub("Zend/zend_hash.c",
      r'zend_error_noreturn\(E_ERROR, "Possible integer overflow in memory allocation',
      'zend_mm_safe_error_ex("Possible integer overflow in memory allocation', count=3)

sub("Zend/zend_hash.c",
    'ZEND_API HashTable* ZEND_FASTCALL _zend_new_array_0(void)\n'
    '{\n'
    '\tHashTable *ht = emalloc(sizeof(HashTable));\n'
    '\t_zend_hash_init_int(ht, HT_MIN_SIZE, ZVAL_PTR_DTOR, 0);\n'
    '\treturn ht;\n'
    '}\n',
    'ZEND_API HashTable* ZEND_FASTCALL _zend_new_array_0(void)\n'
    '{\n'
    '\tHashTable *ht = emalloc(sizeof(HashTable));\n'
    '\t_zend_hash_init_int(ht, HT_MIN_SIZE, ZVAL_PTR_DTOR, 0);\n'
    '\treturn ht;\n'
    '}\n'
    '\n'
    '/* An array that is known to hold a single element: $_POST/$_GET/$_COOKIE\n'
    ' * roots are created before the request data is known, so allocating the\n'
    ' * default 8-bucket table for every nested key lets a small multipart body\n'
    ' * reserve a huge amount of memory and reach memory_limit at will. */\n'
    'ZEND_API HashTable* ZEND_FASTCALL zend_new_array_singleton(void)\n'
    '{\n'
    '\tHashTable *ht = _zend_new_array_0();\n'
    '\tht->nTableSize = 1;\n'
    '\treturn ht;\n'
    '}\n')

# =========================================================== Zend/zend_hash.h
sub("Zend/zend_hash.h",
    "ZEND_API HashTable* ZEND_FASTCALL _zend_new_array_0(void);\n",
    "ZEND_API HashTable* ZEND_FASTCALL _zend_new_array_0(void);\n"
    "ZEND_API HashTable* ZEND_FASTCALL zend_new_array_singleton(void);\n")

# =========================================================== Zend/zend_API.h
sub("Zend/zend_API.h",
    "#define array_init_size(arg, size)\tZVAL_ARR((arg), zend_new_array(size))\n",
    "#define array_init_size(arg, size)\tZVAL_ARR((arg), zend_new_array(size))\n"
    "#define array_init_singleton(arg)\tZVAL_ARR((arg), zend_new_array_singleton())\n")

# =========================================================== Zend/zend_multiply.h
resub("Zend/zend_multiply.h",
      r'zend_error_noreturn\(E_ERROR, "Possible integer overflow in memory allocation',
      'zend_mm_safe_error_ex("Possible integer overflow in memory allocation', count=1)
resub("Zend/zend_multiply.h",
      r'zend_error_noreturn\(E_ERROR, "Possible integer overflow in %s',
      'zend_mm_safe_error_ex("Possible integer overflow in %s', count=1)

# =========================================================== Zend/zend_strtod.c
resub("Zend/zend_strtod.c",
      r'zend_error_noreturn\(E_ERROR, "Balloc\(\) failed to allocate memory"\);',
      'zend_mm_safe_error_ex("Balloc() failed to allocate memory");', count=2)

# =========================================================== Zend/zend_types.h
sub("Zend/zend_types.h",
    '# define HT_HASH_RESET(ht) do { \\\n'
    '\t\tchar *p = (char*)&HT_HASH(ht, (ht)->nTableMask); \\\n'
    '\t\tsize_t size = HT_HASH_SIZE((ht)->nTableMask); \\\n'
    '\t\t__m128i xmm0 = _mm_setzero_si128(); \\\n'
    '\t\txmm0 = _mm_cmpeq_epi8(xmm0, xmm0); \\\n'
    '\t\tZEND_ASSERT(size >= 64 && ((size & 0x3f) == 0)); \\\n'
    '\t\tdo { \\\n'
    '\t\t\t_mm_storeu_si128((__m128i*)p, xmm0); \\\n'
    '\t\t\t_mm_storeu_si128((__m128i*)(p+16), xmm0); \\\n'
    '\t\t\t_mm_storeu_si128((__m128i*)(p+32), xmm0); \\\n'
    '\t\t\t_mm_storeu_si128((__m128i*)(p+48), xmm0); \\\n'
    '\t\t\tp += 64; \\\n'
    '\t\t\tsize -= 64; \\\n'
    '\t\t} while (size != 0); \\\n'
    '\t} while (0)\n',
    '# define HT_HASH_RESET(ht) do { \\\n'
    '\t\tchar *p = (char*)&HT_HASH(ht, (ht)->nTableMask); \\\n'
    '\t\tsize_t size = HT_HASH_SIZE((ht)->nTableMask); \\\n'
    '\t\t/* A one-element table has a hash area smaller than one SSE store;\n'
    '\t\t * memset() it instead of running off the end of the allocation. */ \\\n'
    '\t\tif (UNEXPECTED(size < 64)) { \\\n'
    '\t\t\tmemset(p, HT_INVALID_IDX, size); \\\n'
    '\t\t} else { \\\n'
    '\t\t\t__m128i xmm0 = _mm_setzero_si128(); \\\n'
    '\t\t\txmm0 = _mm_cmpeq_epi8(xmm0, xmm0); \\\n'
    '\t\t\tZEND_ASSERT(size >= 64 && ((size & 0x3f) == 0)); \\\n'
    '\t\t\tdo { \\\n'
    '\t\t\t\t_mm_storeu_si128((__m128i*)p, xmm0); \\\n'
    '\t\t\t\t_mm_storeu_si128((__m128i*)(p+16), xmm0); \\\n'
    '\t\t\t\t_mm_storeu_si128((__m128i*)(p+32), xmm0); \\\n'
    '\t\t\t\t_mm_storeu_si128((__m128i*)(p+48), xmm0); \\\n'
    '\t\t\t\tp += 64; \\\n'
    '\t\t\t\tsize -= 64; \\\n'
    '\t\t\t} while (size != 0); \\\n'
    '\t\t} \\\n'
    '\t} while (0)\n')

# =========================================================== Zend/zend_llist.c
sub("Zend/zend_llist.c",
    '\t\tcurrent = next;\n'
    '\t}\n'
    '\n'
    '\tl->count = 0;\n'
    '}\n',
    '\t\tcurrent = next;\n'
    '\t}\n'
    '\n'
    '\tl->head  = NULL;\n'
    '\tl->tail  = NULL;\n'
    '\tl->count = 0;\n'
    '}\n')

# =========================================================== Zend/zend_execute_API.c
sub("Zend/zend_execute_API.c",
    '\tzend_objects_store_free_object_storage(&EG(objects_store), fast_shutdown);\n',
    '\t/* A request that fataled before init_executor() leaves these pointing into\n'
    '\t * the previous request\'s heap. zend_error() can reach them while a later\n'
    '\t * request is still parsing its body (CVE-2026-109619). */\n'
    '\tif (!EG(objects_store).object_buckets) {\n'
    '\t\tZVAL_UNDEF(&EG(user_error_handler));\n'
    '\t\tZVAL_UNDEF(&EG(user_exception_handler));\n'
    '\t\tmemset(&EG(user_error_handlers_error_reporting), 0, sizeof(EG(user_error_handlers_error_reporting)));\n'
    '\t\tmemset(&EG(user_error_handlers), 0, sizeof(EG(user_error_handlers)));\n'
    '\t\tmemset(&EG(user_exception_handlers), 0, sizeof(EG(user_exception_handlers)));\n'
    '\t}\n'
    '\n'
    '\tzend_objects_store_free_object_storage(&EG(objects_store), fast_shutdown);\n'
    '\n'
    '\t/* These may be used by zend_error() before init_executor() */\n'
    '\tEG(error_handling) = EH_NORMAL;\n'
    '\tEG(exception) = NULL;\n')

sub("Zend/zend_execute_API.c",
    '\t\tzend_hash_discard(EG(zend_constants), EG(persistent_constants_count));\n'
    '\t\tzend_hash_discard(EG(function_table), EG(persistent_functions_count));\n'
    '\t\tzend_hash_discard(EG(class_table), EG(persistent_classes_count));\n'
    '\t\tzend_cleanup_internal_classes();\n',
    '\t\tzend_hash_discard(EG(zend_constants), EG(persistent_constants_count));\n'
    '\t\tzend_hash_discard(EG(function_table), EG(persistent_functions_count));\n'
    '\t\tzend_hash_discard(EG(class_table), EG(persistent_classes_count));\n'
    '\t\tzend_cleanup_internal_classes();\n'
    '\t\t/* Mark the store as torn down so a later request can tell that the\n'
    '\t\t * executor was never re-initialised. */\n'
    '\t\tEG(objects_store).object_buckets = NULL;\n'
    '\t\tEG(objects_store).top = 1;\n')

# =========================================================== ext/session/session.c
sub("ext/session/session.c",
    '\tif (!PS(rfc1867_enabled)) {\n'
    '\t\treturn retval;\n'
    '\t}\n',
    '\t/* Session upload progress initialises the session while the request body\n'
    '\t * is still being parsed, i.e. before the module is activated. That early\n'
    '\t * window is the state the php2shell chains corrupt, and this game has no\n'
    '\t * upload form, so the callback is disabled outright - the same change the\n'
    '\t * vendor backport makes for 7.4. */\n'
    '\tif (!PS(rfc1867_enabled) || true) {\n'
    '\t\treturn retval;\n'
    '\t}\n')

# =========================================================== main/SAPI.c
for field in ("auth_user", "auth_password", "auth_digest", "content_type_dup", "current_user"):
    sub("main/SAPI.c",
        "\tif (SG(request_info).%s) {\n\t\tefree(SG(request_info).%s);\n\t}\n" % (field, field),
        "\tif (SG(request_info).%s) {\n\t\tefree(SG(request_info).%s);\n\t\tSG(request_info).%s = NULL;\n\t}\n"
        % (field, field, field))

# =========================================================== main/main.c
sub("main/main.c",
    '\tPHP_INI_ENTRY("max_file_uploads",\t\t\t"20",\t\t\tPHP_INI_SYSTEM|PHP_INI_PERDIR,\t\tNULL)\n',
    '\tPHP_INI_ENTRY("max_file_uploads",\t\t\t"20",\t\t\tPHP_INI_SYSTEM|PHP_INI_PERDIR,\t\tNULL)\n'
    '\tPHP_INI_ENTRY("max_multipart_body_parts",\t"-1",\t\t\tPHP_INI_SYSTEM|PHP_INI_PERDIR,\t\tNULL)\n')

sub("main/main.c",
    '\t\tfor (i=0; i<NUM_TRACK_VARS; i++) {\n'
    '\t\t\tzval_ptr_dtor(&PG(http_globals)[i]);\n'
    '\t\t}\n',
    '\t\tfor (i=0; i<NUM_TRACK_VARS; i++) {\n'
    '\t\t\tzval_ptr_dtor(&PG(http_globals)[i]);\n'
    '\t\t\t/* May be accessed before php_request_startup() */\n'
    '\t\t\tZVAL_UNDEF(&PG(http_globals)[i]);\n'
    '\t\t}\n')

sub("main/main.c",
    '#endif /* HAVE_DTRACE */\n'
    '}\n'
    '/* }}} */\n',
    '#endif /* HAVE_DTRACE */\n'
    '\n'
    '\t/* May be accessed before php_request_startup() */\n'
    '\tPG(modules_activated) = 0;\n'
    '}\n'
    '/* }}} */\n')

# =========================================================== main/php_variables.c
sub("main/php_variables.c", "\t\t\t\tarray_init(&gpc_element);", "\t\t\t\tarray_init_singleton(&gpc_element);")
sub("main/php_variables.c", "\t\t\t\t\tarray_init(&tmp);", "\t\t\t\t\tarray_init_singleton(&tmp);")
sub("main/php_variables.c", "\t\t\t\t\t\tarray_init(gpc_element_p);", "\t\t\t\t\t\tarray_init_singleton(gpc_element_p);")
sub("main/php_variables.c", "\t\t\tarray_init(&array);", "\t\t\tarray_init_singleton(&array);")

# =========================================================== main/rfc1867.c
# 1. only keep the two headers the parser actually reads, ignore duplicates
sub("main/rfc1867.c",
    '/* parse headers */\n'
    'static int multipart_buffer_headers(multipart_buffer *self, zend_llist *header)\n',
    'static zend_bool php_mime_should_save_hdr(const char *name)\n'
    '{\n'
    '\treturn !strcasecmp(name, "Content-Disposition")\n'
    '\t\t|| !strcasecmp(name, "Content-Type");\n'
    '}\n'
    '\n'
    'static char *php_mime_get_hdr_value(zend_llist header, char *key);\n'
    '\n'
    '/* parse headers */\n'
    'static int multipart_buffer_headers(multipart_buffer *self, zend_llist *header)\n')

sub("main/rfc1867.c",
    '\t\t\t*value = \'\\0\';\n'
    '\t\t\tdo { value++; } while (isspace(*value));\n'
    '\n'
    '\t\t\tkey = estrdup(line);\n'
    '\t\t\tsmart_string_appends(&buf_value, value);\n',
    '\t\t\t*value = \'\\0\';\n'
    '\n'
    '\t\t\t/* Keep only the headers we use, and ignore duplicates: every\n'
    '\t\t\t * stored header is a request-heap allocation an attacker would\n'
    '\t\t\t * otherwise control. */\n'
    '\t\t\tif (!php_mime_should_save_hdr(line)\n'
    '\t\t\t\t\t|| php_mime_get_hdr_value(*header, line)) {\n'
    '\t\t\t\tkey = NULL;\n'
    '\t\t\t} else {\n'
    '\t\t\t\tkey = estrdup(line);\n'
    '\t\t\t\tdo { value++; } while (isspace((unsigned char)*value));\n'
    '\t\t\t\tsmart_string_appends(&buf_value, value);\n'
    '\t\t\t}\n')

# 2. substring_conf takes a size_t length
sub("main/rfc1867.c",
    'static char *substring_conf(char *start, int len, char quote)\n'
    '{\n'
    '\tchar *result = emalloc(len + 1);\n'
    '\tchar *resp = result;\n'
    '\tint i;\n',
    'static char *substring_conf(char *start, size_t len, char quote)\n'
    '{\n'
    '\tchar *result = emalloc(len + 1);\n'
    '\tchar *resp = result;\n'
    '\tsize_t i;\n')

sub("main/rfc1867.c",
    '\t\treturn substring_conf(str, (int)strlen(str), quote);\n',
    '\t\treturn substring_conf(str, strlen(str), quote);\n')

# 3. cap the number of multipart body parts
sub("main/rfc1867.c",
    '\tint upload_cnt = INI_INT("max_file_uploads");\n',
    '\tint upload_cnt = INI_INT("max_file_uploads");\n'
    '\tint body_parts_cnt = INI_INT("max_multipart_body_parts");\n'
    '\tint body_parts_limit;\n')

sub("main/rfc1867.c",
    '\t/* Get the boundary */\n',
    '\t/* Unbounded multipart parts are how a request stays under post_max_size\n'
    '\t * while still forcing a large number of allocations. */\n'
    '\tif (body_parts_cnt < 0) {\n'
    '\t\tbody_parts_cnt = (int) PG(max_input_vars) + upload_cnt;\n'
    '\t}\n'
    '\tbody_parts_limit = body_parts_cnt;\n'
    '\n'
    '\t/* Get the boundary */\n')

sub("main/rfc1867.c",
    '\t\tif ((cd = php_mime_get_hdr_value(header, "Content-Disposition"))) {\n'
    '\t\t\tchar *pair = NULL;\n'
    '\t\t\tint end = 0;\n',
    '\t\tif ((cd = php_mime_get_hdr_value(header, "Content-Disposition"))) {\n'
    '\t\t\tchar *pair = NULL;\n'
    '\t\t\tint end = 0;\n'
    '\n'
    '\t\t\tif (--body_parts_cnt < 0) {\n'
    '\t\t\t\tphp_error_docref(NULL, E_WARNING, "Multipart body parts limit exceeded %d. To increase the limit change max_multipart_body_parts in php.ini.", body_parts_limit);\n'
    '\t\t\t\tgoto fileupload_done;\n'
    '\t\t\t}\n')

print()
if FAILS:
    print("FAILURES:")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print("all edits applied")
