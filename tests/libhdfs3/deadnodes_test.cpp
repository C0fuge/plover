// Unit test of the process-wide dead DataNode list (patches/libhdfs3/0001). Built against the patched libhdfs3
// source by scripts/test-libhdfs3.sh: g++ -std=c++20 -I<libhdfs3>/src/client deadnodes_test.cpp <libhdfs3>/src/client/DeadNodes.cpp
#include "DeadNodes.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

using Hdfs::Internal::DeadNodes;
using Clock = DeadNodes::Clock;
using std::chrono::milliseconds;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

// replica choice over keys; failed = indexes already failed for the current block
static int pick(DeadNodes & d, const std::vector<std::string> & keys, const std::vector<int> & failed, bool consult,
                Clock::time_point now) {
    return d.choose(keys.size(), [&](size_t i) { for (int f : failed) if ((size_t)f == i) return true; return false; },
                    [&](size_t i) { return keys[i]; }, consult, now);
}

int main() {
    DeadNodes & d = DeadNodes::instance();
    CHECK(&d == &DeadNodes::instance());
    d.clear();
    Clock::time_point t0 = Clock::now();
    const std::string dn1 = "uuid-1@10.0.0.1:9866", dn2 = "uuid-2@10.0.0.2:9866", dn3 = "uuid-3@10.0.0.3:9866";
    std::vector<std::string> nodes = {dn3, dn1};  // namenode order: dead node first

    // empty list: first node, nothing dead
    CHECK(!d.isDead(dn3, t0));
    CHECK(pick(d, nodes, {}, true, t0) == 0);

    // ttl <= 0: no-op
    CHECK(!d.markDead(dn3, 0, t0));
    CHECK(d.size() == 0);

    // mark dead: the live replica is preferred, for every new block / stream (no per-stream state)
    CHECK(d.markDead(dn3, 60000, t0));
    CHECK(!d.markDead(dn3, 60000, t0 + milliseconds(10)));  // already dead: refresh, not new
    CHECK(d.size() == 1);
    CHECK(d.isDead(dn3, t0 + milliseconds(1000)));
    CHECK(pick(d, nodes, {}, true, t0 + milliseconds(1000)) == 1);
    CHECK(pick(d, nodes, {}, false, t0 + milliseconds(1000)) == 0);  // consult off (stream ttl 0) = upstream order
    // the dead node is the only replica left -> still tried
    CHECK(pick(d, {dn3}, {}, true, t0 + milliseconds(1000)) == 0);
    CHECK(pick(d, nodes, {1}, true, t0 + milliseconds(1000)) == 0);
    // all failed for this block -> none
    CHECK(pick(d, nodes, {0, 1}, true, t0 + milliseconds(1000)) == -1);
    // two dead + one live in the middle; dead fallback = first dead in namenode order
    CHECK(d.markDead(dn2, 60000, t0));
    CHECK(pick(d, {dn2, dn1, dn3}, {}, true, t0 + milliseconds(1)) == 1);
    CHECK(pick(d, {dn2, dn3}, {}, true, t0 + milliseconds(1)) == 0);
    CHECK(pick(d, {dn2, dn3}, {0}, true, t0 + milliseconds(1)) == 1);

    // success clears at once
    CHECK(d.markAlive(dn2));
    CHECK(!d.markAlive(dn2));
    CHECK(!d.isDead(dn2, t0 + milliseconds(1)));

    // expiry: refreshed at t0+10 ms -> dead until t0+60010 ms, then dropped and the namenode order applies again
    CHECK(d.isDead(dn3, t0 + milliseconds(60009)));
    CHECK(!d.isDead(dn3, t0 + milliseconds(60010)));
    CHECK(d.size() == 0);
    CHECK(pick(d, nodes, {}, true, t0 + milliseconds(60010)) == 0);
    // expired entry marked again counts as new
    CHECK(d.markDead(dn3, 100, t0));
    CHECK(d.markDead(dn3, 100, t0 + milliseconds(200)));
    // a shorter ttl never shortens a longer one
    CHECK(!d.markDead(dn3, 1, t0 + milliseconds(200)));
    CHECK(d.isDead(dn3, t0 + milliseconds(250)));
    // same uuid, new address = different node
    CHECK(!d.isDead("uuid-3@10.0.0.9:9866", t0 + milliseconds(250)));
    d.clear();
    CHECK(d.size() == 0);

    // concurrent use from reader threads
    std::vector<std::thread> ts;
    for (int t = 0; t < 8; ++t) {
        ts.emplace_back([&d, t] {
            for (int i = 0; i < 20000; ++i) {
                std::string k = "uuid-" + std::to_string((t + i) % 5) + "@h:1";
                if (i % 3 == 0) d.markDead(k, 50); else if (i % 3 == 1) d.isDead(k); else d.markAlive(k);
            }
        });
    }
    for (auto & th : ts) th.join();
    CHECK(d.size() <= 5);
    d.clear();

    std::printf("%s (%d failures)\n", failures ? "deadnodes_test FAILED" : "deadnodes_test OK", failures);
    return failures ? 1 : 0;
}
