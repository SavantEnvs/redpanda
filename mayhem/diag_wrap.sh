#!/bin/bash
/mayhem/acl_store_fuzz "$@"
rc=$?
echo "[diag] wrapper saw child status=$rc" >&2
exit $rc
