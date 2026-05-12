#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use feature 'say';

use Mojo::UserAgent;
use Mojo::Promise;
use Time::HiRes qw(gettimeofday tv_interval);
use Parallel::ForkManager;
use Getopt::Long;
use File::Spec;
use File::Path qw(make_path remove_tree);
use Pod::Usage;
use List::Util qw(shuffle sum max);

# --- CLI Parameter Setup ---
my $url_template;
my $req_per_thread = 10;
my $concurrency    = 5;
my $time_cutoff    = 1.0; 
my $max_id         = 100;
my $cleanup        = 0; 
my $verbose        = 0;
my $tmp_dir        = '/tmp/mw_bench';
my $file_src;
my $seed;
my $help           = 0;
my $max_depth      = 4;
my $unique         = 0;
my $bucket_time    = 3;
my $site_sections  = 50;
my $skew           = 1.1;
my $no_memory_cache = 0;

my $chrome_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

GetOptions(
    'url=s'             => \$url_template,
    'requests=i'        => \$req_per_thread,
    'concurrency|c=i'   => \$concurrency,
    'time-cutoff|t=f'   => \$time_cutoff,
    'max-id=i'          => \$max_id,
    'cleanup'           => \$cleanup,
    'verbose|v'         => \$verbose,
    'temp-dir|d=s'      => \$tmp_dir,
    'file|f=s'          => \$file_src,
    'seed|e=i'          => \$seed,
    'depth=i'           => \$max_depth,
    'unique|u'          => \$unique,
    'bucket-time|b=i'   => \$bucket_time,
    'site-sections|s=i' => \$site_sections,
    'skew|k=f'          => \$skew,
    'no-memory-cache|n' => \$no_memory_cache,
    'help|h|?'          => \$help,
) or pod2usage(2);

pod2usage(1) if $help || !$url_template;

my $h2_support = eval { require Protocol::HTTP2; 1 } ? "Enabled" : "Disabled (Install Protocol::HTTP2)";

my @cdf = initialize_zipf();

# --- Task Preparation ---
my @substitutions;
if ($file_src) {
    open(my $fh, '<', $file_src) or die "Cannot open $file_src: $!";
    @substitutions = map { s/^\s+|\s+$//gr } <$fh>;
    close($fh);
}

my @task_list;
my $grand_total = $concurrency * $req_per_thread;
if ($unique) {
    if ($file_src) {
        my @shuffled = shuffle(@substitutions);
        @task_list = @shuffled[0 .. ($grand_total - 1)];
    } else {
        my @ids = shuffle(1 .. $max_id);
        @task_list = @ids[0 .. ($grand_total - 1)];
    }
} else {
    srand($seed) if defined $seed;
    for (1 .. $grand_total) {
        push @task_list, $file_src ? $substitutions[int(rand(@substitutions))] : get_next_page_id() + 1;
    }
}

my %stats = ( index => {}, load => {}, internal => {}, cf_cache => { HIT => 0, MISS => 0, DYNAMIC => 0, HIT_VALS => [], MISS_VALS => [] } );
my $slow_304_count = 0;
my %global_visited;
my @ttlb_results;

say "Target:      $url_template";
say "HTTP/2:      $h2_support";
say "Mode:        " . ($unique ? "Unique Hits" : "Random Hits");
say "Config:      $concurrency users (Private Browser Caches), Depth: $max_depth";
say "-" x 115;

my $pm = Parallel::ForkManager->new($concurrency);

$pm->run_on_finish(sub {
    my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $data) = @_;
    if (defined $data) {
        $slow_304_count += $data->{slow_304_count} // 0;
        push @ttlb_results, @{$data->{ttlb_vals}} if $data->{ttlb_vals};
        
        $stats{cf_cache}{HIT} += $data->{cf_cache}{HIT} // 0;
        $stats{cf_cache}{MISS} += $data->{cf_cache}{MISS} // 0;
        $stats{cf_cache}{DYNAMIC} += $data->{cf_cache}{DYNAMIC} // 0;
        push @{$stats{cf_cache}{HIT_VALS}}, @{$data->{cf_cache}{HIT_VALS} // []};
        push @{$stats{cf_cache}{MISS_VALS}}, @{$data->{cf_cache}{MISS_VALS} // []};

        while (my ($url, $count) = each %{$data->{visited}}) {
            $global_visited{$url} += $count;
        }

        foreach my $cat ('index', 'load', 'internal') {
            foreach my $code (keys %{$data->{codes}{$cat}}) {
                $stats{$cat}{$code} //= { count => 0, sum => 0, max => 0 };
                my $src = $data->{codes}{$cat}{$code};
                $stats{$cat}{$code}{count} += $src->{count};
                $stats{$cat}{$code}{sum}   += $src->{sum};
                $stats{$cat}{$code}{max} = $src->{max} if $src->{max} > $stats{$cat}{$code}{max};
            }
        }
    }
});

for my $worker_id (1 .. $concurrency) {
    my @my_tasks = splice(@task_list, 0, $req_per_thread);
    last unless @my_tasks;
    $pm->start($worker_id) and next;

    my $worker_cache_dir = File::Spec->catdir($tmp_dir, "worker_$worker_id");
    make_path($worker_cache_dir) unless -d $worker_cache_dir;

    my $ua = Mojo::UserAgent->new(max_active_connections => 100)->request_timeout(60);
    $ua->transactor->name($chrome_ua);

    my $child_data = { 
        slow_304_count => 0, 
        codes => { index => {}, load => {}, internal => {} }, 
        ttlb_vals => [],
        memory_cache => {},
        visited => {},
        cf_cache => { HIT => 0, MISS => 0, DYNAMIC => 0, HIT_VALS => [], MISS_VALS => [] },
    };

    for my $req_num (1 .. scalar @my_tasks) {
        my $percent = ($req_num / scalar @my_tasks) * 100;

        my $target_url = sprintf($url_template, $my_tasks[$req_num - 1]);
        my $t_page_start = [gettimeofday];
        fetch_page_recursive($ua, $target_url, 0, $child_data, {}, $worker_id, $req_num, $worker_cache_dir, $percent);
        push @{$child_data->{ttlb_vals}}, tv_interval($t_page_start);
    }

    remove_tree($worker_cache_dir) if $cleanup;
    $pm->finish(0, $child_data);
}

$pm->wait_all_children;

render_report(\%stats, \@ttlb_results, scalar @task_list, $slow_304_count, $concurrency, $req_per_thread, $time_cutoff, \%global_visited);

sub fetch_page_recursive {
    my ($ua, $url, $depth, $data_ref, $seen_ref, $wid, $rid, $cache_dir, $percent) = @_;
    return if $depth > $max_depth || $seen_ref->{$url}++;

    my $cat = ($url =~ /load\.php/) ? 'load' : 'index';
    
    my $now = time();
    if (!$no_memory_cache && exists $data_ref->{memory_cache}{$url} && $now < $data_ref->{memory_cache}{$url}) {
        $data_ref->{codes}{internal}{'MEM_HIT'} //= { count => 0, sum => 0, max => 0 };
        $data_ref->{codes}{internal}{'MEM_HIT'}{count}++;
        if ($verbose) {
            my $path = Mojo::URL->new($url)->path_query;
            printf("[W:%-2d R:%-4d %3.0f%%] MEM | C:- | %7.4fs | %s\n", $wid, $rid, $percent, 0.0, $path) if $path =~ /index\.php/;
        }
        return;
    }

    my $safe_key = $url =~ s/[^a-zA-Z0-9]/_/gr;
    my $file = File::Spec->catfile($cache_dir, "cache_${safe_key}.bin");
    my $headers = { 'Accept-Language' => 'en-US,en;q=0.5', 'Cache-Control' => 'max-age=0' };
    
    if (-e $file) {
        my $mtime = (stat($file))[9];
        $headers->{'If-Modified-Since'} = Mojo::Date->new($mtime)->to_string;
    }

    my $t0 = [gettimeofday];
    my ($res, $code);
    eval {
        my $tx = $ua->get($url => $headers);
        $res  = $tx->result;
        $code = $res ? $res->code : 999;
    };
    if ($@ || !$code) { $code = 999; }
    my $elapsed = tv_interval($t0);

    $data_ref->{codes}{$cat}{$code} //= { count => 0, sum => 0, max => 0 };
    $data_ref->{codes}{$cat}{$code}{count}++;
    $data_ref->{codes}{$cat}{$code}{sum} += $elapsed;
    $data_ref->{codes}{$cat}{$code}{max} = $elapsed if $elapsed > $data_ref->{codes}{$cat}{$code}{max};
    
    my $cf_code = '-';
    if ($res) {
        my $cf_status = $res->headers->header('cf-cache-status') // '';
        if ($cf_status =~ /HIT/i) {
            $data_ref->{cf_cache}{HIT}++;
            push @{$data_ref->{cf_cache}{HIT_VALS}}, $elapsed;
            $cf_code = 'H';
        } elsif ($cf_status =~ /MISS/i) {
            $data_ref->{cf_cache}{MISS}++;
            push @{$data_ref->{cf_cache}{MISS_VALS}}, $elapsed;
            $cf_code = 'm';
        } elsif ($cf_status =~ /EXPIRED/i) {
            $data_ref->{cf_cache}{MISS}++;
            push @{$data_ref->{cf_cache}{MISS_VALS}}, $elapsed;
            $cf_code = 'x';
        } else {
            $data_ref->{cf_cache}{DYNAMIC}++;
            $cf_code = '-';
        }
    }

    if ($code == 304 && $elapsed > $time_cutoff) { $data_ref->{slow_304_count}++; }
    if ($verbose) {
        my $path = Mojo::URL->new($url)->path_query;
        $data_ref->{visited}{$path}++;
        printf("[W:%-2d R:%-4d %3.0f%%] %s | C:%s | %7.4fs | %-40s %s \n", $wid, $rid, $percent, $code, $cf_code, $elapsed, $path, '*' x ($data_ref->{visited}{$path}-1)) if $path =~ /index\.php/;
    }

    return unless $res;

    if (!$no_memory_cache) {
        my $cache_control = $res->headers->cache_control // '';
        if ($cache_control =~ /max-age=(\d+)/) {
            $data_ref->{memory_cache}{$url} = $now + $1;
        } elsif (my $exp = $res->headers->expires) {
            $data_ref->{memory_cache}{$url} = Mojo::Date->new($exp)->epoch;
        }
    }

    if ($code == 200) {
        $res->save_to($file);
        if (my $lm = $res->headers->last_modified) {
            my $epoch = Mojo::Date->new($lm)->epoch;
            utime($epoch, $epoch, $file);
        }
    }

    if ($depth < $max_depth && ($res->body =~ /load\.php/)) {
        my @next_urls;
        if ($res->headers->content_type && $res->headers->content_type =~ /html/i) {
            $res->dom->find('script[src*="load.php"]:not([async]):not([defer]), link[rel="stylesheet"][href*="load.php"]')
                     ->each(sub {
                         my $attr = $_->attr('src') || $_->attr('href');
                         return unless $attr;
                         push @next_urls, Mojo::URL->new($attr)->to_abs(Mojo::URL->new($url));
                     });
        }
        if (@next_urls) {
            Mojo::Promise->all(map { 
                Mojo::Promise->new(sub {
                    my $resolve = shift;
                    fetch_page_recursive($ua, $_, $depth + 1, $data_ref, $seen_ref, $wid, $rid, $cache_dir, $percent);
                    $resolve->();
                })
            } @next_urls)->wait;
        }
    }
}

sub render_report {
    my ($stats, $ttlbs, $total_main, $slow, $conc, $req, $cut, $visited_ref) = @_;
    my $ttlb_count = scalar @$ttlbs;
    my ($ttlb_sum, $ttlb_max) = (0, 0);
    foreach (@$ttlbs) { $ttlb_sum += $_; $ttlb_max = $_ if $_ > $ttlb_max; }
    my $ttlb_avg = $ttlb_count > 0 ? $ttlb_sum / $ttlb_count : 0;

    my $p80 = calculate_p($ttlbs, 0.80);
    my $p95 = calculate_p($ttlbs, 0.95);
    my $p99 = calculate_p($ttlbs, 0.99);

    say "\n" . "=" x 115;
    say "MEDIAWIKI CONVOY REPORT (v2.8 - Histogram Mode)";
    say "=" x 115;

    say "Threads: $concurrency | Requests/thread: $req_per_thread | URL: $url_template";
    say "-" x 115;
    printf "TOTAL PAGE LOAD (TTLB)   | Avg: %6.4fs | p80: %6.4fs | p95: %6.4fs | p99: %6.4fs | Max: %6.4fs\n", $ttlb_avg, $p80, $p95, $p99, $ttlb_max;
    
    say "-" x 115;
    printf "CLOUDFLARE CACHE STATUS  | Hits: %-6d | Misses: %-6d | Dynamic: %-6d\n", $stats->{cf_cache}{HIT}, $stats->{cf_cache}{MISS}, $stats->{cf_cache}{DYNAMIC};
    
    if (scalar @{$stats->{cf_cache}{HIT_VALS}} > 0) {
        my $h_avg = sum(@{$stats->{cf_cache}{HIT_VALS}}) / scalar @{$stats->{cf_cache}{HIT_VALS}};
        my $h_p80 = calculate_p($stats->{cf_cache}{HIT_VALS}, 0.80);
        my $h_p95 = calculate_p($stats->{cf_cache}{HIT_VALS}, 0.95);
        my $h_p99 = calculate_p($stats->{cf_cache}{HIT_VALS}, 0.99);
        my $h_max = max(@{$stats->{cf_cache}{HIT_VALS}});
        printf "  -> HIT TIMES           | Avg: %6.4fs | p80: %6.4fs | p95: %6.4fs | p99: %6.4fs | Max: %6.4fs\n", $h_avg, $h_p80, $h_p95, $h_p99, $h_max;
    }

    if (scalar @{$stats->{cf_cache}{MISS_VALS}} > 0) {
        my $m_avg = sum(@{$stats->{cf_cache}{MISS_VALS}}) / scalar @{$stats->{cf_cache}{MISS_VALS}};
        my $m_p80 = calculate_p($stats->{cf_cache}{MISS_VALS}, 0.80);
        my $m_p95 = calculate_p($stats->{cf_cache}{MISS_VALS}, 0.95);
        my $m_p99 = calculate_p($stats->{cf_cache}{MISS_VALS}, 0.99);
        my $m_max = max(@{$stats->{cf_cache}{MISS_VALS}});
        printf "  -> MISS TIMES          | Avg: %6.4fs | p80: %6.4fs | p95: %6.4fs | p99: %6.4fs | Max: %6.4fs\n", $m_avg, $m_p80, $m_p95, $m_p99, $m_max;
    }

    # Histogram Logic
    say "-" x 115;
    say "TTLB DISTRIBUTION (${bucket_time}s Buckets)";
    say "-" x 115;
    
    my %buckets;
    my $step = $bucket_time;
    foreach my $val (@$ttlbs) {
        my $b = int($val / $step) * $step;
        # my $b = ($val / $step) * $step;
        $buckets{$b}++;
    }
    
    foreach my $lower (sort { $a <=> $b } keys %buckets) {
        my $upper = $lower + $step;
        my $count = $buckets{$lower};
        my $perc  = ($count / $ttlb_count) * 100;
        my $bar   = "*" x int($perc / 2); # Visual representation
        printf "%2ds - %2ds | %4d | %5.1f%% | %s\n", $lower, $upper, $count, $perc, $bar;
        # printf "%2.2fs - %2.2fs | %4.2f | %5.1f%% | %s\n", $lower, $upper, $count, $perc, $bar;
    }

    my $total_unique_urls = 0;
    my $total_all_visits  = 0;
    my $multi_visit_urls  = 0;
    my $multi_visit_count = 0;

    while (my ($url, $count) = each %$visited_ref) {
        $total_unique_urls++;
        $total_all_visits += $count;

        if ($count > 1) {
            $multi_visit_urls++;
            $multi_visit_count += $count;
        }
    }

    my $percentage = $total_all_visits > 0 
        ? ($multi_visit_count / $total_all_visits) * 100 
        : 0;
    
    say "-" x 115;
    printf "Repeat URLs: %-6d | Repeat count: %-6s | Concentration: %.2f%%\n", $multi_visit_urls, $multi_visit_count, $percentage;
    
    foreach my $cat ('index', 'load', 'internal') {
        next unless keys %{$stats->{$cat}};
        say "-" x 115;
        say "CATEGORY: " . ($cat eq 'internal' ? "BROWSER MEMORY CACHE" : uc($cat) . ".PHP");
        say "-" x 115;
        printf "%-10s | %8s | %10s | %14s | %14s\n", ($cat eq 'internal' ? "Type" : "HTTP Code"), "Count", "Percent", "Avg Time", "Max Time";
        say "-" x 115;
        my $cat_hits = 0;
        foreach my $code (keys %{$stats->{$cat}}) { $cat_hits += $stats->{$cat}{$code}{count}; }
        foreach my $code (sort keys %{$stats->{$cat}}) {
            my $s = $stats->{$cat}{$code};
            printf "%-10s | %8d | %9.2f%% | %13.4fs | %13.4fs\n", $code, $s->{count}, ($s->{count}/$cat_hits)*100, $s->{sum}/$s->{count}, $s->{max};
        }
    }
    say "=" x 115;
}

sub calculate_p {
    my ($ttlbs, $limit) = @_;
    my $ttlb_count = scalar @$ttlbs;
    my $ttlb = 0;
    if ($ttlb_count > 0) {
        my @sorted = sort { $a <=> $b } @$ttlbs;
        my $idx = int($limit * $ttlb_count);
        $idx = $ttlb_count - 1 if $idx >= $ttlb_count;
        $ttlb = $sorted[$idx];
    }
}

sub initialize_zipf {
    my $sum = 0;
    my $ppl = int($max_id / $site_sections);

    for my $i (1 .. $ppl) {
        $sum += 1.0 / ($i ** $skew);
        push @cdf, $sum;
    }

    # Normalize the array so the final value is exactly 1.0
    $_ /= $sum for @cdf;

    return @cdf;
}

sub get_next_page_id {
    my $ppl = int($max_id / $site_sections);

    # Step 1: Pick a site section uniformly (returns 0 to 49)
    my $section_bucket = int(rand($site_sections));
    
    # Step 2: Pick a page popularity rank within that section (returns 1 to 6000)
    my $r = rand();
    my $low = 0;
    my $high = $#cdf;

    while ($low < $high) {
        my $mid = int(($low + $high) / 2);
        if ($r > $cdf[$mid]) {
            $low = $mid + 1;
        } else {
            $high = $mid;
        }
    }
    my $rank_within_section = $low + 1;
    
    # Step 3: Calculate the absolute Page ID
    # E.g., Bucket 2 * 6000 = base 12000. + rank 1 = Page ID 12001.
    my $absolute_page_id = ($section_bucket * $ppl) + $rank_within_section;
    
    # Catch any edge cases (like rounding errors) pushing past the max
    return $absolute_page_id > $max_id ? $max_id : $absolute_page_id;
}