TERMUX_PKG_HOMEPAGE=https://github.com/appdevforall/terminal-packages/tree/main/packages/sqlite-brotli
TERMUX_PKG_DESCRIPTION="SQLite extension adding the encodeBrotli and decodeBrotli functions"
TERMUX_PKG_LICENSE="GPL-3.0"
TERMUX_PKG_MAINTAINER="@appdevforall"
TERMUX_PKG_VERSION=1.0.0
TERMUX_PKG_REVISION=1
TERMUX_PKG_DEPENDS="brotli"
TERMUX_PKG_BUILD_DEPENDS="libsqlite"
TERMUX_PKG_RECOMMENDS="sqlite"
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_AUTO_UPDATE=false

termux_step_make() {
	# Links Brotli only. The SQLite API comes from the loading process through
	# sqlite3ext.h, so the extension works with any sqlite3 that can load it.
	$CC $CPPFLAGS $CFLAGS -fPIC -shared \
		"$TERMUX_PKG_BUILDER_DIR/sqlite-brotli.c" \
		-o sqlite-brotli.so \
		$LDFLAGS -lbrotlienc -lbrotlidec
}

termux_step_make_install() {
	# In $PREFIX/lib, where the sqlite3 shell's RUNPATH finds it, so
	# `.load sqlite-brotli` works without a path.
	install -Dm600 sqlite-brotli.so "$TERMUX_PREFIX/lib/sqlite-brotli.so"
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR/README.md" \
		"$TERMUX_PREFIX/share/doc/sqlite-brotli/README.md"
	# Executable, so it runs directly as well as with bash.
	install -Dm700 "$TERMUX_PKG_BUILDER_DIR/tests/run-tests.sh" \
		"$TERMUX_PREFIX/share/sqlite-brotli/run-tests.sh"
}
