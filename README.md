# Code on the Go Terminal Packages

Scripts to build [termux-packages](https://github.com/termux/termux-packages) for [Code on the Go](https://github.com/appdevforall/CodeOnTheGo).

## How to build

### 1. Get source

Get this Git repository with :

```shell
git clone --recurse-submodules https://github.com/appdevforall/terminal-packages.git
```

### 2. Build packages

```shell
./build.sh \
    -a aarch64 \
    -p 'com.itsaky.androidide' \
    -r 'https://packages.appdevforall.org/apt/termux-main/' \
    -s ./adfa-dev-team.gpg
```

`build.sh` will patch `termux-packages` if needed, set up the output directories and then start building the packages. See [termux-packages WiKi](https://github.com/termux/termux-packages/wiki) for more information about the build system, patches, build scripts, etc.

The key specified with the `-s` option is the **public key** (**NOT** the private key!), which can be generated using :

```
gpg --export <key-id> > public-key.gpg
```

Run `build.sh -h` to learn more about the available build options.

### 3. Generate an APT repository

After the packages have been built, an APT repository can be generated with the following command :

```shell
./generate-apt-repo.sh
```

The APT repository will be created in the `output/repo` directory.

### 4. Sign the repository

The newly generated repository needs to be signed before it can be published. Sign the repository will the following command :

```shell
gpg --default-key <secret-key-id> --yes --pinentry-mode loopback --digest-algo SHA256 --clearsign -o ./output/repo/dists/stable/InRelease ./output/repo/dists/stable/Release
```

Where `<secret-key-id>` is the ID of the GPG secret key to be used for signing. Usually, this is the same key you used in [step 1](#build-packages). You may be prompted to enter the password for the GPG key.

**The repository must be signed after each time it is generated.**

### 5. Publish the repository

After signing, the contents of the `output/repo` directory can be published to a web hosting service or a S3-compatible storage server. Ensure that the directory structure is same as the repository URL.

For example, if the repository URL is `https://packages.appdevforall.org/apt/termux-main`, then the contents of the `output/repo` directory must be stored in the `apt/termux-main` directory of `packages.appdevforall.org`'s content root (usually, it's something like `/www/public/html/packages.appdevforall.org` in web hosting environments).

If you have SSH access to the web hosting service, then you can use `rsync` for incremental updates :

```
rsync -vrPL ./output/repo/* <user>@<host>:<content-root>/<repository-root>
```

Where :
- `<user>` is SSH server username.
- `<host>` is the SSH server hostname.
- `<content-root>` is the root directory of the website.
- `<repository-root>` is the directory where the repository should be stored.

### 6. Generate bootstrap packages

From the root directory of this repository, use the following command to generate the bootstrap packages :

```
./termux-packages/scripts/generate-bootstraps.sh --architectures aarch64,arm -r file://$(pwd)/output/repo -a <extra-packages>
```

Where `<extra-packages>` are the packages that are specific to the target application. For Code on the CoGo, the following packages are included in `bootstrap-*.zip` in addition to the default ones :

<!-- For CoGo maintainers:
     
     Please keep the below list up-to-date with all the extra packages we include in CoGo.
-->

- `binutils`
- `coreutils`
- `file`
- `git`
- `mandoc`
- `openjdk-21`
- `python`
- `sqlite`
- `zip`

With our changes, this should generate two archives :
- `bootstrap-<arch>.zip` - bootstrap archive without compression (`zip -0`)
- `bootstrap-<arch>.zip.br` - this is `bootstrap-<arch>.zip` archive compressed with `brotli` using `-q 11` (max compression).

# License

```
Copyright (C) 2025 Akash Yadav
 
This file is part of The Scribe Project.

Scribe is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Scribe is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Scribe.  If not, see <https://www.gnu.org/licenses/>.
```
