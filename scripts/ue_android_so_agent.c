#include <android/log.h>
#include <fcntl.h>
#include <jni.h>
#include <jvmti.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LOG_TAG "nvim-ue-so-agent"
#define AGENT_OK 0
#define MAP_POLL_INTERVAL_US 100000
#define MAP_MONITOR_INTERVAL_US 1000000
#define MAP_POLL_LIMIT 600

static char g_target[PATH_MAX];
static char g_original[PATH_MAX];
static char g_directory[PATH_MAX];
static char g_status[PATH_MAX];
static volatile int g_claimed;
static volatile int g_redirected;
static volatile int g_mapping_confirmed;
static volatile int g_agent_initialized;
static _Thread_local int g_in_callback;

static void copy_option(char *destination, size_t capacity, const char *begin,
                        size_t length) {
  if (capacity == 0) {
    return;
  }
  if (length >= capacity) {
    length = capacity - 1;
  }
  memcpy(destination, begin, length);
  destination[length] = '\0';
}

static void read_option(const char *options, const char *key, char *destination,
                        size_t capacity) {
  size_t key_length = strlen(key);
  const char *cursor = options;
  destination[0] = '\0';
  while (cursor != NULL && *cursor != '\0') {
    const char *end = strchr(cursor, ',');
    size_t length = end == NULL ? strlen(cursor) : (size_t)(end - cursor);
    if (length > key_length + 1 && strncmp(cursor, key, key_length) == 0 &&
        cursor[key_length] == '=') {
      copy_option(destination, capacity, cursor + key_length + 1,
                  length - key_length - 1);
      return;
    }
    cursor = end == NULL ? NULL : end + 1;
  }
}

static int ends_with(const char *value, const char *suffix) {
  size_t value_length = strlen(value);
  size_t suffix_length = strlen(suffix);
  return value_length >= suffix_length &&
         memcmp(value + value_length - suffix_length, suffix, suffix_length) ==
             0;
}

static int initialize_directory(void) {
  const char *slash = strrchr(g_target, '/');
  if (slash == NULL || slash == g_target || strcmp(slash, "/libUE4.so") != 0) {
    return 0;
  }
  copy_option(g_directory, sizeof(g_directory), g_target,
              (size_t)(slash - g_target));
  return g_directory[0] != '\0';
}

static void write_status(const char *state, const char *detail) {
  if (g_status[0] == '\0') {
    return;
  }
  int fd = open(g_status, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) {
    return;
  }
  char buffer[PATH_MAX * 3];
  int length = snprintf(buffer, sizeof(buffer),
                        "state=%s\ntarget=%s\noriginal=%s\ndetail=%s\n", state,
                        g_target, g_original, detail == NULL ? "" : detail);
  if (length > 0) {
    size_t bytes =
        (size_t)length < sizeof(buffer) ? (size_t)length : sizeof(buffer) - 1;
    (void)write(fd, buffer, bytes);
    (void)fsync(fd);
  }
  (void)close(fd);
}

static void fail_process(const char *detail) __attribute__((noreturn));

static void fail_process(const char *detail) {
  __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "%s", detail);
  write_status("error", detail);
  _exit(86);
}

static int clear_exception(JNIEnv *env) {
  if (!(*env)->ExceptionCheck(env)) {
    return 0;
  }
  (*env)->ExceptionClear(env);
  return 1;
}

static int copy_java_string(JNIEnv *env, jstring value, char *destination,
                            size_t capacity) {
  if (value == NULL || capacity == 0) {
    return 0;
  }
  const char *utf = (*env)->GetStringUTFChars(env, value, NULL);
  if (utf == NULL) {
    clear_exception(env);
    return 0;
  }
  copy_option(destination, capacity, utf, strlen(utf));
  (*env)->ReleaseStringUTFChars(env, value, utf);
  return 1;
}

static jmethodID find_method_id(jvmtiEnv *jvmti, jclass klass,
                                const char *wanted_name,
                                const char *wanted_signature) {
  jint count = 0;
  jmethodID *methods = NULL;
  if ((*jvmti)->GetClassMethods(jvmti, klass, &count, &methods) !=
      JVMTI_ERROR_NONE) {
    return NULL;
  }
  jmethodID found = NULL;
  for (jint index = 0; index < count; ++index) {
    char *name = NULL;
    char *signature = NULL;
    if ((*jvmti)->GetMethodName(jvmti, methods[index], &name, &signature, NULL) ==
            JVMTI_ERROR_NONE &&
        name != NULL && signature != NULL && strcmp(name, wanted_name) == 0 &&
        strcmp(signature, wanted_signature) == 0) {
      found = methods[index];
    }
    if (name != NULL) {
      (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)name);
    }
    if (signature != NULL) {
      (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)signature);
    }
    if (found != NULL) {
      break;
    }
  }
  if (methods != NULL) {
    (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)methods);
  }
  return found;
}

static jfieldID find_field_id(jvmtiEnv *jvmti, jclass klass,
                              const char *wanted_name,
                              const char *wanted_signature) {
  jint count = 0;
  jfieldID *fields = NULL;
  if ((*jvmti)->GetClassFields(jvmti, klass, &count, &fields) !=
      JVMTI_ERROR_NONE) {
    return NULL;
  }
  jfieldID found = NULL;
  for (jint index = 0; index < count; ++index) {
    char *name = NULL;
    char *signature = NULL;
    if ((*jvmti)->GetFieldName(jvmti, klass, fields[index], &name, &signature,
                               NULL) == JVMTI_ERROR_NONE &&
        name != NULL && signature != NULL && strcmp(name, wanted_name) == 0 &&
        strcmp(signature, wanted_signature) == 0) {
      found = fields[index];
    }
    if (name != NULL) {
      (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)name);
    }
    if (signature != NULL) {
      (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)signature);
    }
    if (found != NULL) {
      break;
    }
  }
  if (fields != NULL) {
    (void)(*jvmti)->Deallocate(jvmti, (unsigned char *)fields);
  }
  return found;
}

static int find_library(jvmtiEnv *jvmti, JNIEnv *env, jobject loader,
                        char *resolved,
                        size_t capacity) {
  jclass base_class =
      (*env)->FindClass(env, "dalvik/system/BaseDexClassLoader");
  if (base_class == NULL || clear_exception(env)) {
    return -1;
  }
  // ClassPrepare also fires for boot classes. Their loader may be BootClassLoader,
  // which is not a BaseDexClassLoader; calling a BaseDex method on it makes CheckJNI
  // abort the process instead of raising a catchable Java exception.
  if (loader == NULL || !(*env)->IsInstanceOf(env, loader, base_class)) {
    clear_exception(env);
    (*env)->DeleteLocalRef(env, base_class);
    return 0;
  }
  jmethodID method = find_method_id(
      jvmti, base_class, "findLibrary", "(Ljava/lang/String;)Ljava/lang/String;");
  if (method == NULL) {
    (*env)->DeleteLocalRef(env, base_class);
    return -1;
  }
  jstring name = (*env)->NewStringUTF(env, "UE4");
  if (name == NULL || clear_exception(env)) {
    (*env)->DeleteLocalRef(env, base_class);
    return -1;
  }
  jstring result =
      (jstring)(*env)->CallObjectMethod(env, loader, method, name);
  (*env)->DeleteLocalRef(env, name);
  (*env)->DeleteLocalRef(env, base_class);
  if (clear_exception(env)) {
    return -1;
  }
  if (result == NULL) {
    return 0;
  }
  int copied = copy_java_string(env, result, resolved, capacity);
  (*env)->DeleteLocalRef(env, result);
  return copied ? 1 : -1;
}

static jobject get_class_loader(JNIEnv *env, jclass klass) {
  jclass class_class = (*env)->FindClass(env, "java/lang/Class");
  if (class_class == NULL || clear_exception(env)) {
    return NULL;
  }
  jmethodID get_class_loader = (*env)->GetMethodID(
      env, class_class, "getClassLoader", "()Ljava/lang/ClassLoader;");
  if (get_class_loader == NULL || clear_exception(env)) {
    (*env)->DeleteLocalRef(env, class_class);
    return NULL;
  }
  jobject loader = (*env)->CallObjectMethod(env, klass, get_class_loader);
  (*env)->DeleteLocalRef(env, class_class);
  if (clear_exception(env)) {
    return NULL;
  }
  return loader;
}

static void prepend_private_directory(jvmtiEnv *jvmti, JNIEnv *env,
                                      jobject loader) {
  jclass base_class =
      (*env)->FindClass(env, "dalvik/system/BaseDexClassLoader");
  jclass path_list_class = (*env)->FindClass(env, "dalvik/system/DexPathList");
  jclass list_class = (*env)->FindClass(env, "java/util/ArrayList");
  if (base_class == NULL || path_list_class == NULL || list_class == NULL ||
      clear_exception(env)) {
    fail_process("required Android class-loader classes are unavailable");
  }

  jfieldID path_list_field = find_field_id(
      jvmti, base_class, "pathList", "Ldalvik/system/DexPathList;");
  jfieldID elements_field = find_field_id(
      jvmti, path_list_class, "nativeLibraryPathElements",
      "[Ldalvik/system/DexPathList$NativeLibraryElement;");
  jmethodID add_native_path = find_method_id(
      jvmti, base_class, "addNativePath", "(Ljava/util/Collection;)V");
  jmethodID list_constructor =
      (*env)->GetMethodID(env, list_class, "<init>", "()V");
  jmethodID list_add = (*env)->GetMethodID(
      env, list_class, "add", "(Ljava/lang/Object;)Z");
  if (path_list_field == NULL || elements_field == NULL ||
      add_native_path == NULL || list_constructor == NULL || list_add == NULL ||
      clear_exception(env)) {
    fail_process("Android class-loader layout does not match the required contract");
  }

  jobject path_list = (*env)->GetObjectField(env, loader, path_list_field);
  if (path_list == NULL || clear_exception(env)) {
    fail_process("app ClassLoader has no DexPathList");
  }
  jobjectArray before =
      (jobjectArray)(*env)->GetObjectField(env, path_list, elements_field);
  if (before == NULL || clear_exception(env)) {
    fail_process("app ClassLoader has no native library path elements");
  }
  jsize before_count = (*env)->GetArrayLength(env, before);

  jobject directories =
      (*env)->NewObject(env, list_class, list_constructor);
  jstring directory = (*env)->NewStringUTF(env, g_directory);
  if (directories == NULL || directory == NULL || clear_exception(env)) {
    fail_process("unable to allocate private native path request");
  }
  (void)(*env)->CallBooleanMethod(env, directories, list_add, directory);
  if (clear_exception(env)) {
    fail_process("unable to populate private native path request");
  }
  (*env)->CallVoidMethod(env, loader, add_native_path, directories);
  if (clear_exception(env)) {
    fail_process("BaseDexClassLoader.addNativePath rejected the private directory");
  }

  jobjectArray appended =
      (jobjectArray)(*env)->GetObjectField(env, path_list, elements_field);
  if (appended == NULL || clear_exception(env)) {
    fail_process("native library path array disappeared after addNativePath");
  }
  jsize appended_count = (*env)->GetArrayLength(env, appended);
  if (appended_count != before_count + 1) {
    fail_process("addNativePath did not append exactly one private path element");
  }

  jobject private_element =
      (*env)->GetObjectArrayElement(env, appended, appended_count - 1);
  if (private_element == NULL || clear_exception(env)) {
    fail_process("private native path element is unavailable");
  }
  jclass element_class = (*env)->GetObjectClass(env, private_element);
  if (element_class == NULL || clear_exception(env)) {
    fail_process("private native path element class is unavailable");
  }
  jobjectArray reordered =
      (*env)->NewObjectArray(env, appended_count, element_class, NULL);
  if (reordered == NULL || clear_exception(env)) {
    fail_process("unable to allocate reordered native path array");
  }
  (*env)->SetObjectArrayElement(env, reordered, 0, private_element);
  for (jsize index = 0; index < appended_count - 1; ++index) {
    jobject element = (*env)->GetObjectArrayElement(env, appended, index);
    if (element == NULL || clear_exception(env)) {
      fail_process("existing native path element became unavailable");
    }
    (*env)->SetObjectArrayElement(env, reordered, index + 1, element);
    (*env)->DeleteLocalRef(env, element);
  }
  if (clear_exception(env)) {
    fail_process("unable to reorder native library path elements");
  }
  (*env)->SetObjectField(env, path_list, elements_field, reordered);
  if (clear_exception(env)) {
    fail_process("unable to install reordered native library path elements");
  }
}

static char *mapping_path(char *line) {
  char *cursor = line;
  for (int field = 0; field < 5; ++field) {
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t') {
      ++cursor;
    }
    while (*cursor == ' ' || *cursor == '\t') {
      ++cursor;
    }
    if (*cursor == '\0' || *cursor == '\r' || *cursor == '\n') {
      return NULL;
    }
  }
  cursor[strcspn(cursor, "\r\n")] = '\0';
  const char *deleted_suffix = " (deleted)";
  if (ends_with(cursor, deleted_suffix)) {
    cursor[strlen(cursor) - strlen(deleted_suffix)] = '\0';
  }
  return cursor;
}

static int paths_equivalent(const char *left, const char *right) {
  if (strcmp(left, right) == 0) {
    return 1;
  }
  // Android's linker may record app-private mappings under /data/data even when
  // BaseDexClassLoader returned the equivalent /data/user/0 path. realpath()
  // is not reliable for this comparison on all vendor builds, so handle the
  // well-known Android CE-storage alias explicitly.
  static const char data_user_prefix[] = "/data/user/0/";
  static const char data_data_prefix[] = "/data/data/";
  if (strncmp(left, data_user_prefix, sizeof(data_user_prefix) - 1) == 0 &&
      strncmp(right, data_data_prefix, sizeof(data_data_prefix) - 1) == 0 &&
      strcmp(left + sizeof(data_user_prefix) - 1,
             right + sizeof(data_data_prefix) - 1) == 0) {
    return 1;
  }
  if (strncmp(right, data_user_prefix, sizeof(data_user_prefix) - 1) == 0 &&
      strncmp(left, data_data_prefix, sizeof(data_data_prefix) - 1) == 0 &&
      strcmp(right + sizeof(data_user_prefix) - 1,
             left + sizeof(data_data_prefix) - 1) == 0) {
    return 1;
  }
  char canonical_left[PATH_MAX];
  char canonical_right[PATH_MAX];
  return realpath(left, canonical_left) != NULL &&
         realpath(right, canonical_right) != NULL &&
         strcmp(canonical_left, canonical_right) == 0;
}

static int maps_contains_exact_path(const char *path) {
  FILE *maps = fopen("/proc/self/maps", "re");
  if (maps == NULL) {
    return -1;
  }
  char line[PATH_MAX * 2];
  int found = 0;
  while (fgets(line, sizeof(line), maps) != NULL) {
    char *mapped = mapping_path(line);
    if (mapped != NULL && paths_equivalent(mapped, path)) {
      found = 1;
      break;
    }
  }
  (void)fclose(maps);
  return found;
}

static void *watch_library_maps(void *unused) {
  (void)unused;
  int mapped = 0;
  for (int attempt = 0;; ++attempt) {
    int original_mapped = maps_contains_exact_path(g_original);
    if (original_mapped < 0) {
      fail_process("unable to read /proc/self/maps");
    }
    if (original_mapped) {
      fail_process("installed APK libUE4.so was mapped; redirection failed closed");
    }
    if (!mapped) {
      // ActivityManager can load this agent into more than one linker namespace.
      // A duplicate instance has independent globals and may not be the instance
      // that performed ClassLoader redirection, but it must still accept the
      // already-mapped target instead of killing the process on timeout.
      int target_mapped = maps_contains_exact_path(g_target);
      if (target_mapped < 0) {
        fail_process("unable to read /proc/self/maps");
      }
      if (target_mapped) {
        original_mapped = maps_contains_exact_path(g_original);
        if (original_mapped < 0) {
          fail_process("unable to re-read /proc/self/maps");
        }
        if (original_mapped) {
          fail_process("installed APK libUE4.so was mapped with the private copy");
        }
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "mapped %s", g_target);
        write_status("mapped", g_target);
        __atomic_store_n(&g_mapping_confirmed, 1, __ATOMIC_RELEASE);
        mapped = 1;
      }
    }
    // ActivityManager may invoke Agent_OnAttach more than once for one bind on
    // this vivo build. A duplicate watcher must honor another watcher's proof.
    if (!mapped && __atomic_load_n(&g_mapping_confirmed, __ATOMIC_ACQUIRE)) {
      mapped = 1;
    }
    if (!mapped && attempt + 1 >= MAP_POLL_LIMIT) {
      fail_process("private libUE4.so mapping did not appear before timeout");
    }
    usleep(mapped ? MAP_MONITOR_INTERVAL_US : MAP_POLL_INTERVAL_US);
  }
}

static void JNICALL on_class_prepare(jvmtiEnv *jvmti, JNIEnv *env,
                                     jthread thread, jclass klass) {
  (void)thread;
  if (__atomic_load_n(&g_claimed, __ATOMIC_ACQUIRE) || g_in_callback) {
    return;
  }
  g_in_callback = 1;

  jobject loader = get_class_loader(env, klass);
  if (loader == NULL) {
    clear_exception(env);
    g_in_callback = 0;
    return;
  }
  char before[PATH_MAX];
  int found = find_library(jvmti, env, loader, before, sizeof(before));
  if (found <= 0 || strcmp(before, g_original) != 0) {
    (*env)->DeleteLocalRef(env, loader);
    g_in_callback = 0;
    return;
  }
  if (!__sync_bool_compare_and_swap(&g_claimed, 0, 1)) {
    (*env)->DeleteLocalRef(env, loader);
    g_in_callback = 0;
    return;
  }

  (void)(*jvmti)->SetEventNotificationMode(
      jvmti, JVMTI_DISABLE, JVMTI_EVENT_CLASS_PREPARE, NULL);
  int original_mapped = maps_contains_exact_path(g_original);
  if (original_mapped < 0) {
    fail_process("unable to read /proc/self/maps before redirection");
  }
  if (original_mapped) {
    fail_process("installed APK libUE4.so was already mapped before redirection");
  }

  prepend_private_directory(jvmti, env, loader);
  char after[PATH_MAX];
  int redirected = find_library(jvmti, env, loader, after, sizeof(after));
  if (redirected != 1 || strcmp(after, g_target) != 0) {
    fail_process("ClassLoader.findLibrary did not resolve the app-private libUE4.so");
  }
  __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "redirected %s -> %s",
                      g_original, g_target);
  write_status("redirected", g_target);
  __atomic_store_n(&g_redirected, 1, __ATOMIC_RELEASE);
  (*env)->DeleteLocalRef(env, loader);
  g_in_callback = 0;
}

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM *vm, char *options,
                                      void *reserved) {
  (void)reserved;
  if (!__sync_bool_compare_and_swap(&g_agent_initialized, 0, 1)) {
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG,
                        "duplicate Agent_OnAttach ignored");
    return AGENT_OK;
  }
  if (options == NULL) {
    _exit(86);
  }
  read_option(options, "target", g_target, sizeof(g_target));
  read_option(options, "original", g_original, sizeof(g_original));
  read_option(options, "status", g_status, sizeof(g_status));
  if (g_target[0] == '\0' || g_original[0] == '\0' || g_status[0] == '\0' ||
      !initialize_directory() || !ends_with(g_original, "/libUE4.so")) {
    fail_process("startup-agent options are incomplete or invalid");
  }
  if (access(g_target, R_OK) != 0 || access(g_original, R_OK) != 0) {
    fail_process("target or original libUE4.so is not readable");
  }

  jvmtiEnv *jvmti = NULL;
  if ((*vm)->GetEnv(vm, (void **)&jvmti, JVMTI_VERSION_1_2) != JNI_OK ||
      jvmti == NULL) {
    fail_process("JVMTI 1.2 is unavailable");
  }
  jvmtiEventCallbacks callbacks;
  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.ClassPrepare = on_class_prepare;
  if ((*jvmti)->SetEventCallbacks(jvmti, &callbacks, sizeof(callbacks)) !=
      JVMTI_ERROR_NONE) {
    fail_process("unable to register ClassPrepare callback");
  }
  if ((*jvmti)->SetEventNotificationMode(
      jvmti, JVMTI_ENABLE, JVMTI_EVENT_CLASS_PREPARE, NULL) !=
      JVMTI_ERROR_NONE) {
    fail_process("unable to enable ClassPrepare events");
  }

  write_status("armed", g_original);
  pthread_t watcher;
  if (pthread_create(&watcher, NULL, watch_library_maps, NULL) != 0) {
    fail_process("unable to start libUE4.so maps watcher");
  }
  (void)pthread_detach(watcher);
  return AGENT_OK;
}
