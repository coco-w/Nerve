cmake_minimum_required(VERSION 3.16)
project(nerve_ssh LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(OHOS)
    # 鸿蒙 SDK 传入的 --gcc-toolchain 会被 Clang 忽略，避免依赖的 -Werror 误判。
    string(APPEND CMAKE_C_FLAGS " -Qunused-arguments")
    string(APPEND CMAKE_CXX_FLAGS " -Qunused-arguments")
endif()
include(FetchContent)

set(aws_lc_archive "https://codeload.github.com/aws/aws-lc/tar.gz/refs/tags/v5.15.0")
set(libssh2_archive "https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz")
# 网络受限时可从本地读取同一份归档，仍校验固定的 SHA-256。
if(DEFINED ENV{NERVE_SSH_ARCHIVE_DIR})
    file(TO_CMAKE_PATH "$ENV{NERVE_SSH_ARCHIVE_DIR}" ssh_archive_dir)
    set(aws_lc_archive "${ssh_archive_dir}/aws-lc-5.15.0.tar.gz")
    set(libssh2_archive "${ssh_archive_dir}/libssh2-1.11.1.tar.gz")
endif()
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()

# 随应用静态链接，避免依赖鸿蒙的私有 OpenSSL ABI。
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_LIBSSL OFF CACHE BOOL "" FORCE)
set(BUILD_TOOL OFF CACHE BOOL "" FORCE)
set(DISABLE_GO ON CACHE BOOL "" FORCE)
set(DISABLE_PERL ON CACHE BOOL "" FORCE)
set(ENABLE_SOURCE_MODIFICATION OFF CACHE BOOL "" FORCE)
FetchContent_Declare(aws_lc
    URL "${aws_lc_archive}"
    URL_HASH SHA256=66e7132566cf2356b16ae79a9b57ea7a75ad6d65a41408753b08569c7db02921)
FetchContent_MakeAvailable(aws_lc)

list(PREPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(CRYPTO_BACKEND OpenSSL CACHE STRING "" FORCE)
FetchContent_Declare(libssh2
    URL "${libssh2_archive}"
    URL_HASH SHA256=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7)
FetchContent_MakeAvailable(libssh2)

add_library(nerve_ssh_core STATIC ssh_session.cpp mosh_udp.cpp)
target_compile_features(nerve_ssh_core PUBLIC cxx_std_17)
target_include_directories(nerve_ssh_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(nerve_ssh_core PUBLIC libssh2::libssh2 PRIVATE OpenSSL::Crypto)

if(OHOS)
    add_library(nerve_ssh SHARED ssh_napi.cpp)
    target_compile_options(nerve_ssh PRIVATE -fvisibility=hidden)
    target_link_options(nerve_ssh PRIVATE -Wl,--exclude-libs,ALL)
    target_link_libraries(nerve_ssh PRIVATE nerve_ssh_core libace_napi.z.so)
endif()

option(NERVE_BUILD_SMOKE_TEST "构建 SSH 与 Zellij 联调程序" OFF)
if(NERVE_BUILD_SMOKE_TEST)
    add_executable(nerve_ssh_smoke tests/ssh_smoke.cpp)
    target_link_libraries(nerve_ssh_smoke PRIVATE nerve_ssh_core)
endif()
