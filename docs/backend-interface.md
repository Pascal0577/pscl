# Backend API Specification

This document defines the required interface that all `backend.sh` implementations must provide. The backend layer abstracts package management operations, allowing different implementations (e.g., stow-like, traditionally installing to the filesystem) to be swapped without changing the core package manager logic.

## Overview

All backend functions are prefixed with `backend_`. They are called by the main package manager (`pscl`) and must implement the exact interface specified below. When building your own implementation you may override some or all of these functions.

## General Conventions

- **Return Values**: Functions return 0 on success, non-zero on failure
- **Output**: Functions should output their results to stdout when they need to return data
- **Errors**: Use `log_error` for fatal errors (will exit), `log_warn` for warnings
- **Logging**: Use `log_debug` for debug messages (respects `VERBOSE` setting)

## Required Functions

### `backend_run_checks`

**Purpose**: Perform environment validation and setup before any operations.

**Signature**:
```bash
backend_run_checks
```

**Parameters**: None

**Returns**:
- 0: All checks passed
- Non-zero: One or more checks failed

**Description**: 
Validates that the environment is correctly set up for package operations. This may include:
- Checking that required directories exist
- Verifying database connectivity
- Validating configuration files
- Creating necessary directory structures

Called once at startup, before any package operations

---

### `backend_ask_confirmation`

**Purpose**: Ask from the user confirmation for package transactions

**Signature**:
```bash
backend_run_checks <transaction_type> <packages_list>
```

**Parameters**:
- $1: The type of transaction being performed.
- $*: The list of packages for the user to confirm the transaction for

**Returns**:
- 0: User confirmed transaction
- 1: User did not confirm transaction

**Description**: 
Asks the user for confirmation to perform the given transation on the specified packages. Required transaction types are:
- **build** to confirm building packages
- **install** to confirm installing packages
- **uninstall** to confirm uninstalling packages
- **activation** to confirm changing activation status of packages

Called before package transactions take place, but after dependency resolution occurs

---

### `backend_get_package_name`

**Purpose**: Transform input into package names for consistency

**Signature**:
```bash
backend_get_package_name <package_list>
```

**Parameters**:
- `$*`: Space-separated list of package names or absolute/relative paths to build scripts or directories containing a build script

**Output**:
- Space-separated list of package names

**Returns**:
- 0: Success
- Non-zero: Failed to resolve one or more packages

**Description**:
Converts user-provided package identifiers into canonical package names. This may involve:
- Resolving aliases
- Expanding package groups
- Validating package existence
- Removing duplicates

**Example Input**: `/var/pkg/repositories/main/gcc/gcc.build ./repositories/main/coreutils/`

**Example Output**: `gcc coreutils`

---

### `backend_get_package_build`

**Purpose**: Locate the build script for a package.

**Signature**:
```bash
backend_get_package_build <package_name>
```

**Parameters**:
- `$1`: Package name

**Output**:
- Full path to the package's build script

**Returns**:
- 0: Build script found
- Non-zero: Build script not found

**Description**:
Returns the path to the build script that contains package metadata and build instructions. The build script typically defines:
- `package_name`
- `package_version`
- `package_dependencies`
- `build()` function
- `install_files()` function

**Example Input**: `gcc`

**Example Output**: `/var/pkg/repositories/main/gcc/gcc.build`

---

### `backend_resolve_build_order`

**Purpose**: Calculate the build order for packages and their dependencies.

**Signature**:
```bash
backend_resolve_build_order <package_list>
```

**Parameters**:
- `$*`: Space-separated list of package names

**Output**:
- Space-separated list of packages in build order (dependencies first)

**Returns**:
- 0: Successfully resolved
- Non-zero: Circular dependency or resolution failure

**Description**:
Performs topological sort on the dependency graph to determine the correct build order. Must handle:
- Transitive dependencies
- Circular dependency detection
- Already-satisfied dependencies (if applicable)

**Example Input**: `bash`

**Example Output**: `readline ncurses bash`

---

### `backend_resolve_install_order`

**Purpose**: Calculate the installation order for packages and their dependencies.

**Signature**:
```bash
backend_resolve_install_order <package_list>
```

**Parameters**:
- `$*`: Space-separated list of package names

**Output**:
- Space-separated list of packages in install order (dependencies first)

**Returns**:
- 0: Successfully resolved
- Non-zero: Circular dependency or resolution failure

**Description**:
Similar to `backend_resolve_build_order`, but may exclude already-installed packages based on `INSTALL_FORCE` setting. Must respect:
- Existing installations (unless `INSTALL_FORCE=1`)
- Runtime dependencies vs build dependencies
- Version requirements (if supported)

**Example Input**: `bash vim`

**Example Output**: `readline ncurses bash vim` (if none installed)

**Example Output**: `vim` (if bash and dependencies already installed)

---

### `backend_resolve_uninstall_order`

**Purpose**: Calculate the uninstallation order for packages.

**Signature**:
```bash
backend_resolve_uninstall_order <package_list>
```

**Parameters**:
- `$*`: Space-separated list of package names

**Output**:
- Space-separated list of packages in uninstall order (dependents first)

**Returns**:
- 0: Successfully resolved
- Non-zero: Resolution failure

**Description**:
Determines the order for uninstalling packages. Unlike build/install order, this goes in reverse (dependent packages first, dependencies last). May include:
- Packages that depend on the requested packages
- Orphaned dependencies (packages no longer needed)

**Example Input**: `wayland`

**Example Output**: `wayland libxml icu`

---

### `backend_prepare_sources`

**Purpose**: Download and prepare source code for building.

**Signature**:
```bash
backend_prepare_sources <package_list>
```

**Parameters**:
- `$*`: Space-separated list of package names

**Returns**:
- 0: All sources prepared
- Non-zero: Failed to prepare one or more sources

**Description**:
Downloads and extracts source code for packages that need to be built. This may involve:
- Downloading tarballs/archives
- Cloning git repositories
- Verifying checksums (if `CHECKSUM_CHECK=1`)
- Verifying SSL certificates (if `CERTIFICATE_CHECK=1`)
- Applying patches
- Parallel downloads (respecting `PARALLEL_DOWNLOADS`)

Sources should be placed in `$CACHE_DIR` or extracted to working directories.

---

### `backend_want_to_build_package`

**Purpose**: Determine if a package needs to be built from source.

**Signature**:
```bash
backend_want_to_build_package <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Package should be built
- Non-zero: Package should not be built (binary available)

**Description**:
Checks if a package needs to be built from source or if a pre-built package is available in `$PACKAGE_CACHE`. Used during install operations to determine whether to invoke the build process.

---

### `backend_build_source`

**Purpose**: Compile/build a package from source.

**Signature**:
```bash
backend_build_source <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Build succeeded
- Non-zero: Build failed

**Description**:
Executes the package's build process. This typically involves:
1. Creating a build directory (e.g., `$PKGDIR/build/<package>`)
2. Sourcing the build script
3. Running the `build()` function from the build script
4. Compiling the source code
5. Running tests (if applicable)

The build artifacts should be left in the build directory for the next step.

---

### `backend_create_package`

**Purpose**: Package built files into an installable format.

**Signature**:
```bash
backend_create_package <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Package created successfully
- Non-zero: Packaging failed

**Description**:
Takes built artifacts and creates an installable package. This typically involves:
1. Running the `package()` function from the build script
2. Installing files to a staging directory
3. Creating a package archive (tarball, etc.)
4. Storing package metadata
5. Moving the package to `$PACKAGE_CACHE`

The result should be a package file that can be installed without rebuilding.

---

### `backend_install_files`

**Purpose**: Install package files to the system.

**Signature**:
```bash
backend_install_files <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Installation succeeded
- Non-zero: Installation failed

**Description**:
Extracts and installs files from a package to the installation root. This involves:
- Extracting package contents
- Installing files to `${INSTALL_ROOT}/usr/...` or appropriate locations
- Setting file permissions
- Handling conflicts (if any)

Files are installed but may not necessarily be "activated" yet (see `backend_activate_package`).

---

### `backend_register_package`

**Purpose**: Register a package as installeed in the package database.

**Signature**:
```bash
backend_register_package <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Registration succeeded
- Non-zero: Registration failed

**Description**:
Records that a package is installed in the package database. This typically involves:
- Adding the package to the world file (`$WORLD`)
- Recording package metadata (version, files, etc.)
- Updating dependency information
- Creating file manifests

---

### `backend_activate_package`

**Purpose**: Activate a package, making its files available to the system.

**Signature**:
```bash
backend_activate_package <package_name>
```

**Parameters**:
- `$1`: Package name (or space-separated list)

**Returns**:
- 0: Activation succeeded
- Non-zero: Activation failed

**Description**:
Makes package files active/usable on the system. This may involve:
- Creating symlinks from package store to system locations
- Updating system caches (ldconfig, icon cache, etc.)
- Running post-activation scripts
- Enabling services

Used in systems with Stow-like activation or atomic package management.

---

### `backend_unactivate_package`

**Purpose**: Deactivate a package, making its files unavailable to the system.

**Signature**:
```bash
backend_unactivate_package <package_name>
```

**Parameters**:
- `$1`: Package name (or space-separated list)

**Returns**:
- 0: Deactivation succeeded
- Non-zero: Deactivation failed

**Description**:
Reverses the activation process. This may involve:
- Removing symlinks
- Cleaning up empty directories
- Updating system caches
- Stopping services

The package files remain on disk but are no longer active.

---

### `backend_remove_files`

**Purpose**: Remove package files from the filesystem.

**Signature**:
```bash
backend_remove_files <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Removal succeeded
- Non-zero: Removal failed

**Description**:
Physically deletes package files from the installation root. This involves:
- Reading the package file manifest
- Removing all files belonging to the package
- Cleaning up empty directories
- Handling shared files (if applicable)

Should only be called after `backend_unactivate_package`, if applicable.

---

### `backend_unregister_package`

**Purpose**: Remove a package from the package database.

**Signature**:
```bash
backend_unregister_package <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Unregistration succeeded
- Non-zero: Unregistration failed

**Description**:
Removes package metadata from the database. This involves:
- Removing from world file (`$WORLD`)
- Deleting package metadata
- Updating dependency tracking
- Removing file manifests

---

### `backend_is_installed`

**Purpose**: Check if a package is currently installed.

**Signature**:
```bash
backend_is_installed <package_name>
```

**Parameters**:
- `$1`: Package name

**Returns**:
- 0: Package is installed
- Non-zero: Package is not installed

**Description**:
Queries the package database to determine if a package is currently installed. Should respect `$INSTALL_ROOT` if set.

**Note**: No output to stdout; return value indicates status.

---

### `backend_query`

**Purpose**: Display information about a package.

**Signature**:
```bash
backend_query <package_name>
```

**Parameters**:
- `$1`: Package name (may be empty for some query types)

**Returns**:
- 0: Query succeeded
- Non-zero: Query failed

**Description**:
Displays package information based on flags set in `parse_arguments`:
- `SHOW_INFO=1`: Display package metadata (name, version, description, dependencies)
- `LIST_FILES=1`: List all files owned by the package
- `PRINT_WORLD=1`: List all installed packages (ignores `$1`)

**Example Output** (SHOW_INFO):
```
Name         : gcc
Version      : 13.2.0
Description  : GNU Compiler Collection
Dependencies : glibc binutils gmp mpfr mpc
Installed    : Yes
```

**Example Output** (LIST_FILES):
```
/usr/bin/gcc
/usr/bin/g++
/usr/lib/libgcc_s.so
...
```

**Example Output** (PRINT_WORLD):
```
bash-5.2.15
coreutils-9.3
gcc-13.2.0
...
```

---

## Environment Variables

Backend implementations must respect the following environment variables set by the main script:

### Required Variables
- `$PKGDIR`: Root directory of the package manager
- `$METADATA_DIR`: Directory for package database/metadata
- `$WORLD`: Path to the world file (list of explicitly installed packages)
- `$CACHE_DIR`: Directory for source code cache
- `$PACKAGE_CACHE`: Directory for built package cache
- `$REPOSITORY_LIST`: Pattern matching repository directories
- `$EXTENSION_DIR`: Directory containing extensions

### Optional Variables
- `$INSTALL_ROOT`: Installation prefix (default: `/`, may be `/mnt/sysroot`, etc.)
- `$VERBOSE`: Enable verbose/debug output (0 or 1)
- `$INSTALL_FORCE`: Force reinstallation even if already installed (0 or 1)
- `$RESOLVE_DEPENDENCIES`: Enable dependency resolution (0 or 1)
- `$PARALLEL_DOWNLOADS`: Number of parallel downloads (default: 5)
- `$CERTIFICATE_CHECK`: Verify SSL certificates (0 or 1)
- `$CHECKSUM_CHECK`: Verify file checksums (0 or 1)
- `$DO_CLEANUP`: Clean up build directories after success (0 or 1)

---

## Build Script Interface

While not part of the backend really, backend implementations must parse and execute build scripts with the following expected format:

### Required Variables
```bash
package_name="gcc"
package_version="13.2.0"
package_source="https://ftp.gnu.org/gnu/gcc/gcc-13.2.0/gcc-13.2.0.tar.xz"
package_checksum="sha256:..."
```

### Optional Variables
```bash
package_dependencies="glibc binutils gmp mpfr mpc"
package_description="GNU Compiler Collection"
package_license="GPL-3.0"
```

### Required Functions
```bash
build() {
    cd "$package_name-$package_version"
    ./configure --prefix=/usr
    make -j$(nproc)
}

package() {
    cd "$package_name-$package_version"
    make DESTDIR="$pkgdir" install
}
```

The backend must provide the `$pkgdir` variable to the `package()` function, pointing to the staging/fakeroot directory.

---

## Testing Your Backend Implementation

To verify your backend implementation, ensure it can handle:

1. **Basic install/uninstall cycle**
   ```bash
   ./pscl -I package_name
   ./pscl -U package_name
   ```

2. **Dependency resolution**
   ```bash
   ./pscl -I package_with_dependencies
   ./pscl -U package_with_otherwise_orphaned_dependencies
   ```

3. **Build from source**
   ```bash
   ./pscl -B package_name
   ./pscl -Ib package_name
   ```

4. **Query operations**
   ```bash
   ./pscl -Qi package_name
   ./pscl -Ql package_name
   ./pscl -Qw
   ```

5. **Alternate root**
   ```bash
   ./pscl -Ir /mnt/sysroot package_name
   ```

6. **Force operations**
   ```bash
   ./pscl -If package_name
   ```

---

## Notes for Implementers

- **Error Handling**: Always provide clear error messages via `log_error` or `log_warn`, and try to propagate errors where possible
- **Atomic Operations**: Where possible, make operations atomic
- **Subshells**: Implement each of these functions as subshells where possible to lower the chance of accidentally polluting global state
- **Thread Safety**: If your backend uses shared state, ensure operations are properly locked

---

## Version

This specification is version 1.0.0 and corresponds to `pscl` version 1.0.0. This specification could very well change in future updates
