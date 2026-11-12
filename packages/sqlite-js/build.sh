TERMUX_PKG_HOMEPAGE=https://github.com/sqliteai/sqlite-js
TERMUX_PKG_DESCRIPTION="SQLite extension for functions written in JavaScript"
TERMUX_PKG_LICENSE="Apache-2.0, MIT"
TERMUX_PKG_LICENSE_FILE="LICENSE, LICENSE.quickjs"
TERMUX_PKG_MAINTAINER="@appdevforall"
TERMUX_PKG_VERSION=1.3.7
TERMUX_PKG_REVISION=5
TERMUX_PKG_SRCURL=https://github.com/sqliteai/sqlite-js/archive/refs/tags/${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=a3251ba5b10beb4b1f9b001f6595581a85015dd792ee93aa1947db12b2f8f316
TERMUX_PKG_BUILD_DEPENDS="libsqlite"
TERMUX_PKG_RECOMMENDS="sqlite"
TERMUX_PKG_BUILD_IN_SRC=true
# The *.patch files are ours (ADFA-7081) and sent upstream; check each one
# against a new upstream version, and drop those upstream has merged.
TERMUX_PKG_AUTO_UPDATE=false

termux_step_post_get_source() {
	# QuickJS (quickjs-ng, amalgamated into libs/quickjs.c) is MIT-licensed,
	# with the license only in the comment that heads each amalgamated file.
	# Collect every copyright line, then the license text once.
	{
		grep -o 'Copyright (c) [^*]*' libs/quickjs.c | sed 's/[[:space:]]*$//' | sort -u
		echo
		awk '/Permission is hereby granted/ { on = 1 }
			on { sub(/^ \* ?/, ""); print }
			on && /THE SOFTWARE\.$/ { exit }' libs/quickjs.c
	} >LICENSE.quickjs
}

termux_step_make() {
	# QuickJS is compiled in. The SQLite API comes from the loading process
	# through sqlite3ext.h, so the extension works with any sqlite3 that can
	# load it. -idirafter puts the SQLite headers bundled in libs/ after
	# Termux's, which $CPPFLAGS adds with -isystem; quickjs.h is only in libs/.
	#
	# SQLite derives the entry point from the file name, sqlite3_sqlitejs_init
	# for sqlite-js.so, but upstream names it sqlite3_js_init, so --defsym adds
	# the first as an alias. sqlite-js.map exports only those two: SQLite opens
	# extensions with RTLD_GLOBAL, so an exported QuickJS function or
	# sqlite3_api could bind to another extension's copy.
	$CC $CPPFLAGS $CFLAGS -fPIC -shared -DQJS_BUILD_LIBC -idirafter libs \
		src/sqlitejs.c libs/quickjs.c \
		-o sqlite-js.so \
		$LDFLAGS -lm \
		-Wl,--version-script="$TERMUX_PKG_BUILDER_DIR/sqlite-js.map" \
		-Wl,--defsym=sqlite3_sqlitejs_init=sqlite3_js_init

	local exports
	exports=$($NM -D --defined-only sqlite-js.so | awk '{ print $3 }' | sort | tr '\n' ' ')
	if [[ $exports != "sqlite3_js_init sqlite3_sqlitejs_init " ]]; then
		termux_error_exit "sqlite-js.so must export only its entry points, but exports: $exports"
	fi
}

termux_step_make_install() {
	# In $PREFIX/lib, where the sqlite3 shell's RUNPATH finds it, so
	# `.load sqlite-js` works without a path.
	install -Dm600 sqlite-js.so "$TERMUX_PREFIX/lib/sqlite-js.so"
	install -Dm600 "$TERMUX_PKG_BUILDER_DIR/README.md" \
		"$TERMUX_PREFIX/share/doc/sqlite-js/README.md"
	# Executable, so it runs directly as well as with bash.
	install -Dm700 "$TERMUX_PKG_BUILDER_DIR/tests/run-tests.sh" \
		"$TERMUX_PREFIX/share/sqlite-js/run-tests.sh"
}
