<?php
/**
 * Times a UI listing the way the admin does, then prints the plans, indexes and server settings
 * behind each query, as kapelos profile grid.
 */

use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\View\Element\UiComponent\DataProvider\CollectionFactory;

require __DIR__ . '/../../app/bootstrap.php';

$pageSize = (int)($argv[1] ?? 20);
$dataSource = $argv[2] ?? 'sales_order_grid_data_source';
$sortColumn = $argv[3] ?? 'created_at';

$bootstrap = Bootstrap::create(BP, $_SERVER);
$om = $bootstrap->getObjectManager();
$om->get(\Magento\Framework\App\State::class)->setAreaCode('adminhtml');
$om->configure($om->get(\Magento\Framework\ObjectManager\ConfigLoaderInterface::class)->load('adminhtml'));

$storeManager = $om->get(\Magento\Store\Model\StoreManagerInterface::class);
$storeManager->setCurrentStore($storeManager->getStore(0)->getCode());

$conn = $om->get(ResourceConnection::class)->getConnection();
$prof = $conn->getProfiler();
$prof->setEnabled(true);
$snap = static function () use ($prof) {
    $qs = $prof->getQueryProfiles() ?: [];
    $t = 0.0;
    foreach ($qs as $q) {
        $t += $q->getElapsedSecs();
    }
    return ['n' => count($qs), 't' => $t];
};

$report = [];
$step = static function (string $label, callable $fn) use (&$report, $snap) {
    $before = $snap();
    $t = microtime(true);
    $extra = '';
    try {
        $extra = (string)$fn();
    } catch (\Throwable $e) {
        $extra = '!! ' . get_class($e) . ': ' . $e->getMessage();
    }
    $secs = microtime(true) - $t;
    $after = $snap();
    $report[] = [$label, $secs, $after['n'] - $before['n'], $after['t'] - $before['t'], $extra];
};

/** @var CollectionFactory $collectionFactory */
$collectionFactory = $om->get(CollectionFactory::class);

$collection = null;
$step('CollectionFactory->getReport()', static function () use ($collectionFactory, $dataSource, &$collection) {
    $collection = $collectionFactory->getReport($dataSource);
    return get_class($collection);
});

if ($collection === null) {
    fwrite(STDERR, "could not build a collection for '$dataSource'\n");
    exit(1);
}

$collection->setPageSize($pageSize);
$collection->setCurPage(1);

// Listings sort on different columns, and asking for one a table doesn't have is a fatal.
$mainTable = '';
try {
    $mainTable = (string)$collection->getMainTable();
} catch (\Throwable $e) {
    $mainTable = '';
}
if ($sortColumn === '-') {
    echo "sorting: none\n";
} elseif ($mainTable !== '' && !array_key_exists($sortColumn, $conn->describeTable($mainTable))) {
    printf("sorting: none, because %s has no %s column. Name one as the third argument, or - for none.\n", $mainTable, $sortColumn);
} else {
    $collection->addOrder($sortColumn, 'DESC');
}

$size = null;
$step('getSize()  [the COUNT query]', static function () use ($collection, &$size) {
    $size = $collection->getSize();
    return "size=$size";
});

$step('load()     [one page of rows]', static function () use ($collection, $pageSize) {
    $collection->load();
    return 'rows=' . count($collection->getItems()) . " (pageSize=$pageSize)";
});

$step('toArray()  [row hydration]', static function () use ($collection) {
    return 'bytes=' . strlen(json_encode($collection->toArray()));
});

printf("data source: %s\n\n", $dataSource);
printf("%-34s %9s %8s %9s  %s\n", 'STEP', 'SECONDS', 'QUERIES', 'SQL s', 'DETAIL');
printf("%s\n", str_repeat('-', 104));
$total = 0.0;
foreach ($report as [$label, $secs, $n, $sql, $extra]) {
    $total += $secs;
    printf("%-34s %9.3f %8d %9.3f  %s\n", $label, $secs, $n, $sql, substr($extra, 0, 60));
}
printf("%s\n", str_repeat('-', 104));
printf("%-34s %9.3f\n", 'TOTAL', $total);

echo "\n--- COUNT sql ---\n" . $collection->getSelectCountSql() . "\n";
echo "\n--- page sql (the select the collection built) ---\n" . $collection->getSelect() . "\n";

$all = $prof->getQueryProfiles() ?: [];
usort($all, static fn($a, $b) => $b->getElapsedSecs() <=> $a->getElapsedSecs());
echo "\nslowest queries:\n";
foreach (array_slice($all, 0, 8) as $q) {
    printf("  %8.3fs  %s\n", $q->getElapsedSecs(), substr(preg_replace('/\s+/', ' ', $q->getQuery()), 0, 300));
}

/**
 * EXPLAIN for the queries that actually ran, so the plan can be read next to the timing.
 */
$explain = static function (string $sql, array $params) use ($conn): void {
    try {
        $rows = $conn->fetchAll('EXPLAIN ' . $sql, $params);
    } catch (\Throwable $e) {
        printf("    (could not explain: %s)\n", $e->getMessage());
        return;
    }
    printf("    %-24s %-8s %-38s %-10s %-12s %s\n", 'TABLE', 'TYPE', 'KEY', 'ROWS', 'REF', 'EXTRA');
    foreach ($rows as $row) {
        printf(
            "    %-24s %-8s %-38s %-10s %-12s %s\n",
            substr((string)($row['table'] ?? ''), 0, 24),
            (string)($row['type'] ?? ''),
            substr((string)($row['key'] ?? '(none)'), 0, 38),
            (string)($row['rows'] ?? ''),
            substr((string)($row['ref'] ?? ''), 0, 12),
            (string)($row['Extra'] ?? '')
        );
    }
};

echo "\n--- plans for the queries that ran ---\n";
$explained = 0;
foreach ($all as $q) {
    $sql = trim($q->getQuery());
    if (stripos($sql, 'select') !== 0 || $explained >= 5) {
        continue;
    }
    $explained++;
    printf("\n  %8.3fs  %s\n", $q->getElapsedSecs(), substr(preg_replace('/\s+/', ' ', $sql), 0, 160));
    $explain($sql, $q->getQueryParams() ?: []);
}

/**
 * Indexes on every table the grid touches. A plan that scans is only a mystery until you know
 * whether the index it would have needed exists at all.
 */
$tables = [];
foreach ([$collection->getSelectCountSql(), $collection->getSelect()] as $select) {
    foreach ((array)$select->getPart(\Magento\Framework\DB\Select::FROM) as $spec) {
        if (!empty($spec['tableName'])) {
            $tables[(string)$spec['tableName']] = true;
        }
    }
}
$tables = array_keys($tables);

echo "\n--- tables and indexes ---\n";
$sizes = $conn->fetchAssoc(
    $conn->quoteInto(
        'SELECT table_name, table_rows, ROUND(data_length/1048576) AS data_mb,
                ROUND(index_length/1048576) AS index_mb
           FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN (?)',
        $tables
    )
);
foreach ($tables as $table) {
    $size = $sizes[$table] ?? [];
    printf(
        "\n  %s  ~%s rows, %s MB data, %s MB index\n",
        $table,
        number_format((float)($size['table_rows'] ?? 0)),
        (string)($size['data_mb'] ?? '?'),
        (string)($size['index_mb'] ?? '?')
    );
    $columns = [];
    foreach ($conn->fetchAll('SHOW INDEX FROM ' . $conn->quoteIdentifier($table)) as $row) {
        $columns[$row['Key_name']][(int)$row['Seq_in_index']] = $row['Column_name']
            . ($row['Non_unique'] ? '' : ' [unique]');
    }
    foreach ($columns as $keyName => $keyColumns) {
        ksort($keyColumns);
        printf("      %-52s %s\n", $keyName, implode(', ', $keyColumns));
    }
}

echo "\n--- server ---\n";
printf("  version: %s\n", (string)$conn->fetchOne('SELECT VERSION()'));
$variables = [
    'innodb_buffer_pool_size',
    'join_buffer_size',
    'sort_buffer_size',
    'join_cache_level',
    'optimizer_use_condition_selectivity',
    'optimizer_switch',
];
$serverVariables = $conn->fetchPairs('SHOW VARIABLES');
foreach ($variables as $name) {
    if (isset($serverVariables[$name])) {
        printf("  %-38s %s\n", $name, $serverVariables[$name]);
    }
}
