#ifndef CDABBI_SQLITE_H
#define CDABBI_SQLITE_H

#include <sqlite3.h>

// `sqlite3_db_config` is variadic, which Swift cannot call. These wrappers cover the two options we set.

/// Enables SQLITE_DBCONFIG_DEFENSIVE. Returns an SQLite result code.
int dabbi_sqlite3_enable_defensive(sqlite3 *db);

/// Turns SQLITE_DBCONFIG_TRUSTED_SCHEMA off. Returns an SQLite result code.
int dabbi_sqlite3_distrust_schema(sqlite3 *db);

#endif
