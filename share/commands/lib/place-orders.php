<?php
/**
 * Places real orders through the quote and QuoteManagement::submit(), as kapelos orders.
 */
declare(strict_types=1);

use Magento\Catalog\Api\Data\ProductInterface;
use Magento\Catalog\Api\ProductRepositoryInterface;
use Magento\Framework\App\Area;
use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\Config\ScopeConfigInterface;
use Magento\Framework\App\ResourceConnection;
use Magento\Framework\App\State;
use Magento\Framework\DataObject;
use Magento\Framework\DB\Adapter\AdapterInterface;
use Magento\Framework\DB\Select;
use Magento\Framework\EntityManager\MetadataPool;
use Magento\Quote\Model\QuoteFactory;
use Magento\Quote\Model\QuoteManagement;
use Magento\Store\Model\StoreManagerInterface;

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "This runs on the command line only.\n");
    exit(1);
}

require __DIR__ . '/../../app/bootstrap.php';

$defaults = [
    'count'    => 0,
    'items'    => 0,
    'interval' => 0,
    'batches'  => 0,
    'type'     => 'configurable',
    'store'    => 1,
    'payment'  => 'checkmo',
    'shipping' => 'flatrate_flatrate',
    'email'    => '',
    'grid'     => 1,
    'trace'    => 0,
];

$options = $defaults;
foreach (array_slice($argv, 1) as $argument) {
    if (!preg_match('/^--([a-z]+)=(.*)$/', $argument, $matches) || !array_key_exists($matches[1], $defaults)) {
        fwrite(STDERR, "Unknown argument: {$argument}\n");
        fwrite(STDERR, 'Valid: --' . implode('= --', array_keys($defaults)) . "=\n");
        exit(1);
    }
    $options[$matches[1]] = is_int($defaults[$matches[1]]) ? (int) $matches[2] : $matches[2];
}
if (!in_array($options['type'], ['configurable', 'simple'], true)) {
    fwrite(STDERR, "--type is configurable or simple.\n");
    exit(1);
}

$bootstrap = Bootstrap::create(BP, $_SERVER);
$objects = $bootstrap->getObjectManager();
$objects->get(State::class)->setAreaCode(Area::AREA_FRONTEND);

$storeManager    = $objects->get(StoreManagerInterface::class);
$productRepo     = $objects->get(ProductRepositoryInterface::class);
$quoteFactory    = $objects->get(QuoteFactory::class);
$quoteManagement = $objects->get(QuoteManagement::class);
$connection      = $objects->get(ResourceConnection::class)->getConnection();

// Commerce keys the EAV value tables and catalog_product_super_link.parent_id on row_id, not entity_id.
$linkField = $objects->get(MetadataPool::class)->getMetadata(ProductInterface::class)->getLinkField();

$store = $storeManager->getStore($options['store']);
$storeManager->setCurrentStore($store);

/** Made-up US addresses whose city, state and ZIP agree, so address validation has nothing to say. */
$addresses = [
    ['Chesterfield', 'MO', '63005', '17600 Chesterfield Airport Rd'],
    ['Overland Park', 'KS', '66210', '11100 W 95th St'],
    ['Naperville',    'IL', '60540', '2760 Aurora Ave'],
    ['Round Rock',    'TX', '78664', '2601 S IH 35'],
    ['Tempe',         'AZ', '85281', '1300 E Apache Blvd'],
];
$firstNames = ['Avery', 'Jordan', 'Riley', 'Casey', 'Morgan', 'Quinn', 'Reese', 'Rowan'];
$lastNames  = ['Nakamura', 'Okafor', 'Delgado', 'Lindqvist', 'Haddad', 'Petrova', 'Whitfield'];

$attributeId = static function (AdapterInterface $connection, string $code): int {
    return (int) $connection->fetchOne(
        'SELECT attribute_id FROM eav_attribute WHERE attribute_code = ? AND entity_type_id = 4',
        [$code]
    );
};

// MSI decides what can be sold; cataloginventory_stock_item is only right on a store without it.
$hasMsi = (bool) $connection->isTableExists('inventory_source_item');

/** Joins the stock table that decides salability onto a select, against the product table aliased $alias. */
$joinSalable = static function (Select $select, string $alias) use ($hasMsi): Select {
    if ($hasMsi) {
        return $select->join(
            ['stock' => 'inventory_source_item'],
            "stock.sku = {$alias}.sku AND stock.status = 1 AND stock.quantity > 5",
            []
        );
    }

    return $select->join(
        ['stock' => 'cataloginventory_stock_item'],
        "stock.product_id = {$alias}.entity_id AND stock.is_in_stock = 1 AND stock.qty > 5",
        []
    );
};

/**
 * Joins a select on the salable, enabled children of the configurable aliased e.
 */
$joinSalableChildren = static function (Select $select, int $statusAttributeId) use ($linkField, $joinSalable): Select {
    $select
        ->join(['sl' => 'catalog_product_super_link'], "sl.parent_id = e.{$linkField}", [])
        ->join(['c' => 'catalog_product_entity'], 'c.entity_id = sl.product_id', []);
    $joinSalable($select, 'c');

    return $select->join(
        ['cst' => 'catalog_product_entity_int'],
        "cst.{$linkField} = c.{$linkField} AND cst.attribute_id = {$statusAttributeId}"
        . ' AND cst.store_id = 0 AND cst.value = 1',
        []
    );
};

/**
 * A pool of SKUs that can actually be ordered, sampled from a random entity_id floor so the
 * query stays an index range scan; ORDER BY RAND() is unusable on a catalogue of any size.
 */
$fetchSkuPool = static function () use (
    $connection,
    $linkField,
    $options,
    $attributeId,
    $joinSalable,
    $joinSalableChildren
): array {
    $statusAttributeId = $attributeId($connection, 'status');
    $maxProductId = (int) $connection->fetchOne('SELECT MAX(entity_id) FROM catalog_product_entity');

    for ($attempt = 0; $attempt < 8; $attempt++) {
        $floor = random_int(1, max(1, $maxProductId - 20000));

        if ($options['type'] === 'configurable') {
            // A parent is usable only when at least one enabled child is salable.
            $select = $connection->select()
                ->distinct()
                ->from(['e' => 'catalog_product_entity'], ['sku'])
                ->join(
                    ['st' => 'catalog_product_entity_int'],
                    "st.{$linkField} = e.{$linkField} AND st.attribute_id = {$statusAttributeId}"
                    . ' AND st.store_id = 0 AND st.value = 1',
                    []
                )
                ->where('e.type_id = ?', 'configurable')
                ->where('e.entity_id >= ?', $floor)
                ->limit(100);
            $joinSalableChildren($select, $statusAttributeId);
        } else {
            $priceAttributeId = $attributeId($connection, 'price');
            $select = $connection->select()
                ->distinct()
                ->from(['e' => 'catalog_product_entity'], ['sku'])
                ->join(
                    ['st' => 'catalog_product_entity_int'],
                    "st.{$linkField} = e.{$linkField} AND st.attribute_id = {$statusAttributeId}"
                    . ' AND st.store_id = 0 AND st.value = 1',
                    []
                )
                ->join(
                    ['pr' => 'catalog_product_entity_decimal'],
                    "pr.{$linkField} = e.{$linkField} AND pr.attribute_id = {$priceAttributeId}"
                    . ' AND pr.store_id = 0 AND pr.value > 0',
                    []
                )
                ->where('e.type_id = ?', 'simple')
                ->where('e.entity_id >= ?', $floor)
                ->limit(200);
            $joinSalable($select, 'e');
        }

        $skus = $connection->fetchCol($select);
        if (count($skus) >= 3) {
            return $skus;
        }
    }

    throw new RuntimeException("Found no {$options['type']} product that can be ordered.");
};

/** The salable, enabled children of one configurable parent, as SKUs. */
$salableChildSkus = static function (string $parentSku) use ($connection, $attributeId, $joinSalableChildren): array {
    $select = $connection->select()
        ->distinct()
        ->from(['e' => 'catalog_product_entity'], [])
        ->where('e.sku = ?', $parentSku);
    $joinSalableChildren($select, $attributeId($connection, 'status'))->columns(['sku' => 'c.sku']);

    return $connection->fetchCol($select);
};

$skuPool = $fetchSkuPool();

/**
 * Builds the add-to-cart request for one line item, resolving a configurable's child into the
 * super_attribute selection the storefront form would have sent.
 */
$buildRequest = static function (ProductInterface $product, int $qty) use (
    $options,
    $productRepo,
    $salableChildSkus,
    $store
): DataObject {
    // Quote::addProduct takes a bare qty in core, but a plugin on it may type-hint ?DataObject.
    $data = ['qty' => $qty];

    if ($options['type'] !== 'configurable') {
        return new DataObject($data);
    }

    $childSkus = $salableChildSkus((string) $product->getSku());
    if (!$childSkus) {
        throw new RuntimeException('no salable child');
    }

    $superAttributes = [];
    foreach ($product->getTypeInstance()->getConfigurableAttributes($product) as $attribute) {
        $superAttributes[(int) $attribute->getAttributeId()] = $attribute->getProductAttribute()->getAttributeCode();
    }
    if (!$superAttributes) {
        throw new RuntimeException('parent has no configurable attributes');
    }

    // A child with no value for one of the parent's super attributes disqualifies the child, not
    // the parent, so walk the children until one has a complete selection.
    shuffle($childSkus);
    $candidates = array_slice($childSkus, 0, 10);
    $incomplete = [];
    foreach ($candidates as $childSku) {
        $child = $productRepo->get($childSku, false, $store->getId());
        $selection = [];
        foreach ($superAttributes as $attributeId => $code) {
            $value = $child->getData($code);
            if ($value === null || $value === '') {
                $incomplete[$childSku] = $code;
                continue 2;
            }
            $selection[$attributeId] = $value;
        }
        $data['super_attribute'] = $selection;

        return new DataObject($data);
    }

    throw new RuntimeException(sprintf(
        'no child with a complete selection (%d of %d tried, such as %s missing %s)',
        count($candidates),
        count($childSkus),
        (string) array_key_first($incomplete),
        (string) reset($incomplete)
    ));
};

/** Builds a guest quote, submits it, and returns the order that came back. */
$placeOrder = static function (int $itemCount) use (
    $quoteFactory,
    $quoteManagement,
    $productRepo,
    $buildRequest,
    $store,
    $skuPool,
    $addresses,
    $firstNames,
    $lastNames,
    $options
): \Magento\Sales\Api\Data\OrderInterface {
    [$city, $region, $postcode, $street] = $addresses[array_rand($addresses)];
    $firstName = $firstNames[array_rand($firstNames)];
    $lastName  = $lastNames[array_rand($lastNames)];
    $email     = $options['email'] !== ''
        ? $options['email']
        : sprintf('loadtest+%s@example.test', bin2hex(random_bytes(5)));

    $quote = $quoteFactory->create();
    $quote->setStore($store);
    $quote->setCurrency();
    $quote->setCustomerIsGuest(true);
    $quote->setCustomerEmail($email);
    $quote->setCustomerFirstname($firstName);
    $quote->setCustomerLastname($lastName);

    $added = 0;
    $tried = [];
    $rejected = [];
    while ($added < $itemCount && count($tried) < count($skuPool)) {
        $sku = $skuPool[array_rand($skuPool)];
        if (isset($tried[$sku])) {
            continue;
        }
        $tried[$sku] = true;
        try {
            $product = $productRepo->get($sku, false, $store->getId());
            $request = $buildRequest($product, random_int(1, 3));
            // Quote::addProduct returns the reason as a string instead of throwing.
            $result = $quote->addProduct($product, $request);
            if (is_string($result)) {
                $rejected[$sku] = $result;
                continue;
            }
            $added++;
        } catch (\Throwable $e) {
            // Required options, not assigned to this site, or nothing salable left.
            $rejected[$sku] = $e->getMessage();
        }
    }
    if ($added === 0) {
        $detail = [];
        foreach (array_slice($rejected, 0, 3, true) as $sku => $reason) {
            $detail[] = "{$sku}: {$reason}";
        }
        throw new RuntimeException(
            sprintf('Nothing could be added to the cart (%d tried). %s', count($tried), implode(' | ', $detail))
        );
    }

    $address = [
        'firstname'  => $firstName,
        'lastname'   => $lastName,
        'street'     => $street,
        'city'       => $city,
        'country_id' => 'US',
        'region'     => $region,
        'postcode'   => $postcode,
        'telephone'  => '3145550' . random_int(100, 199),
        'email'      => $email,
        'save_in_address_book' => 0,
    ];
    $quote->getBillingAddress()->addData($address);
    $shippingAddress = $quote->getShippingAddress()->addData($address);

    $shippingAddress->setCollectShippingRates(true)->collectShippingRates();
    $method = $options['shipping'];
    $available = [];
    foreach ($shippingAddress->getGroupedAllShippingRates() as $rates) {
        foreach ($rates as $rate) {
            $available[] = $rate->getCode();
        }
    }
    if ($available && !in_array($method, $available, true)) {
        // Which rates a quote gets depends on its weight and destination, so take one it got.
        $method = $available[0];
    }
    $shippingAddress->setShippingMethod($method);

    $quote->setPaymentMethod($options['payment']);
    $quote->setInventoryProcessed(false);
    // Save before touching payment, so the quote and its addresses have ids.
    $quote->save();
    $quote->getPayment()->importData(['method' => $options['payment']]);

    $quote->collectTotals()->save();

    return $quoteManagement->submit($quote);
};

// With async grid indexing on, an order reaches the admin grid only when its cron job runs.
$gridIsAsync = $options['grid'] === 1
    && $objects->get(ScopeConfigInterface::class)->isSetFlag('dev/grid/async_indexing');

$batch = 0;
$placed = 0;
$failed = 0;

do {
    $batch++;
    $orderCount = $options['count'] > 0 ? $options['count'] : random_int(2, 10);

    for ($i = 0; $i < $orderCount; $i++) {
        $itemCount = $options['items'] > 0 ? $options['items'] : random_int(1, 15);
        $started = microtime(true);
        try {
            $order = $placeOrder($itemCount);
            $placed++;
            printf(
                "[%s] %s  %d item(s)  %s %.2f  (%.1fs)\n",
                date('H:i:s'),
                $order->getIncrementId(),
                count($order->getAllVisibleItems()),
                $order->getOrderCurrencyCode(),
                (float) $order->getGrandTotal(),
                microtime(true) - $started
            );
        } catch (\Throwable $e) {
            $failed++;
            printf(
                "[%s] FAILED: %s (%s at %s:%d)\n",
                date('H:i:s'),
                $e->getMessage(),
                get_class($e),
                $e->getFile(),
                $e->getLine()
            );
            if ($options['trace'] === 1) {
                echo $e->getTraceAsString(), "\n";
            }
        }
    }

    if ($gridIsAsync) {
        try {
            // The virtual type, not Model\GridAsyncInsert: di.xml is what binds the order grid onto it.
            $objects->get('SalesOrderIndexGridAsyncInsertCron')->execute();
        } catch (\Throwable $e) {
            printf("[%s] the grid sync failed: %s\n", date('H:i:s'), $e->getMessage());
        }
    }

    if ($options['interval'] <= 0 || ($options['batches'] > 0 && $batch >= $options['batches'])) {
        break;
    }
    printf(
        "[%s] batch %d done (%d placed, %d failed), sleeping %ds\n",
        date('H:i:s'),
        $batch,
        $placed,
        $failed,
        $options['interval']
    );
    sleep($options['interval']);
} while (true);

printf("Done: %d order(s) placed, %d failed.\n", $placed, $failed);
exit($failed > 0 && $placed === 0 ? 1 : 0);
