# Installing and testing MediaWiki on DreamCompute

## Summary

1. Copy `config.sh.TEMPLATE` to `config.sh` and fill it out.
1. Upload `config.sh` and `install_mediawiki.sh` to the same directory on an Ubuntu 24.04 server.
1. Run `install_mediawiki.sh` as `root`.

See also `Migrating MediaWiki sites.pdf` (exported from [this Google Doc](https://docs.google.com/document/d/10pSXb6K-w1I-thrCGC-t85hwvz_7nviXadH4OedKR7s/edit?tab=t.h3kucxfk7o76)).

## Load Tester (`load_tester_zipf.pl`)

The `load_tester/load_tester_zipf.pl` script is a concurrent HTTP benchmarking tool. While designed with MediaWiki in mind (e.g., recursive fetching of `load.php` assets), it can be used against any website by providing a URL template. It tracks metrics like Time to Last Byte (TTLB), HTTP status codes, and Cloudflare cache status. It also simulates a private browser memory cache for each worker thread, which can be disabled using the `-n` (`--no-memory-cache`) flag.

### Generating Realistic Traffic (The "Zipf Math")

When not using a pre-defined list of URLs (via the `-f` flag), the script generates random page IDs to insert into the URL template (e.g., `http://target/wiki/Page_%d`). To simulate realistic, Wikipedia-style traffic where a small number of pages receive the vast majority of hits, it uses a **Zipf distribution**.

The distribution is controlled by three parameters:

* `--max-id`: The total number of unique pages available across all site sections (default: 100).
* `--site-sections`: The number of uniform "section buckets" the pages are divided into (default: 50).
* `--skew`: The Zipf skew factor ($s$). A higher number concentrates more traffic on the top-ranked pages (default: 1.1).

**How the math works:**

1. **Pre-calculation (`initialize_zipf`):** The script first determines the number of pages per section (`pps = max_id / site_sections`). It then pre-calculates a Cumulative Distribution Function (CDF) array for a Zipf distribution of size `pps`. The probability of the $i$-th ranked page is proportional to $1 / i^s$.
1. **Section Selection:** For each new request, it uniformly selects a random section bucket (from `0` to `site_sections - 1`).
1. **Rank Selection:** It generates a random floating-point number between 0 and 1. It performs a binary search on the CDF array to find the corresponding "popularity rank" within that section (from `1` to `pps`). The Zipf math ensures that rank 1 is selected most frequently, rank 2 less frequently, and so on, forming a "long tail".
1. **Final ID (`get_next_page_id`):** The final absolute page ID is calculated as: `(section_bucket * pps) + rank`. This ID is then passed to the worker thread to format the target URL.
