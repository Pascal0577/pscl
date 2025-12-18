#!/bin/sh

readonly EXTENSION_DIR="${PKGDIR:?}/extensions/"

extension_parse_action() {
    INSTALL_EXTENSION=0
    UNINSTALL_EXTENSION=0

    _flag="$1"
    case "$_flag" in
        -E*)
            readonly ACTION="extension"
            _flag="${_flag#-E}"
            while [ -n "$_flag" ]; do
                _char="${_flag%"${_flag#?}"}"
                _flag="${_flag#?}"
                case "$_char" in
                    i) readonly INSTALL_EXTENSION=1 ;;
                    u) readonly UNINSTALL_EXTENSION=1 ;;
                    v) readonly VERBOSE=1 ;;
                    *)
                        if ! extension_parse_flag "E" "$_char" "$@"; then
                            log_error "Invalid option for -Q: -$_char"
                        fi
                        ;;
                esac
            done
            readonly ARGUMENTS="$*"
            ;;
    esac
}

extension_parse_flag() {
    _action="$1"
    _char="$2"
    _args="$*"
    case "$_action" in
        Q)
            case "$_char" in
                e) readonly LIST_EXTENSION=1 ;;
                *) log_error "Invalid option for -Q: ;$_char"
            esac
            ;;
    esac
}

extension_augment_main() {
    case "${ACTION:-}" in
        extension) extension_main_extension "$ARGUMENTS" ;;
    esac
}

extension_main_extension() (
    _requested_extensions="$*"

    if [ "$INSTALL_EXTENSION" = 1 ] && [ "$UNINSTALL_EXTENSION" = 1 ]; then
        log_error "-Ei and -Eu cannot both be set"
    fi

    if [ "$INSTALL_EXTENSION" = 1 ]; then
        extension_install_extension "$_requested_extensions" || \
            log_error "Failed to install extensions: $_requested_extensions"
    elif [ "$UNINSTALL_EXTENSION" = 1 ]; then
        extension_uninstall_extension "$_requested_extensions" || \
            log_error "Failed to uninstall extensions: $_requested_extensions"
    fi
)

extension_install_extension() (
    _extension="$*"
    for extension in $_extension; do
        _ext="$(realpath "$extension")"
        _ext_name="${_ext##*/}"
        _install_path="${EXTENSION_DIR:?}/$_ext_name"

        if [ ! -f "$_ext" ]; then
            log_warn "$_ext_name is not an extension. Skipping."
            continue
        elif [ -f "$_install_path" ]; then
            log_warn "$_ext_name is already installed. Skipping."
            continue 
        fi

        (
            cp -a "$_ext" "$_install_path" || \
                log_error "Failed to copy extension to extensions directory"

            . "$_install_path" || \
                log_error "Failed to source: $_install_path"

            command -v extension_post_install 2>/dev/null && \
                extension_post_install || \
                log_error "Failed to execute post-install commands for $_ext_name"
        ) || log_warn "Failed to install extension: $_ext_name"
    done
)

extension_unininstall_extension() (
    _extension="$*"
    for extension in $_extension; do
        _ext="$(realpath "$extension")"
        _ext_name="${_ext##*/}"
        _install_path="${EXTENSION_DIR:?}/$_ext_name"

        if [ ! -f "$_ext" ]; then
            log_warn "$_ext_name is not an extension. Skipping."
            continue
        elif [ ! -f "$_install_path" ]; then
            log_warn "$_ext_name is not installed. Skipping."
            continue 
        fi

        (
            . "$_install_path" || \
                log_error "Failed to source: $_install_path"

            command -v extension_post_uninstall 2>/dev/null && \
                extension_post_uninstall || \
                log_error "Failed to execute post-uninstall commands for $_ext_name"

            rm "$_install_path" || \
                log_error "Failed to copy extension to extensions directory"
        ) || log_warn "Failed to install extension: $_ext_name"
    done
)
