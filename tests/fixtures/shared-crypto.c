/* R23: ACCP/JNI-style shared object that statically embeds libssl.a/libcrypto.a. */
#include <openssl/crypto.h>
#include <openssl/ssl.h>

const char *elide_crypto_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
const void *elide_tls_method(void) { return TLS_method(); }
