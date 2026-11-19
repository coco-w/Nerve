# libssh2 通过 OpenSSL API 使用当前构建中的 AWS-LC。
if(NOT TARGET OpenSSL::Crypto)
    add_library(OpenSSL::Crypto INTERFACE IMPORTED GLOBAL)
    target_link_libraries(OpenSSL::Crypto INTERFACE "$<LINK_ONLY:crypto>")
    target_include_directories(OpenSSL::Crypto INTERFACE "${aws_lc_SOURCE_DIR}/include")
endif()
if(TARGET ssl AND NOT TARGET OpenSSL::SSL)
    # libdatachannel 的 DTLS 与 SSH 共用随应用打包的 AWS-LC。
    add_library(OpenSSL::SSL INTERFACE IMPORTED GLOBAL)
    target_link_libraries(OpenSSL::SSL INTERFACE "$<LINK_ONLY:ssl>" OpenSSL::Crypto)
endif()
set(OPENSSL_FOUND TRUE)
set(OpenSSL_FOUND TRUE)
set(OPENSSL_INCLUDE_DIR "${aws_lc_SOURCE_DIR}/include")
