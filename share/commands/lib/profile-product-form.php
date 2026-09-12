<?php
/**
 * Times every modifier behind the admin product edit form, as kapelos profile product-form.
 */

use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\ResourceConnection;

require __DIR__ . '/../../app/bootstrap.php';

$productId = (int)($argv[1] ?? 0);
$storeId = (int)($argv[2] ?? 0);
if (!$productId) {
    fwrite(STDERR, "usage: profile-product-form.php <productId> [storeId]\n");
    exit(1);
}

$bootstrap = Bootstrap::create(BP, $_SERVER);
$om = $bootstrap->getObjectManager();
$om->get(\Magento\Framework\App\State::class)->setAreaCode('adminhtml');
$om->configure($om->get(\Magento\Framework\ObjectManager\ConfigLoaderInterface::class)->load('adminhtml'));

/** @var \Magento\Framework\App\Request\Http $request */
$request = $om->get(\Magento\Framework\App\RequestInterface::class);
$request->setParams(['id' => $productId, 'store' => $storeId]);

$storeManager = $om->get(\Magento\Store\Model\StoreManagerInterface::class);
$store = $storeManager->getStore($storeId);
$storeManager->setCurrentStore($store->getCode());

$conn = $om->get(ResourceConnection::class)->getConnection();
$profiler = null;
try {
    $profiler = $conn->getProfiler();
    $profiler->setEnabled(true);
} catch (\Throwable $e) {
    fwrite(STDERR, "db profiler unavailable: {$e->getMessage()}\n");
}

$snapshot = static function () use ($profiler) {
    if (!$profiler || !$profiler->getEnabled()) {
        return ['count' => 0, 'time' => 0.0, 'queries' => []];
    }
    $queries = $profiler->getQueryProfiles() ?: [];
    $time = 0.0;
    foreach ($queries as $q) {
        $time += $q->getElapsedSecs();
    }
    return ['count' => count($queries), 'time' => $time, 'queries' => $queries];
};

$fmt = static fn(float $s): string => sprintf('%8.3f', $s);

$t0 = microtime(true);
$base = $snapshot();

$product = $om->get(\Magento\Catalog\Api\ProductRepositoryInterface::class)->getById($productId, false, $storeId);
$loadTime = microtime(true) - $t0;
$afterLoad = $snapshot();

$registry = $om->get(\Magento\Framework\Registry::class);
$registry->register('current_product', $product);
$registry->register('product', $product);
$registry->register('current_store', $store);

printf(
    "product %d (%s / type=%s / set=%d) loaded in %ss, %d queries\n\n",
    $productId,
    $product->getSku(),
    $product->getTypeId(),
    (int)$product->getAttributeSetId(),
    trim($fmt($loadTime)),
    $afterLoad['count'] - $base['count']
);

/** @var \Magento\Ui\DataProvider\Modifier\PoolInterface $pool */
$pool = $om->get('Magento\Catalog\Ui\DataProvider\Product\Form\Modifier\Pool');
$modifiers = $pool->getModifiersInstances();

printf("%-78s %8s %8s %7s %8s\n", 'MODIFIER', 'META s', 'DATA s', 'QUERIES', 'SQL s');
printf("%s\n", str_repeat('-', 116));

$rows = [];
$meta = [];
$data = [];
foreach ($modifiers as $name => $modifier) {
    $before = $snapshot();
    $tm = microtime(true);
    try {
        $meta = $modifier->modifyMeta($meta);
    } catch (\Throwable $e) {
        $meta['__err_' . $name] = get_class($e) . ': ' . $e->getMessage();
    }
    $metaTime = microtime(true) - $tm;

    $td = microtime(true);
    try {
        $data = $modifier->modifyData($data);
    } catch (\Throwable $e) {
        $data['__err_' . $name] = get_class($e) . ': ' . $e->getMessage();
    }
    $dataTime = microtime(true) - $td;
    $after = $snapshot();

    $rows[] = [
        'name' => $name,
        'class' => get_class($modifier),
        'meta' => $metaTime,
        'data' => $dataTime,
        'queries' => $after['count'] - $before['count'],
        'sql' => $after['time'] - $before['time'],
    ];
}

usort($rows, static fn($a, $b) => ($b['meta'] + $b['data']) <=> ($a['meta'] + $a['data']));
$totalMeta = $totalData = $totalSql = 0.0;
$totalQueries = 0;
foreach ($rows as $r) {
    $totalMeta += $r['meta'];
    $totalData += $r['data'];
    $totalSql += $r['sql'];
    $totalQueries += $r['queries'];
    if ($r['meta'] + $r['data'] < 0.005) {
        continue;
    }
    printf(
        "%-78s %s %s %7d %s\n",
        substr($r['name'], 0, 78),
        $fmt($r['meta']),
        $fmt($r['data']),
        $r['queries'],
        $fmt($r['sql'])
    );
}
printf("%s\n", str_repeat('-', 116));
printf("%-78s %s %s %7d %s\n", 'TOTAL (' . count($rows) . ' modifiers)', $fmt($totalMeta), $fmt($totalData), $totalQueries, $fmt($totalSql));
printf("\nwall clock since bootstrap: %ss   peak memory: %.1f MB\n", trim($fmt(microtime(true) - $t0)), memory_get_peak_usage(true) / 1048576);

// Slowest individual queries overall.
$all = $snapshot();
if ($all['queries']) {
    $qs = $all['queries'];
    usort($qs, static fn($a, $b) => $b->getElapsedSecs() <=> $a->getElapsedSecs());
    echo "\nslowest queries:\n";
    foreach (array_slice($qs, 0, 15) as $q) {
        printf("  %ss  %s\n", $fmt($q->getElapsedSecs()), substr(preg_replace('/\s+/', ' ', $q->getQuery()), 0, 220));
    }

    $byShape = [];
    foreach ($all['queries'] as $q) {
        $shape = preg_replace(['/\s+/', "/'[^']*'/", '/\b\d+\b/'], [' ', '?', '?'], $q->getQuery());
        $shape = substr($shape, 0, 160);
        $byShape[$shape]['n'] = ($byShape[$shape]['n'] ?? 0) + 1;
        $byShape[$shape]['t'] = ($byShape[$shape]['t'] ?? 0) + $q->getElapsedSecs();
    }
    uasort($byShape, static fn($a, $b) => $b['t'] <=> $a['t']);
    echo "\ntop query shapes by total time (n x shape):\n";
    foreach (array_slice($byShape, 0, 15, true) as $shape => $agg) {
        printf("  %ss  n=%-5d %s\n", $fmt($agg['t']), $agg['n'], $shape);
    }
}
