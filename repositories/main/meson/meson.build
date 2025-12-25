#!/bin/sh

package_name="meson"
package_version="1.8.3"
package_description="an open source build system designed to be both extremely fast and as user friendly as possible"
package_source="https://github.com/mesonbuild/meson/releases/download/1.8.3/meson-1.8.3.tar.gz 08221d2f515e759686f666ff6409a903"

build_deps="python3"

source_dir="$package_name-$package_version"

configure() {
    cd "$source_dir" || log_error "In $package_name.build: Failed to cd to $source_dir"
    :
}

build() {
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
}

install_files() {
    pip3 install --no-index --find-links dist --root "$DESTDIR" meson
    command install -vDm644 data/shell-completions/bash/meson "$DESTDIR/usr/share/bash-completion/completions/meson"
    command install -vDm644 data/shell-completions/zsh/_meson "$DESTDIR/usr/share/zsh/site-functions/_meson"
}
