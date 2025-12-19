# Extension API Specification

This document defines the extension system for `pscl`, the package manager. Extensions allow adding custom functionality, commands, flags, and lifecycle hooks without modifying the core package manager code.

## Overview

Extensions are shell scripts (`.sh` files) placed in the `$EXTENSION_DIR` directory (typically `extensions/`). They are automatically loaded at startup and can register hooks to customize package manager behavior.

**Key Capabilities:**
- Add new command-line actions (e.g., `-S` for sync)
- Add new flags to existing actions (e.g., `-t` to `-Q`)
- Hook into package lifecycle events (pre/post install, build, etc.)
- Extend or alter the main execution flow
- Share functionality between extensions

---

## Extension Loading Process

- Core extensions are loaded first: `stdlib.sh` and `backend.sh`
- All other `.sh` files in `$EXTENSION_DIR` are sourced alphabetically
- Extensions register their hooks during sourcing
- Hooks are called in registration order during execution

---

## Hook System

Extensions register hooks using the `register_hook` function from `stdlib.sh`:

```bash
register_hook "<hook_point>" "<function_name>"
```

These hooks execute all registered functions in order. All "pre-" hooks must succeed for the operation to continue.

- `pre_install` - Before installing a package
- `post_install` - After installing a package
- `pre_build` - Before building a package
- `post_build` - After building a package
- `pre_uninstall` - Before uninstalling a package
- `post_uninstall` - After uninstalling a package
- `pre_query` - Before querying a package
- `post_query` - After querying a package
- `pre_activation` - Before activating a package
- `post_activation` - After activating a package

These hooks stop executing once one returns success (0). Used for handling actions and flags. Each registered function is called in order. When one returns 0, no further hooks are called and the system considers the request handled.

- `action` - Parse custom command-line actions
- `flag` - Parse custom flags within existing actions
- `main` - Handle custom actions during main execution

---

## Writing Extensions

### Extension Naming Convention

- Use descriptive names like `git-integration.sh`, `btrfs-support.sh`
- Use `.sh` extension. This is required
- Don't use names that conflict with core files: `stdlib.sh`, `backend.sh`

---

## Action Hooks

Action hooks allow extensions to add completely new command-line actions (like `-E` for extension management). Register them like so:

```bash
register_hook "action" my_action_parser
```

The function `my_action_parser` will be passed the entire action and flag (`-Ibf`, `-Uv`, etc) and the remaining arguments of the user input (`gcc coreutils` for example) like so:

```bash
my_action_parser "-Ibf" gcc coreutils
```

### Action Parser Responsibilities

- Check if the flag matches your action pattern and return 0 if handled, return 1 if not your action
- Parse the flag and its options (e.g., `-E` with `-i`, `-u` sub-flags)
- Set variables like `ACTION`, `ARGUMENTS`, and any custom flags

### Example: Adding an `-E` (Extension) Action

```bash
ext_mgmt_parse_action() {
    # Default values
    INSTALL_EXTENSION=false
    UNINSTALL_EXTENSION=false
    LIST_EXTENSION=false

    _flag="$1"
    shift
    case "$_flag" in
        -E*)
            # Set the action and strip -E from the flag
            readonly ACTION="extension"
            _flag="${_flag#-E}"
            while [ -n "$_flag" ]; do
                _char="${_flag%"${_flag#?}"}"
                _flag="${_flag#?}"
                case "$_char" in
                    i) readonly INSTALL_EXTENSION=true ;;
                    u) readonly UNINSTALL_EXTENSION=true ;;
                    v) readonly VERBOSE=1 ;;
                    *) log_error "Invalid option for -E: -$_char" ;;
                esac
            done
            # Store remaining arguments
            readonly ARGUMENTS="$*"
            ;;

        # Not our action to process
        *) return 1 ;;
    esac
}

# Register the action so pscl can parse -E
register_hook "action" my_parse_sync_action
```

### Testing Action Hooks

```bash
# User runs:
./pscl -Ei extension.sh

# Your function receives:
# _flag = "-Ei"
# $* = "extension.sh"

# After parsing:
# ACTION="extension"
# INSTALL_EXTENSION=true
# ARGUMENTS="extension.sh"
```

---

## Flag Hooks

Flag hooks allow extensions to add new flags to existing actions (like adding `-e` to `-Q` to query extensions). Register them like so:

```bash
register_hook "flag" my_flag_parser
```

The function `my_flag_parser` will be passed the letter of the action (`Q` for query, `B` for build, etc), a flag for that action (`l` to list files, `w` to print world, etc), and the remaining arguments of the user input (`gcc coreutils` for example) like so:

```bash
my_flag_parser Q l gcc coreutils
```

### Flag Parser Responsibilities

- Check if you handle this action/flag combination and return 0 if handled, return 1 if it's not your flag to handle
- Set variables or perform actions based on the flag

### Example: Adding Custom Flags

```bash
ext_mgmt_parse_flag() {
    _action="$1"
    _char="$2"

    case "$_action" in
        Q)
            case "$_char" in
                e) readonly LIST_EXTENSION=true ;;
                *) return 1 ;; # Not our flag to process
            esac
            ;;

        *) return 1 ;; # Not our action to process
    esac
}

# Register the flag so pscl can parse -Qe
register_hook "flag" my_flag_parser
```

### Testing Flag Hooks

```bash
# User runs:
./pscl -Qe package_name

# Your function receives:
# _action = "Q"
# _char = "e"

# After handling:
# LIST_EXTENSION=true
```

---

## Main Hooks

Main hooks handle the execution of custom actions defined by action hooks. Register them like so:

```bash
register_hook "main" my_main_handler
```

The function `my_main_handler` will be passed the entire list of user arguments (`gcc coreutils` for example) like so:

```bash
my_main_handler gcc coreutils
```

### Main Handler Responsibilities

- Check if this is your action and return 0 if handled, return 1 if not your action
- Execute the appropriate logic for the action

### Example: Handling a Sync Action

```bash
ext_mgmt_augment_main() {
    # Use ACTION variable
    case "${ACTION:-}" in
        extension) extension_main_extension "$ARGUMENTS" ;; # Use 
        *) return 1 ;;
    esac
}

# Register hook so we can execute ext_mgmt_augment_main
register_hook "main" ext_mgmt_augment_main
```

### Testing Main Hooks

```bash
# User runs:
./pscl -Ei extension.sh

# Action hook sets:
# ACTION=extension
# ARGUMENTS=extension.sh

# Main hook receives:
# $*=extension.sh
```

---

## Lifecycle Hooks

### Purpose

Lifecycle hooks allow extensions to run code before/after package operations without replacing core functionality. This can be used to run commands for custom flags for existing actions

### Registration

```bash
register_hook "pre_install" my_pre_install
register_hook "post_install" my_post_install
```

### Function Signature

All lifecycle hooks receive the package name as the first argument:

```bash
my_lifecycle_hook() {
    _pkg_name="$1"
    
    # Your logic here
    
    # Return 0 for success, non-zero to abort the operation
}
```

### Available Lifecycle Hooks

| Hook | When Called |
|------|-------------|
| `pre_install` | Before installing package files
| `post_install` | After package installed and activated
| `pre_build` | Before building from source
| `post_build` | After package built 
| `pre_uninstall` | Before uninstalling
| `post_uninstall` | After package removed 
| `pre_query` | Before querying package info
| `post_query` | After querying package info
| `pre_activation` | Before activating package links
| `post_activation` | After package activated

### Example: Post-Install Hook

```bash
extension_query_extensions() (
    if "${LIST_EXTENSION:-false}"; then
        ls "${EXTENSION_DIR:?}"
    fi
)

# Register post_install hook
register_hook "post_install" extension_query_extensions
```

### Important Notes

- All lifecycle hooks are executed (not first-match)
- Returning non-zero aborts the operation for pre- hooks
- Multiple extensions can register the same hook, all will run

---

## Accessing Package Manager State

Extensions have access to all global variables set by the package manager:

### Directory Variables
```bash
$PKGDIR           # Package manager root directory
$METADATA_DIR     # Metadata/database directory
$CACHE_DIR        # Source code cache
$PACKAGE_CACHE    # Built package cache
$EXTENSION_DIR    # Extension directory
$INSTALL_ROOT     # Installation prefix (may be "/" or "/mnt/sysroot")
```

### Action Variables
```bash
$ACTION           # Current action (install, build, query, etc.)
$ARGUMENTS        # Package names or arguments
$ACTIVATION       # Activation mode ("up" or "down")
```

### Flag Variables
```bash
$VERBOSE              # Verbose/debug output (0 or 1)
$RESOLVE_DEPENDENCIES # Dependency resolution enabled (0 or 1)
$INSTALL_FORCE        # Force reinstall (0 or 1)
$CERTIFICATE_CHECK    # Verify SSL certificates (0 or 1)
$CHECKSUM_CHECK       # Verify checksums (0 or 1)
$DO_CLEANUP           # Clean up after build (0 or 1)
$PARALLEL_DOWNLOADS   # Number of parallel downloads
$SHOW_INFO            # Show package info (0 or 1)
$LIST_FILES           # List package files (0 or 1)
$PRINT_WORLD          # Print all installed packages (0 or 1)
```

### Example

```bash
my_pre_build() {
    _pkg_name="$1"
    
    # Check if verbose mode is enabled
    if [ "$VERBOSE" = 1 ]; then
        echo "Building $_pkg_name with full debug output"
    fi
    
    # Access installation root
    if [ -n "$INSTALL_ROOT" ] && [ "$INSTALL_ROOT" != "/" ]; then
        echo "Building for alternate root: $INSTALL_ROOT"
    fi
    
    return 0
}
```

---

## Using stdlib.sh and Backend Functions

Extensions can use utility functions from `stdlib.sh` and call backend functions to interact with the package database.

### Example

```bash
# Get full dependency tree with resolution
tree=$(get_dependency_tree "gcc vim")

# Get package build script path
build_script=$(backend_get_package_build "gcc")

# Resolve dependencies
install_order=$(backend_resolve_install_order "gcc vim")

# Query package information
backend_query "gcc"  # Respects SHOW_INFO, LIST_FILES, etc.
```

See the Backend API Specification for complete function documentation.

---

## Logging Functions

Extensions should use the standard logging functions:

```bash
# Fatal error (exits immediately)
log_error "Something went wrong"

# Warning (continues execution)
log_warn "This might be a problem"

# Debug message (only shown if VERBOSE=1)
log_debug "Detailed information"
```

### Logging Conventions

- Use `log_error` for fatal errors only
- Use `log_warn` for recoverable problems
- Use `log_debug` liberally for troubleshooting
- Let the logging functions handle formatting

---

## Complete Extension Example

See `extensions/extension-management.sh` for an example implemenation of an extension

---

## Extension Best Practices

### Do's

1. **Return proper status codes**
   - Return 0 when you handle something
   - Return 1 when you don't handle something
   - Use `log_error` for fatal errors (it exits automatically)

2. **Use unique variable names**
   - Prefix variables with your extension name
   - Use readonly for variables in action hooks

3. **Handle errors gracefully in post- hooks**
   - Log warnings instead of failing
   - Don't block operations on non-critical failures

4. **Test with other extensions**
   - Ensure your extension works with extension-management.sh
   - Test flag combinations with multiple extensions
   - Verify your action doesn't conflict with others

### Don'ts

1. **Don't modify global state carelessly**
   - Don't change `$ACTION` unless you're handling the action
   - Don't unset variables set by other extensions

2. **Don't call log_error in flag hooks**
   - Return 1 instead if you don't handle the flag
   - Let the core handle "invalid flag" errors

3. **Don't assume execution order**
   - Extensions are loaded alphabetically
   - Don't depend on other extensions being loaded first
   - Use hook registration, not direct function calls

---

## Extension Installation

Extensions can provide post-install hooks to set themselves up:

```bash
#!/bin/sh
# my-extension.sh

# Your extension code here...

# Optional: Run setup after installation
extension_post_install() {
    log_debug "Setting up my-extension"
    
    # Create necessary directories
    mkdir -p "${PKGDIR}/my-extension-data"
    
    # Create config file if it doesn't exist
    if [ ! -f "${PKGDIR}/my-extension.conf" ]; then
        cat > "${PKGDIR}/my-extension.conf" <<- EOF
			# My Extension Configuration
			ENABLED=1
			OPTION=value
		EOF
    fi
    
    echo "My extension installed successfully!"
    return 0
}

# Optional: Clean up before uninstallation
extension_post_uninstall() {
    log_debug "Cleaning up my-extension"

    # Ask before removing data
    printf "Remove extension data? [y/N] "
    read -r response
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
        rm -rf "${PKGDIR}/my-extension-data"
        rm -f "${PKGDIR}/my-extension.conf"
        echo "Extension data removed"
    fi

    return 0
}
```

These functions are automatically called by `extension-management.sh` during install/uninstall.

---

## Debugging Extensions

Setting `VERBOSE=1` is recommended to debug argument parsing

```bash
VERBOSE=1 ./pscl -I package_name
```

And be sure to add debug calls in your extension

```bash
my_function() {
    log_debug "Function called with: $*"
    log_debug "Current ACTION: $ACTION"
    log_debug "ARGUMENTS: $ARGUMENTS"
    
    # Your code...
}
```

### Test Hook Registration

```bash
# Add to your extension
log_debug "Registering hooks for my-extension"
register_hook "action" my_action_parser
log_debug "Action hook registered"
```

### Verify Hook Execution

Look for these patterns in verbose output:
```
[DEBUG] Hooks to run: [ my_function other_function ]
[DEBUG] Running hook: my_function
[DEBUG] Hook my_function handled this action
```

---

## Extension Security Considerations

1. **Validate user input**
   - Sanitize file paths
   - Validate package names
   - Check for command injection

2. **Use safe file operations**
   - Use `realpath` for paths
   - Check file existence before operations
   - Set proper permissions

3. **Handle sensitive data carefully**
   - Don't log passwords or tokens
   - Use secure temporary files
   - Clean up sensitive data after use

4. **Privilege escalation**
   - Be aware of when the package manager runs as root
   - Don't trust user-provided paths when running privileged
   - Validate before executing system commands

---

This specification is version 1.0.0 and corresponds to `pscl` version 1.0.0. It could very well change in the future.
