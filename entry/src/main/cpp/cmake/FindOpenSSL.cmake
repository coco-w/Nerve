# libssh2 通过 OpenSSL API 使用当前构建中的 AWS-LC。
if(NOT TARGET OpenSSL::Crypto)
    add_library(OpenSSL::Crypto INTERFACE IMPORTED GLOBAL)
    target_link_libraries(OpenSSL::Crypto INTERFACE "$<LINK_ONLY:crypto>")
    target_include_directories(OpenSSL::Crypto INTERFACE "${aws_lc_SOURCE_DIR}/include")
endif()
set(OPENSSL_FOUND TRUE)
set(OpenSSL_FOUND TRUE)
set(OPENSSL_INCLUDE_DIR "${aws_lc_SOURCE_DIR}/include")
