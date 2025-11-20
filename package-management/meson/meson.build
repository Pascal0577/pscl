#!/bin/sh

package_name="meson"
package_version="1.8.3"
package_description="an open source build system designed to be both extremely fast and as user friendly as possible"
package_source="https://github.com/mesonbuild/meson/releases/download/1.8.3/meson-1.8.3.tar.gz"

source_dir="$package_name-$package_version"

configure() {
    :
}

build() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
}

install_files() {
    pip3 install --no-index --find-links dist --root "$destdir" meson
    command install -vDm644 data/shell-completions/bash/meson "$destdir/usr/share/bash-completion/completions/meson"
    command install -vDm644 data/shell-completions/zsh/_meson "$destdir/usr/share/zsh/site-functions/_meson"
}
