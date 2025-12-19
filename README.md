# pscl Package Manager

A lightweight, extensible package manager written in pure POSIX shell. Designed for source-based Linux distributions with a focus on simplicity, flexibility, and extensibility.

## Features

- Pure POSIX shell. No required dependencies beyonds basic UNIX utilities
- Source-based package management
- Automatic dependency resolution for installs and uninstalls
- Support for specified installation roots
- High performance with parallel downloads
- Extensible architecture with a hook-based extension API to add features to the core package management system

## Quickstart

All you need to do is clone the repo:

```bash
git clone https://github.com/Pascal0577/pscl
```

## Contributing

This is just a hobby project, but feel free to send PRs if you want

## Todo

- [] Build dependency, optional dependency, check dependency resolution
- [] Ask for confirmation before executing action
- [] Atomic BTRFS extension
