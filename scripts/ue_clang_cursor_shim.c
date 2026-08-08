#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#define UE_CURSOR_SHIM_EXPORT __declspec(dllexport)
#else
#define UE_CURSOR_SHIM_EXPORT __attribute__((visibility("default")))
#endif

#define UE_CURSOR_SHIM_ABI_VERSION 1u
#define UE_CURSOR_SHIM_MAX_DEFINITIONS 64u
#define UE_CURSOR_SHIM_MAX_PATH_BYTES 4096u

typedef struct {
  const void *data;
  unsigned private_flags;
} CXString;

typedef struct CXFileImpl *CXFile;
typedef struct CXTranslationUnitImpl *CXTranslationUnit;

typedef struct {
  const void *ptr_data[2];
  unsigned int_data;
} CXSourceLocation;

typedef struct {
  unsigned kind;
  int xdata;
  const void *data[3];
} CXCursor;

typedef unsigned CXChildVisitResult;
typedef CXChildVisitResult (*CXCursorVisitor)(CXCursor cursor, CXCursor parent, void *client_data);

typedef struct {
  const char *(*clang_getCString)(CXString string);
  void (*clang_disposeString)(CXString string);
  unsigned (*clang_isDeclaration)(unsigned kind);
  CXCursor (*clang_getTranslationUnitCursor)(CXTranslationUnit tu);
  unsigned (*clang_visitChildren)(CXCursor parent, CXCursorVisitor visitor, void *client_data);
  CXCursor (*clang_getCanonicalCursor)(CXCursor cursor);
  CXString (*clang_getCursorUSR)(CXCursor cursor);
  CXCursor (*clang_getCursorDefinition)(CXCursor cursor);
  unsigned (*clang_Cursor_isNull)(CXCursor cursor);
  CXSourceLocation (*clang_getCursorLocation)(CXCursor cursor);
  void (*clang_getExpansionLocation)(
    CXSourceLocation location,
    CXFile *file,
    unsigned *line,
    unsigned *column,
    unsigned *offset
  );
  CXString (*clang_getFileName)(CXFile file);
} UECursorShimFns;

typedef struct {
  char path[UE_CURSOR_SHIM_MAX_PATH_BYTES];
  unsigned line;
  unsigned column;
  unsigned offset;
} UECursorShimLocation;

typedef struct {
  unsigned abi_version;
  unsigned capacity;
  unsigned count;
  unsigned overflow;
  unsigned visited_declarations;
  unsigned matched_declarations;
  unsigned error_code;
  UECursorShimLocation definitions[UE_CURSOR_SHIM_MAX_DEFINITIONS];
} UECursorShimResult;

enum {
  UE_CURSOR_SHIM_OK = 0u,
  UE_CURSOR_SHIM_ERROR_INVALID_ARGUMENT = 1u,
  UE_CURSOR_SHIM_ERROR_INVALID_TRANSLATION_UNIT = 2u,
  UE_CURSOR_SHIM_ERROR_INVALID_FUNCTION_TABLE = 3u,
};

typedef struct {
  const UECursorShimFns *fns;
  const char *target_usr;
  UECursorShimResult *result;
} UECursorShimState;

static int ue_cursor_shim_cursor_is_null(const UECursorShimFns *fns, CXCursor cursor) {
  return fns->clang_Cursor_isNull(cursor) != 0u;
}

static int ue_cursor_shim_copy_path(char *dst, const char *src) {
  if (!dst) {
    return 0;
  }
  if (!src) {
    dst[0] = '\0';
    return 0;
  }
  size_t len = strlen(src);
  if (len >= UE_CURSOR_SHIM_MAX_PATH_BYTES) {
    dst[0] = '\0';
    return 0;
  }
  memcpy(dst, src, len);
  dst[len] = '\0';
  return 1;
}

static int ue_cursor_shim_same_location(
  const UECursorShimLocation *left,
  const UECursorShimLocation *right
) {
  return left->line == right->line
    && left->column == right->column
    && left->offset == right->offset
    && strcmp(left->path, right->path) == 0;
}

static int ue_cursor_shim_collect_location(
  const UECursorShimFns *fns,
  CXCursor cursor,
  UECursorShimLocation *out
) {
  CXSourceLocation loc;
  CXFile file = NULL;
  unsigned line = 0u;
  unsigned column = 0u;
  unsigned offset = 0u;
  CXString filename;
  const char *filename_cstr = NULL;

  if (!out || ue_cursor_shim_cursor_is_null(fns, cursor)) {
    return 0;
  }

  loc = fns->clang_getCursorLocation(cursor);
  fns->clang_getExpansionLocation(loc, &file, &line, &column, &offset);
  if (!file) {
    return 0;
  }

  filename = fns->clang_getFileName(file);
  filename_cstr = fns->clang_getCString(filename);
  if (!filename_cstr || filename_cstr[0] == '\0') {
    fns->clang_disposeString(filename);
    return 0;
  }

  if (!ue_cursor_shim_copy_path(out->path, filename_cstr)) {
    fns->clang_disposeString(filename);
    return -1;
  }
  out->line = line;
  out->column = column;
  out->offset = offset;
  fns->clang_disposeString(filename);
  return out->path[0] != '\0';
}

static void ue_cursor_shim_store_definition(
  UECursorShimState *state,
  const UECursorShimLocation *location
) {
  unsigned i;

  if (!state || !location) {
    return;
  }

  for (i = 0u; i < state->result->count; i++) {
    if (ue_cursor_shim_same_location(&state->result->definitions[i], location)) {
      return;
    }
  }

  if (state->result->count >= state->result->capacity) {
    state->result->overflow = 1u;
    return;
  }

  state->result->definitions[state->result->count] = *location;
  state->result->count += 1u;
}

static CXChildVisitResult ue_cursor_shim_visit(CXCursor cursor, CXCursor parent, void *client_data) {
  UECursorShimState *state = (UECursorShimState *)client_data;
  const UECursorShimFns *fns = state ? state->fns : NULL;
  CXCursor canonical;
  CXString usr_string;
  const char *usr_cstr = NULL;

  (void)parent;

  if (!state || !fns) {
    return 0u;
  }
  if (state->result->overflow) {
    return 0u;
  }
  if (fns->clang_isDeclaration(cursor.kind) == 0u) {
    return 2u;
  }

  state->result->visited_declarations += 1u;
  canonical = fns->clang_getCanonicalCursor(cursor);
  if (ue_cursor_shim_cursor_is_null(fns, canonical)) {
    return 2u;
  }

  usr_string = fns->clang_getCursorUSR(canonical);
  usr_cstr = fns->clang_getCString(usr_string);
  if (usr_cstr && strcmp(usr_cstr, state->target_usr) == 0) {
    UECursorShimLocation location;
    CXCursor definition = fns->clang_getCursorDefinition(cursor);
    state->result->matched_declarations += 1u;
    if (!ue_cursor_shim_cursor_is_null(fns, definition)) {
      int location_state = ue_cursor_shim_collect_location(fns, definition, &location);
      if (location_state < 0) {
        state->result->overflow = 1u;
      } else if (location_state > 0) {
        ue_cursor_shim_store_definition(state, &location);
      }
    }
  }
  fns->clang_disposeString(usr_string);
  return state->result->overflow ? 0u : 2u;
}

UE_CURSOR_SHIM_EXPORT unsigned ue_clang_cursor_shim_abi_version(void) {
  return UE_CURSOR_SHIM_ABI_VERSION;
}

UE_CURSOR_SHIM_EXPORT int ue_clang_cursor_shim_lookup_definitions(
  const UECursorShimFns *fns,
  CXTranslationUnit tu,
  const char *target_usr,
  UECursorShimResult *result
) {
  UECursorShimState state;
  CXCursor root;

  if (!fns || !result || !target_usr || target_usr[0] == '\0') {
    if (result) {
      memset(result, 0, sizeof(*result));
      result->abi_version = UE_CURSOR_SHIM_ABI_VERSION;
      result->capacity = UE_CURSOR_SHIM_MAX_DEFINITIONS;
      result->error_code = UE_CURSOR_SHIM_ERROR_INVALID_ARGUMENT;
    }
    return (int)UE_CURSOR_SHIM_ERROR_INVALID_ARGUMENT;
  }
  if (!fns->clang_getTranslationUnitCursor
      || !fns->clang_visitChildren
      || !fns->clang_isDeclaration
      || !fns->clang_getCanonicalCursor
      || !fns->clang_getCursorUSR
      || !fns->clang_getCString
      || !fns->clang_disposeString
      || !fns->clang_getCursorDefinition
      || !fns->clang_Cursor_isNull
      || !fns->clang_getCursorLocation
      || !fns->clang_getExpansionLocation
      || !fns->clang_getFileName) {
    memset(result, 0, sizeof(*result));
    result->abi_version = UE_CURSOR_SHIM_ABI_VERSION;
    result->capacity = UE_CURSOR_SHIM_MAX_DEFINITIONS;
    result->error_code = UE_CURSOR_SHIM_ERROR_INVALID_FUNCTION_TABLE;
    return (int)UE_CURSOR_SHIM_ERROR_INVALID_FUNCTION_TABLE;
  }

  memset(result, 0, sizeof(*result));
  result->abi_version = UE_CURSOR_SHIM_ABI_VERSION;
  result->capacity = UE_CURSOR_SHIM_MAX_DEFINITIONS;

  root = fns->clang_getTranslationUnitCursor(tu);
  if (ue_cursor_shim_cursor_is_null(fns, root)) {
    result->error_code = UE_CURSOR_SHIM_ERROR_INVALID_TRANSLATION_UNIT;
    return (int)UE_CURSOR_SHIM_ERROR_INVALID_TRANSLATION_UNIT;
  }

  state.fns = fns;
  state.target_usr = target_usr;
  state.result = result;
  fns->clang_visitChildren(root, ue_cursor_shim_visit, &state);
  return (int)UE_CURSOR_SHIM_OK;
}
