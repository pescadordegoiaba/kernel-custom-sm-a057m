#!/usr/bin/env bash
# Wrapper legado — o script repacka vendor_boot E vendor_dlkm.
echo "Nota: use scripts/deploy_kernel_modules.sh (este wrapper será removido no futuro)." >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy_kernel_modules.sh" "$@"