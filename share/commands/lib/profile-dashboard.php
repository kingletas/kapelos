<?php
/**
 * Times every block the admin dashboard renders, as kapelos profile dashboard.
 */

use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\ResourceConnection;

require __DIR__ . '/../../app/bootstrap.php';

$storeId = (int)($argv[1] ?? 0);

$bootstrap = Bootstrap::create(BP, $_SERVER);
$om = $bootstrap->getObjectManager();
$om->get(\Magento\Framework\App\State::class)->setAreaCode('adminhtml');
$om->configure($om->get(\Magento\Framework\ObjectManager\ConfigLoaderInterface::class)->load('adminhtml'));

/** @var \Magento\Framework\App\Request\Http $request */
$request = $om->get(\Magento\Framework\App\RequestInterface::class);
$request->setParams(['store' => $storeId]);

$storeManager = $om->get(\Magento\Store\Model\StoreManagerInterface::class);
$storeManager->setCurrentStore($storeManager->getStore($storeId)->getCode());

$conn = $om->get(ResourceConnection::class)->getConnection();
$prof = $conn->getProfiler();
$prof->setEnabled(true);

$snapshot = static function () use ($prof) {
    $queries = $prof->getQueryProfiles() ?: [];
    $time = 0.0;
    foreach ($queries as $q) {
        $time += $q->getElapsedSecs();
    }
    return ['count' => count($queries), 'time' => $time];
};

/** @var \Magento\Framework\View\LayoutInterface $layout */
$layout = $om->get(\Magento\Framework\View\LayoutInterface::class);

$blocks = [
    ['sync', 'dashboard.lastOrders (Orders\Grid)', \Magento\Backend\Block\Dashboard\Orders\Grid::class],
    ['sync', 'dashboard.totals', \Magento\Backend\Block\Dashboard\Totals::class],
    ['sync', 'dashboard.sales', \Magento\Backend\Block\Dashboard\Sales::class],
    ['sync', 'dashboard.grids (tab shell)', \Magento\Backend\Block\Dashboard\Grids::class],
    ['ajax', 'Bestsellers tab (Products\Ordered)', \Magento\Backend\Block\Dashboard\Tab\Products\Ordered::class],
    ['ajax', 'Most Viewed tab (Products\Viewed)', \Magento\Backend\Block\Dashboard\Tab\Products\Viewed::class],
    ['ajax', 'New Customers tab (Customers\Newest)', \Magento\Backend\Block\Dashboard\Tab\Customers\Newest::class],
    ['ajax', 'Customers tab (Customers\Most)', \Magento\Backend\Block\Dashboard\Tab\Customers\Most::class],
];

printf("%-6s %-44s %9s %8s %9s %9s\n", 'WHEN', 'BLOCK', 'SECONDS', 'QUERIES', 'SQL s', 'BYTES');
printf("%s\n", str_repeat('-', 92));

$syncTotal = 0.0;
foreach ($blocks as [$when, $label, $class]) {
    $before = $snapshot();
    $t = microtime(true);
    $bytes = 0;
    $err = null;
    try {
        $block = $layout->createBlock($class);
        $bytes = strlen((string)$block->toHtml());
    } catch (\Throwable $e) {
        $err = get_class($e) . ': ' . $e->getMessage();
    }
    $secs = microtime(true) - $t;
    $after = $snapshot();
    if ($when === 'sync') {
        $syncTotal += $secs;
    }
    printf(
        "%-6s %-44s %9.3f %8d %9.3f %9s%s\n",
        $when,
        substr($label, 0, 44),
        $secs,
        $after['count'] - $before['count'],
        $after['time'] - $before['time'],
        number_format($bytes),
        $err ? '  !! ' . substr($err, 0, 60) : ''
    );
}
printf("%s\n", str_repeat('-', 92));
printf("%-6s %-44s %9.3f\n", 'sync', 'TOTAL rendered on page load', $syncTotal);
printf("\npeak memory: %.1f MB\n", memory_get_peak_usage(true) / 1048576);

// Slowest queries across the whole run.
$all = $prof->getQueryProfiles() ?: [];
usort($all, static fn($a, $b) => $b->getElapsedSecs() <=> $a->getElapsedSecs());
echo "\nslowest queries:\n";
foreach (array_slice($all, 0, 4) as $q) {
    printf("  %8.3fs  %s\n", $q->getElapsedSecs(), substr(preg_replace('/\s+/', ' ', $q->getQuery()), 0, 4000));
}
