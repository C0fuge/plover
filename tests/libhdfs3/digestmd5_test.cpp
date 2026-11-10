// Unit test of libhdfs3 patch 0003 (DigestMd5Client: SASL DIGEST-MD5 with auth / auth-int / auth-conf).
//   digestmd5_test kat                                  RFC 2831 known answer (qop=auth) + negative cases
//   digestmd5_test peer <port> <qops> <ciphers> <user> <password> <want qop> <want cipher>
//       client side of the interop run against the JDK's DIGEST-MD5 server (tests/libhdfs3/DigestServer.java)
#include "DigestMd5Client.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <openssl/opensslv.h>
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#include <openssl/provider.h>
#endif
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using Hdfs::Internal::DigestMd5Client;
using Hdfs::Internal::DigestMd5Error;

static int failures = 0;
#define CHECK(c)                                                         \
    do {                                                                 \
        if (!(c)) {                                                      \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #c); \
            ++failures;                                                  \
        }                                                                \
    } while (0)

template <class F>
static bool throws(F f) {
    try {
        f();
    } catch (const DigestMd5Error &) {
        return true;
    }
    return false;
}

static int kat() {
    // RFC 2831 section 4, example 1 (IMAP)
    const std::string ch = "realm=\"elwood.innosoft.com\",nonce=\"OA6MG9tEQGm2hh\",qop=\"auth\",algorithm=md5-sess,charset=utf-8";
    {
        DigestMd5Client c("chris", "secret", "imap", "elwood.innosoft.com", "auth");
        c.setCnonce("OA6MHXh6VqTrRk");
        std::string r = c.evaluateChallenge(ch);
        printf("response: %s\n", r.c_str());
        CHECK(r.find("response=d388dad90d4bbd760a152321f2143af7") != std::string::npos);
        CHECK(r.find("digest-uri=\"imap/elwood.innosoft.com\"") != std::string::npos);
        CHECK(r.find("qop=auth") != std::string::npos);
        CHECK(r.find("charset=utf-8") != std::string::npos);
        CHECK(!c.isComplete());
        CHECK(c.evaluateChallenge("rspauth=ea40f60335c427b5527b84dbabcdfffd").empty());
        CHECK(c.isComplete());
        CHECK(c.qop() == "auth");
        CHECK(!c.isWrapping());
        CHECK(c.wrap("abc", 3) == "abc");
    }
    {   // wrong rspauth -> server not authenticated
        DigestMd5Client c("chris", "secret", "imap", "elwood.innosoft.com", "auth");
        c.setCnonce("OA6MHXh6VqTrRk");
        c.evaluateChallenge(ch);
        CHECK(throws([&] { c.evaluateChallenge("rspauth=00000000000000000000000000000000"); }));
        CHECK(!c.isComplete());
    }
    {   // client insists on auth-conf, server offers only auth
        DigestMd5Client c("chris", "secret", "imap", "elwood.innosoft.com", "auth-conf");
        CHECK(throws([&] { c.evaluateChallenge(ch); }));
    }
    {   // auth-conf without a common cipher
        DigestMd5Client c("u", "p", "hdfs", "0", "auth-conf", "3des");
        CHECK(throws([&] { c.evaluateChallenge("nonce=\"n\",qop=\"auth-conf\",cipher=\"rc4\",algorithm=md5-sess"); }));
    }
    {   // malformed challenges
        DigestMd5Client a("u", "p", "hdfs", "0");
        CHECK(throws([&] { a.evaluateChallenge("nonce=\"n\",algorithm=md5"); }));
        DigestMd5Client b("u", "p", "hdfs", "0");
        CHECK(throws([&] { b.evaluateChallenge("nonce=\"unterminated,algorithm=md5-sess"); }));
        DigestMd5Client c("u", "p", "hdfs", "0");
        CHECK(throws([&] { c.evaluateChallenge("algorithm=md5-sess"); }));
    }
    printf("kat: %s\n", failures ? "FAILED" : "OK");
    return failures ? 1 : 0;
}

static void writeAll(int fd, const void * p, size_t n) {
    const char * c = static_cast<const char *>(p);
    while (n) {
        ssize_t w = ::write(fd, c, n);
        if (w <= 0) {
            perror("write");
            exit(2);
        }
        c += w;
        n -= w;
    }
}

static void readAll(int fd, void * p, size_t n) {
    char * c = static_cast<char *>(p);
    while (n) {
        ssize_t r = ::read(fd, c, n);
        if (r <= 0) {
            fprintf(stderr, "read: connection closed\n");
            exit(2);
        }
        c += r;
        n -= r;
    }
}

static void sendFrame(int fd, const std::string & s) {
    uint32_t n = htonl(static_cast<uint32_t>(s.size()));
    writeAll(fd, &n, 4);
    writeAll(fd, s.data(), s.size());
}

static std::string recvFrame(int fd) {
    uint32_t n;
    readAll(fd, &n, 4);
    std::string s(ntohl(n), '\0');
    if (!s.empty()) {
        readAll(fd, &s[0], s.size());
    }
    return s;
}

static int peer(int argc, char ** argv) {
    if (argc != 9) {
        fprintf(stderr, "usage: peer <port> <qops> <ciphers> <user> <password> <want qop> <want cipher>\n");
        return 2;
    }
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    // des / rc4 live in OpenSSL 3's legacy provider (the extension's runtime, AlmaLinux 8, has OpenSSL 1.1)
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");
#endif
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(atoi(argv[2]));
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, reinterpret_cast<sockaddr *>(&a), sizeof(a)) != 0) {
        perror("connect");
        return 2;
    }
    try {
        DigestMd5Client c(argv[5], argv[6], "hdfs", "0", argv[3], argv[4]);
        std::string ch = recvFrame(fd);
        sendFrame(fd, c.evaluateChallenge(ch));
        CHECK(c.evaluateChallenge(recvFrame(fd)).empty());
        CHECK(c.isComplete());
        printf("client: qop %s cipher %s maxRawSendSize %zu\n", c.qop().c_str(), c.cipher().c_str(), c.maxRawSendSize());
        CHECK(c.qop() == argv[7]);
        CHECK(c.cipher() == (std::string(argv[8]) == "-" ? std::string() : std::string(argv[8])));
        int n = 0;
        if (c.isWrapping()) {
            for (;;) {
                std::string w = recvFrame(fd);
                if (w.empty()) {
                    break;
                }
                std::string m = c.unwrap(w.data(), w.size());
                std::string r(m.rbegin(), m.rend());
                sendFrame(fd, c.wrap(r.data(), r.size()));
                ++n;
            }
            CHECK(c.wrap("", 0).empty());  // as the JDK
            // a token not made with the server's keys must be rejected
            std::string t = c.wrap("hello", 5);
            CHECK(throws([&] { c.unwrap(t.data(), t.size()); }));  // our own token: client keys, not server keys
        }
        printf("client: %d messages echoed\n", n);
        CHECK(!c.isWrapping() || n == 39);
    } catch (const DigestMd5Error & e) {
        fprintf(stderr, "DigestMd5Error: %s\n", e.what());
        return 1;
    }
    close(fd);
    printf("peer: %s\n", failures ? "FAILED" : "OK");
    return failures ? 1 : 0;
}

int main(int argc, char ** argv) {
    if (argc >= 2 && std::string(argv[1]) == "kat") {
        return kat();
    }
    if (argc >= 2 && std::string(argv[1]) == "peer") {
        return peer(argc, argv);
    }
    fprintf(stderr, "usage: digestmd5_test kat | peer ...\n");
    return 2;
}
