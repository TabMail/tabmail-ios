/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

// Registration wrapper for sqlite-vec extension.
// Per-connection — registers on a specific sqlite3* handle (for GRDB prepareDatabase).

#include <stddef.h>
#include <sqlite3.h>

// Forward declaration from sqlite-vec.h
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                     const sqlite3_api_routines *pApi);

// Register vec0 on a specific connection handle.
// Returns SQLITE_OK on success. Safe to call multiple times per connection
// (re-registration is a no-op — vec0 module already exists).
int tabmail_register_sqlite_vec_on_db(void *db) {
    if (!db) return SQLITE_ERROR;
    return sqlite3_vec_init((sqlite3 *)db, NULL, NULL);
}
