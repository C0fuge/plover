// Unit test of libhdfs3 patch 0006 (TransferInfo: negotiated data-transfer QOP / cipher per DataNode). No HDFS.
#include "TransferInfo.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

using Hdfs::Internal::TransferInfo;
using Hdfs::Internal::TransferInfoEntry;

static int failures = 0;
#define CHECK(c)                                                                                                       \
    do {                                                                                                               \
        if (!(c)) {                                                                                                    \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                                          \
            ++failures;                                                                                                \
        }                                                                                                              \
    } while (0)

static const TransferInfoEntry * find(const std::vector<TransferInfoEntry> & v, const std::string & dn) {
    for (const auto & e : v) {
        if (e.datanode == dn) {
            return &e;
        }
    }
    return nullptr;
}

int main() {
    TransferInfo & ti = TransferInfo::instance();
    CHECK(&ti == &TransferInfo::instance());
    CHECK(ti.snapshot().empty());

    // first negotiation is "changed" (logged once ungated), repeats are not, a change is again
    CHECK(ti.record("dn1(10.0.0.1):9866", "auth-conf", "AES/CTR/NoPadding", 256));
    CHECK(!ti.record("dn1(10.0.0.1):9866", "auth-conf", "AES/CTR/NoPadding", 256));
    CHECK(!ti.record("dn1(10.0.0.1):9866", "auth-conf", "AES/CTR/NoPadding", 256));
    CHECK(ti.record("dn1(10.0.0.1):9866", "auth-conf", "3des", 0));
    CHECK(ti.record("dn2(10.0.0.2):9866", "auth", "", 0));
    CHECK(ti.record("dn3(10.0.0.3):1004", "none", "", 0));

    // a failure before any success: entry exists, no connection; the first success is then still "changed"
    ti.recordFailure("dn4(10.0.0.4):9866", "DataTransferSasl: SASL handshake with DataNode dn4 failed: bad");
    ti.recordFailure("dn1(10.0.0.1):9866", std::string(5000, 'x'));
    std::vector<TransferInfoEntry> s = ti.snapshot();
    CHECK(s.size() == 4);
    const TransferInfoEntry * e1 = find(s, "dn1(10.0.0.1):9866");
    CHECK(e1 && e1->qop == "auth-conf" && e1->cipher == "3des" && e1->keyBits == 0 && e1->connections == 4 &&
          e1->failures == 1 && e1->lastError.size() == 1000 && e1->firstMs > 1600000000000LL &&
          e1->lastMs >= e1->firstMs);
    const TransferInfoEntry * e2 = find(s, "dn2(10.0.0.2):9866");
    CHECK(e2 && e2->qop == "auth" && e2->cipher.empty() && e2->connections == 1 && e2->failures == 0 &&
          e2->lastError.empty());
    const TransferInfoEntry * e4 = find(s, "dn4(10.0.0.4):9866");
    CHECK(e4 && e4->connections == 0 && e4->failures == 1 && e4->lastMs == 0 && e4->qop.empty());
    CHECK(ti.record("dn4(10.0.0.4):9866", "auth-int", "", 0));

    // concurrent records: counters add up
    ti.clear();
    CHECK(ti.snapshot().empty());
    std::vector<std::thread> th;
    for (int t = 0; t < 8; ++t) {
        th.emplace_back([&ti, t] {
            for (int i = 0; i < 1000; ++i) {
                ti.record("dn" + std::to_string(i % 4), "auth-conf", "AES/CTR/NoPadding", 128);
                if (i % 100 == 0) {
                    ti.recordFailure("dn" + std::to_string(t % 4), "e");
                }
                if (i % 250 == 0) {
                    ti.snapshot();
                }
            }
        });
    }
    for (auto & t : th) {
        t.join();
    }
    s = ti.snapshot();
    int64_t conns = 0, fails = 0;
    for (const auto & e : s) {
        conns += e.connections;
        fails += e.failures;
    }
    CHECK(s.size() == 4 && conns == 8000 && fails == 80);

    // bounded
    ti.clear();
    for (size_t i = 0; i < TransferInfo::maxEntries + 5; ++i) {
        ti.record("n" + std::to_string(i), "auth", "", 0);
    }
    CHECK(ti.snapshot().size() == TransferInfo::maxEntries);
    CHECK(!ti.record("another", "auth", "", 0));

    std::printf(failures ? "transferinfo_test: %d FAILED\n" : "transferinfo_test: OK\n", failures);
    return failures ? 1 : 0;
}
