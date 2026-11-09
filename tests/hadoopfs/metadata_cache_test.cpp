// Unit test of hadoopfs::MetadataCache (patches 0006, 0007), no HDFS: TTL, version change, LRU bound, listings.
#include "hadoopfs_metadata_cache.hpp"

#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

static int failures = 0;
#define CHECK(c)                                                                                                       \
	do {                                                                                                               \
		if (!(c)) {                                                                                                    \
			std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                                         \
			failures++;                                                                                                \
		}                                                                                                              \
	} while (0)

using hadoopfs::CachedFileStatus;
using hadoopfs::MetadataCache;

static CachedFileStatus File(int64_t len, int64_t mtime) {
	CachedFileStatus s;
	s.length = len;
	s.mtime_ms = mtime;
	return s;
}

int main() {
	int64_t now = 1000;
	MetadataCache cache(3, [&] { return now; });
	CachedFileStatus out;

	// off / empty
	CHECK(!cache.GetStatus("nn/a", 0, out));
	CHECK(!cache.GetStatus("nn/a", 5000, out));
	CHECK(!cache.GetBlocks("nn/a", 5000, File(10, 1)));

	// status within / after TTL
	cache.PutStatus("nn/a", File(10, 1));
	now += 4999;
	CHECK(cache.GetStatus("nn/a", 5000, out) && out.length == 10 && out.mtime_ms == 1);
	CHECK(!cache.GetStatus("nn/a", 0, out)); // ttl 0 = off even with an entry
	now += 1;
	CHECK(!cache.GetStatus("nn/a", 5000, out));

	// blocks only for the matching version; dropped when a fresh status differs
	auto blocks = std::make_shared<int>(42);
	cache.PutStatus("nn/a", File(10, 1));
	cache.PutBlocks("nn/a", File(10, 1), blocks);
	CHECK(cache.GetBlocks("nn/a", 5000, File(10, 1)) == blocks);
	CHECK(!cache.GetBlocks("nn/a", 5000, File(10, 2)));
	cache.PutStatus("nn/a", File(10, 1)); // same version re-stat keeps blocks
	CHECK(cache.GetBlocks("nn/a", 5000, File(10, 1)) == blocks);
	cache.PutStatus("nn/a", File(11, 2)); // file replaced
	CHECK(!cache.GetBlocks("nn/a", 5000, File(10, 1)));
	CHECK(!cache.GetBlocks("nn/a", 5000, File(11, 2)));
	cache.PutBlocks("nn/a", File(10, 1), blocks); // stale blocks for an old version are refused
	CHECK(!cache.GetBlocks("nn/a", 5000, File(10, 1)));

	// blocks expire on their own clock
	cache.PutBlocks("nn/a", File(11, 2), blocks);
	now += 5000;
	CHECK(!cache.GetBlocks("nn/a", 5000, File(11, 2)));

	// the cache keeps the blocks alive while a stream uses them, eviction does not free them under a reader
	std::weak_ptr<int> weak = blocks;
	auto held = cache.GetBlocks("nn/a", 100000, File(11, 2));
	blocks.reset();
	cache.Clear();
	CHECK(!weak.expired());
	held.reset();
	CHECK(weak.expired());

	// LRU bound: capacity 3
	cache.PutStatus("nn/1", File(1, 1));
	cache.PutStatus("nn/2", File(2, 1));
	cache.PutStatus("nn/3", File(3, 1));
	CHECK(cache.GetStatus("nn/1", 5000, out)); // 1 most recent
	cache.PutStatus("nn/4", File(4, 1));       // evicts 2
	CHECK(cache.Size() == 3);
	CHECK(!cache.GetStatus("nn/2", 5000, out));
	CHECK(cache.GetStatus("nn/1", 5000, out) && cache.GetStatus("nn/3", 5000, out) &&
	      cache.GetStatus("nn/4", 5000, out));

	// invalidate
	cache.Invalidate("nn/1");
	CHECK(!cache.GetStatus("nn/1", 5000, out));
	cache.Invalidate("nn/none");

	// listings (patch 0007): TTL, trailing '/', invalidation of a child drops the parent's listing only
	CHECK(MetadataCache::DirKey("nn/t/") == "nn/t" && MetadataCache::DirKey("nn/t") == "nn/t");
	CHECK(MetadataCache::ParentKey("nn/t/f0.parquet") == "nn/t" && MetadataCache::ParentKey("nn/t/sub/") == "nn/t");
	{
		MetadataCache lc(100, [&] { return now; });
		CHECK(!lc.GetListing("nn/t", 5000));
		auto listing = std::make_shared<hadoopfs::CachedListing>();
		listing->emplace_back("hdfs://nn/t/f0.parquet", false);
		listing->emplace_back("hdfs://nn/t/sub", true);
		lc.PutListing("nn/t/", listing);
		lc.PutStatus("nn/t/f0.parquet", File(10, 1));
		auto got = lc.GetListing("nn/t", 5000);
		CHECK(got && got->size() == 2 && (*got)[1].is_dir && (*got)[0].path == "hdfs://nn/t/f0.parquet");
		CHECK(!lc.GetListing("nn/t", 0));
		now += 5000;
		CHECK(!lc.GetListing("nn/t", 5000)); // expired
		lc.PutListing("nn/t", listing);
		lc.PutStatus("nn/t/f0.parquet", File(10, 1));
		lc.PutStatus("nn/t", File(0, 1)); // the directory's own status leaves its listing alone
		CHECK(lc.GetListing("nn/t", 5000));
		lc.Invalidate("nn/t/other.parquet"); // a new file in nn/t: listing gone, sibling status kept
		CHECK(!lc.GetListing("nn/t", 5000));
		CHECK(lc.GetStatus("nn/t/f0.parquet", 5000, out));
		lc.PutListing("nn/t", listing);
		lc.Invalidate("nn/u/x"); // another directory: untouched
		CHECK(lc.GetListing("nn/t", 5000));
		lc.Invalidate("nn/t/"); // the directory itself (CreateDirectory / delete)
		CHECK(!lc.GetListing("nn/t", 5000));
		lc.PutListing("nn/t", listing);
		lc.Clear();
		CHECK(!lc.GetListing("nn/t", 5000));
	}

	// concurrent use (run under -fsanitize=thread in CI if wanted)
	MetadataCache shared(1000);
	std::vector<std::thread> threads;
	for (int t = 0; t < 8; t++) {
		threads.emplace_back([&shared, t] {
			CachedFileStatus o;
			for (int i = 0; i < 20000; i++) {
				auto key = "nn/f" + std::to_string((i * 7 + t) % 1500);
				if (!shared.GetStatus(key, 60000, o)) {
					shared.PutStatus(key, File(i % 3, 1));
				}
				if (!shared.GetListing("nn/d" + std::to_string(i % 50), 60000)) {
					shared.PutListing("nn/d" + std::to_string(i % 50), std::make_shared<hadoopfs::CachedListing>());
				}
				if (i % 101 == 0) {
					shared.Invalidate(key);
				}
				if (!shared.GetBlocks(key, 60000, File(i % 3, 1))) {
					shared.PutBlocks(key, File(i % 3, 1), std::make_shared<int>(i));
				}
			}
		});
	}
	for (auto &th : threads) {
		th.join();
	}
	CHECK(shared.Size() <= 1000);

	if (failures) {
		std::fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	std::printf("metadata_cache_test OK\n");
	return 0;
}
