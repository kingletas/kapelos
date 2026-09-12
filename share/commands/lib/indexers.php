<?php
/**
 * Every indexer with its mode, its state and how far its changelog has run ahead of it,
 * as kapelos indexers.
 */
declare(strict_types=1);

use Magento\Framework\App\Area;
use Magento\Framework\App\Bootstrap;
use Magento\Framework\App\State;
use Magento\Indexer\Model\Indexer\CollectionFactory;

require __DIR__ . '/../../app/bootstrap.php';

$bootstrap = Bootstrap::create(BP, $_SERVER);
$objects = $bootstrap->getObjectManager();
$objects->get(State::class)->setAreaCode(Area::AREA_ADMINHTML);

$rows = [];
$behindTotal = 0;
foreach ($objects->get(CollectionFactory::class)->create()->getItems() as $indexer) {
    $scheduled = $indexer->isScheduled();
    $behind = '';
    $backlogState = '';

    if ($scheduled) {
        try {
            $view = $indexer->getView();
            $pending = (int) $view->getChangelog()->getVersion() - (int) $view->getState()->getVersionId();
            $behind = (string) max(0, $pending);
            $behindTotal += max(0, $pending);
            $backlogState = (string) $view->getState()->getStatus();
        } catch (\Throwable $e) {
            // A scheduled indexer whose changelog table was never made has no backlog to read.
            $behind = '?';
            $backlogState = 'no changelog';
        }
    }

    $rows[] = [
        (string) $indexer->getId(),
        $scheduled ? 'schedule' : 'save',
        (string) $indexer->getStatus(),
        $behind,
        $backlogState,
        (string) ($indexer->getLatestUpdated() ?: 'never'),
    ];
}

printf("%-36s %-9s %-12s %10s %-13s %s\n", 'INDEXER', 'MODE', 'STATUS', 'BEHIND', 'MVIEW', 'UPDATED');
printf("%s\n", str_repeat('-', 104));
foreach ($rows as [$id, $mode, $status, $behind, $backlogState, $updated]) {
    printf("%-36s %-9s %-12s %10s %-13s %s\n", $id, $mode, $status, $behind, $backlogState, $updated);
}
printf("%s\n", str_repeat('-', 104));

$invalid = count(array_filter($rows, static fn(array $row): bool => $row[2] !== 'valid'));
printf(
    "%d indexer(s), %d not valid, %s row(s) waiting in the changelogs.\n",
    count($rows),
    $invalid,
    number_format($behindTotal)
);
echo "\nBEHIND is how many changed rows a scheduled indexer hasn't caught up on yet. It only falls\n";
echo "when cron runs, so a number that keeps climbing on this stack usually means CRON=no.\n";
