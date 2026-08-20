<?php
/**
 * Validation gates for an extraction run.
 *
 * FALSE POSITIVES (hard gate): every method name in extraction.json must appear
 * in the reflected method list. A failure means the parser attributed a wrapper
 * method to PDFlib.
 *
 * FALSE NEGATIVES (warning): for each reflected method name, count textual
 * occurrences in the repo and compare to the parser's count. Benign mismatches
 * exist — a name in a comment, a docblock, a string. But a parser count BELOW
 * the grep count means a real call site was missed, and that is the failure
 * mode that survives this whole exercise and breaks after the migration ships.
 *
 * Usage:
 *   crosscheck.php --repo <repo-path> \
 *                  --extraction <extraction.json> \
 *                  --methods <pdflib-methods.txt> \
 *                  [--functions <pdflib-functions.txt>] \
 *                  [--json-out <report.json>]
 *
 * Exit codes: 0 pass, 1 false positives (hard failure), 2 usage error.
 * False-negative warnings do not change the exit code — they are reported.
 */

declare(strict_types=1);

if (!function_exists('str_contains')) {
    function str_contains(string $h, string $n): bool { return $n === '' || strpos($h, $n) !== false; }
}
if (!function_exists('str_starts_with')) {
    function str_starts_with(string $h, string $n): bool { return strncmp($h, $n, strlen($n)) === 0; }
}
if (!function_exists('str_ends_with')) {
    function str_ends_with(string $h, string $n): bool { return $n === '' || substr($h, -strlen($n)) === $n; }
}

function arg(string $name, ?string $default = null): ?string
{
    global $argv;
    $flag = '--' . $name;
    foreach ($argv as $i => $a) {
        if ($a === $flag) {
            return $argv[$i + 1] ?? null;
        }
        if (str_starts_with($a, $flag . '=')) {
            return substr($a, strlen($flag) + 1);
        }
    }
    return $default;
}

$repo       = arg('repo');
$extraction = arg('extraction');
$methodsF   = arg('methods');
$functionsF = arg('functions');
$jsonOut    = arg('json-out');

if ($repo === null || $extraction === null || $methodsF === null) {
    fwrite(STDERR, "Usage: crosscheck.php --repo <path> --extraction <file> --methods <file> [--functions <file>] [--json-out <file>]\n");
    exit(2);
}

foreach (['repo' => $repo, 'extraction' => $extraction, 'methods' => $methodsF] as $label => $path) {
    if (!file_exists($path)) {
        fwrite(STDERR, "ERROR: $label not found: $path\n");
        exit(2);
    }
}

$reflected = array_values(array_filter(array_map('trim', file($methodsF))));
if ($reflected === []) {
    fwrite(STDERR, "ERROR: reflected method list is empty. Re-run /pdflib-setup.\n");
    exit(2);
}
$reflectedLower = array_map('strtolower', $reflected);

$procedural = [];
if ($functionsF !== null && file_exists($functionsF)) {
    $procedural = array_map('strtolower', array_values(array_filter(array_map('trim', file($functionsF)))));
}

$data = json_decode((string) file_get_contents($extraction), true);
if (!is_array($data)) {
    fwrite(STDERR, "ERROR: could not parse extraction JSON: $extraction\n");
    exit(2);
}

// --- Parser counts --------------------------------------------------------

$parserCounts = [];
foreach (($data['call_sites'] ?? []) as $cs) {
    $m = strtolower((string) ($cs['method'] ?? ''));
    if ($m === '') {
        continue;
    }
    // Normalise the procedural form so both styles compare against the same key.
    $normalised = str_starts_with($m, 'pdf_') ? substr($m, 4) : $m;
    $parserCounts[$normalised] = ($parserCounts[$normalised] ?? 0) + 1;
}

// --- Gate 1: false positives ---------------------------------------------

$falsePositives = [];
foreach (array_keys($parserCounts) as $m) {
    if (!in_array($m, $reflectedLower, true) && !in_array('pdf_' . $m, $procedural, true)) {
        $falsePositives[$m] = $parserCounts[$m];
    }
}

// --- Gate 2: false negatives ---------------------------------------------

$phpFiles = [];
$it = new RecursiveIteratorIterator(
    new RecursiveCallbackFilterIterator(
        new RecursiveDirectoryIterator($repo, FilesystemIterator::SKIP_DOTS),
        static function ($current): bool {
            $name = $current->getFilename();
            if ($current->isDir()) {
                return !in_array($name, ['vendor', 'node_modules', '.git', 'storage', 'cache'], true);
            }
            return str_ends_with(strtolower($name), '.php');
        }
    )
);
foreach ($it as $f) {
    if ($f->isFile()) {
        $phpFiles[] = $f->getPathname();
    }
}

$grepCounts = [];
foreach ($phpFiles as $file) {
    $src = file_get_contents($file);
    if ($src === false || $src === '') {
        continue;
    }
    $lower = strtolower($src);
    foreach ($reflectedLower as $m) {
        // Cheap substring test first — skips almost every method for almost
        // every file, which matters when this is O(files x methods).
        if (!str_contains($lower, $m)) {
            continue;
        }
        // Word-boundary count of the bare method name and the PDF_ form.
        $n = preg_match_all('/(?<![a-z0-9_])(?:pdf_)?' . preg_quote($m, '/') . '\s*\(/i', $lower);
        if ($n > 0) {
            $grepCounts[$m] = ($grepCounts[$m] ?? 0) + $n;
        }
    }
}

$falseNegatives = [];
foreach ($grepCounts as $m => $g) {
    $p = $parserCounts[$m] ?? 0;
    if ($p < $g) {
        $falseNegatives[] = ['method' => $m, 'grep' => $g, 'parser' => $p, 'missing' => $g - $p];
    }
}
usort($falseNegatives, static fn($a, $b) => $b['missing'] <=> $a['missing']);

$parserOnly = [];
foreach ($parserCounts as $m => $p) {
    $g = $grepCounts[$m] ?? 0;
    if ($p > $g) {
        $parserOnly[] = ['method' => $m, 'grep' => $g, 'parser' => $p];
    }
}

// --- Report ---------------------------------------------------------------

$report = [
    'repo'                  => $repo,
    'php_files_scanned'     => count($phpFiles),
    'reflected_method_count'=> count($reflected),
    'parser_call_sites'     => array_sum($parserCounts),
    'distinct_methods'      => count($parserCounts),
    'false_positives'       => $falsePositives,
    'false_negatives'       => $falseNegatives,
    'parser_exceeds_grep'   => $parserOnly,
    'needs_review_count'    => count($data['needs_review'] ?? []),
];

if ($jsonOut !== null) {
    file_put_contents($jsonOut, json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
}

echo "PHP files scanned:      {$report['php_files_scanned']}\n";
echo "Call sites extracted:   {$report['parser_call_sites']}\n";
echo "Distinct methods:       {$report['distinct_methods']}\n";
echo "needs_review entries:   {$report['needs_review_count']}\n\n";

if ($falsePositives !== []) {
    echo "GATE FAILED — false positives (not PDFlib methods):\n";
    foreach ($falsePositives as $m => $n) {
        echo "  $m  ($n call sites)\n";
    }
    echo "\nThese are wrapper methods or parser bugs. Fix the parser.\n";
    echo "Never edit the reflected method list to make this pass.\n";
} else {
    echo "GATE PASSED — every extracted method exists in the installed PDFlib.\n";
}

echo "\n";

if ($falseNegatives !== []) {
    echo "WARNING — possible missed call sites (grep found more than the parser):\n";
    foreach ($falseNegatives as $fn) {
        echo "  {$fn['method']}: grep {$fn['grep']}, parser {$fn['parser']} (missing {$fn['missing']})\n";
    }
    echo "\nInvestigate each one. Some will be comments, docblocks, or strings —\n";
    echo "record those in needs-review.md with the reason. Any that are real\n";
    echo "call sites are parser bugs: add a fixture first, then fix.\n";
} else {
    echo "No missed call sites detected.\n";
}

if ($parserOnly !== []) {
    echo "\nNOTE — parser found more than grep (usually multi-line calls, which is\n";
    echo "expected and is the reason a parser is used at all):\n";
    foreach ($parserOnly as $po) {
        echo "  {$po['method']}: grep {$po['grep']}, parser {$po['parser']}\n";
    }
}

exit($falsePositives !== [] ? 1 : 0);
