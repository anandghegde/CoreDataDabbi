#include "CDabbiSQLite.h"

int dabbi_sqlite3_enable_defensive(sqlite3 *db) {
    return sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, (int *)0);
}

int dabbi_sqlite3_distrust_schema(sqlite3 *db) {
#ifdef SQLITE_DBCONFIG_TRUSTED_SCHEMA
    return sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, (int *)0);
#else
    return SQLITE_OK;
#endif
}
