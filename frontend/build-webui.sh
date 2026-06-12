#!/usr/bin/env bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"
. ./setup-nodejs-env.sh
install_nodejs
package_version=$(tr -d '\n' < ../packaging/VERSION)
last_commit=$( (git log -1 2>/dev/null || echo dev) | head -1 | sed s/commit\ //)
echo "export const BUILD_VERSION = \"github-$package_version-$last_commit\";" > src/operator/webui/src/environments/version.ts
intl_segmenter_fallback="$PWD/node-intl-segmenter-fallback.cjs"
(cd src/operator/webui/ && npm install && NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$intl_segmenter_fallback" ./node_modules/.bin/ng build)
ok=$?
uninstall_nodejs
exit $ok
