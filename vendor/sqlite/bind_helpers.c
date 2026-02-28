#include "sqlite3.h"

int refract_bind_text(sqlite3_stmt *stmt, int col, const char *ptr, int len) {
    return sqlite3_bind_text(stmt, col, ptr, len, SQLITE_TRANSIENT);
}

int refract_bind_blob(sqlite3_stmt *stmt, int col, const void *ptr, int len) {
    return sqlite3_bind_blob(stmt, col, ptr, len, SQLITE_TRANSIENT);
}
