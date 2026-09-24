set(CMAKE_SYSTEM_NAME Linux)

# Build static binaries by default.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries" FORCE)
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
set(PKG_CONFIG_USE_STATIC_LIBS ON)

# These defaults keep the resulting binary fully static when using musl g++.
string(APPEND CMAKE_C_FLAGS_INIT " -O3 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection")
string(APPEND CMAKE_CXX_FLAGS_INIT " -O3 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection")
string(APPEND CMAKE_EXE_LINKER_FLAGS_INIT " -static -static-libgcc -static-libstdc++ -Wl,-z,relro,-z,now")
