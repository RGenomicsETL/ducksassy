# Linux cross-builds; Windows MinGW/Rtools runners select their native GCC.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
set(MINGW_PREFIX x86_64-w64-mingw32 CACHE STRING "MinGW/Rtools cross-tool prefix, optionally absolute")
set(CMAKE_C_COMPILER "${MINGW_PREFIX}-gcc")
set(CMAKE_AR "${MINGW_PREFIX}-ar")
set(CMAKE_RANLIB "${MINGW_PREFIX}-ranlib")
