"""Structural checks on the php2shell backport.

There is no C compiler in this environment, so instead of building PHP we verify
the properties that matter and that a reviewer can check by eye:

  * the patched tree differs from pristine 7.3.33 in exactly the intended files;
  * every delimiter count is unchanged by the patch (the fix adds balanced
    constructs, so a delta means a truncated hunk);
  * the specific invariants each hunk is supposed to establish.

Usage: verify.py <pristine-dir> <patched-dir>
"""
import io
import re
import sys

pristine, patched = sys.argv[1], sys.argv[2]

EXPECTED = {
    "Zend/zend_API.h", "Zend/zend_alloc.c", "Zend/zend_alloc.h",
    "Zend/zend_execute_API.c", "Zend/zend_hash.c", "Zend/zend_hash.h",
    "Zend/zend_llist.c", "Zend/zend_multiply.h", "Zend/zend_strtod.c",
    "Zend/zend_types.h", "ext/session/session.c", "main/SAPI.c",
    "main/main.c", "main/php_variables.c", "main/rfc1867.c",
}

ok = True


def note(good, msg):
    global ok
    print(("ok   " if good else "FAIL ") + msg)
    ok = ok and good


def strip(src):
    """Remove comments and literals so delimiter counting is meaningful."""
    s = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    s = re.sub(r'//[^\n]*', ' ', s)
    s = re.sub(r'"(\\.|[^"\\\n])*"', '""', s)
    s = re.sub(r"'(\\.|[^'\\\n])*'", "''", s)
    s = re.sub(r'^[ \t]*#.*$', ' ', s, flags=re.M)
    return s


print("== files touched ==")
import os
changed = set()
for rel in sorted(EXPECTED):
    a = io.open(os.path.join(pristine, rel), encoding="utf-8", errors="replace").read()
    b = io.open(os.path.join(patched, rel), encoding="utf-8", errors="replace").read()
    if a != b:
        changed.add(rel)
note(changed == EXPECTED, "exactly the %d intended files differ (got %d)" % (len(EXPECTED), len(changed)))
for miss in sorted(EXPECTED - changed):
    print("     unchanged: " + miss)

print()
print("== delimiter deltas (patched vs pristine) ==")
for rel in sorted(EXPECTED):
    a = strip(io.open(os.path.join(pristine, rel), encoding="utf-8", errors="replace").read())
    b = strip(io.open(os.path.join(patched, rel), encoding="utf-8", errors="replace").read())
    db = b.count("{") - b.count("}") - (a.count("{") - a.count("}"))
    dp = b.count("(") - b.count(")") - (a.count("(") - a.count(")"))
    note(db == 0 and dp == 0, "%-28s brace delta %+d, paren delta %+d" % (rel, db, dp))

print()
print("== invariants ==")
alloc = io.open(os.path.join(patched, "Zend/zend_alloc.c"), encoding="utf-8").read()
alloc_h = io.open(os.path.join(patched, "Zend/zend_alloc.h"), encoding="utf-8").read()
hashc = io.open(os.path.join(patched, "Zend/zend_hash.c"), encoding="utf-8").read()
hashh = io.open(os.path.join(patched, "Zend/zend_hash.h"), encoding="utf-8").read()
rfc = io.open(os.path.join(patched, "main/rfc1867.c"), encoding="utf-8").read()
ex = io.open(os.path.join(patched, "Zend/zend_execute_API.c"), encoding="utf-8").read()
sess = io.open(os.path.join(patched, "ext/session/session.c"), encoding="utf-8").read()
mainc = io.open(os.path.join(patched, "main/main.c"), encoding="utf-8").read()
sapi = io.open(os.path.join(patched, "main/SAPI.c"), encoding="utf-8").read()

note(alloc.count("void zend_mm_safe_error_ex(const char *format, ...)") == 1,
     "zend_alloc.c defines zend_mm_safe_error_ex exactly once")
note("zend_mm_safe_error_ex(const char *format, ...);" in alloc_h,
     "zend_alloc.h declares it")
note(alloc.index("void zend_mm_safe_error_ex(const char *format, ...)") <
     alloc.index("zend_mm_safe_error_ex(format, limit,"),
     "the reporter is defined before zend_mm_safe_error uses it")
note('zend_error_noreturn(E_ERROR, "Possible integer overflow' not in alloc,
     "no E_ERROR/longjmp path left for allocation overflow in zend_alloc.c")
note(re.search(r'(?<!_)exit\(1\);', alloc) is None,
     "the OOM paths use _exit(), not exit()")
note("heap->overflow = 1;" not in alloc,
     "zend_mm_safe_error no longer flips heap->overflow / zend_bailout()")

note("zend_new_array_singleton" in hashc and "zend_new_array_singleton" in hashh,
     "zend_new_array_singleton defined and declared")
note("array_init_singleton" in io.open(os.path.join(patched, "Zend/zend_API.h"), encoding="utf-8").read(),
     "array_init_singleton macro present")
note("UNEXPECTED(size < 64)" in io.open(os.path.join(patched, "Zend/zend_types.h"), encoding="utf-8").read(),
     "HT_HASH_RESET guards the small-table case")

note(rfc.index("static char *php_mime_get_hdr_value(zend_llist header, char *key);") <
     rfc.index("php_mime_get_hdr_value(*header, line)"),
     "rfc1867.c declares php_mime_get_hdr_value before using it")
note(rfc.index("body_parts_limit = body_parts_cnt;") < rfc.index("--body_parts_cnt < 0"),
     "body_parts_limit is set before the first decrement")
note("max_multipart_body_parts" in mainc,
     "max_multipart_body_parts is registered as an ini entry")
note("rfc1867_enabled) || true" in sess,
     "the session upload-progress callback is disabled")
note("EH_NORMAL" in ex and "objects_store).object_buckets = NULL" in ex,
     "shutdown_executor resets the stale executor state")
note("ZVAL_UNDEF(&PG(http_globals)[i]);" in mainc and "PG(modules_activated) = 0;" in mainc,
     "request shutdown undefines the superglobals and clears modules_activated")
note(sapi.count("SG(request_info).auth_user = NULL;") == 1,
     "SAPI request fields are nulled after free")

print()
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
