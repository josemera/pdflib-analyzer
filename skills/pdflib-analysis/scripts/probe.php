<?php
/**
 * Reflects the PDFlib extension as actually installed in the base image.
 *
 * This is the authority for what PDFlib is. Not documentation, not recall.
 * Run inside the base image: `run-php.sh --image`. Never on the host — the
 * host does not have the PDFlib extension, so a host run would report the
 * extension as absent and produce an empty (and very wrong) method list.
 *
 * Output: JSON on stdout.
 */

declare(strict_types=1);

// Polyfills, in case the base image is on PHP 7.x. This script has to run
// wherever the extension lives, and failing to probe because of a syntax-level
// dependency would be a silly reason to lose the authoritative method list.
if (!function_exists('str_contains')) {
    function str_contains(string $h, string $n): bool { return $n === '' || strpos($h, $n) !== false; }
}
if (!function_exists('str_starts_with')) {
    function str_starts_with(string $h, string $n): bool { return strncmp($h, $n, strlen($n)) === 0; }
}

$out = [];

$out['probed_at']        = gmdate('c');
$out['php_version']      = PHP_VERSION;
$out['php_sapi']         = PHP_SAPI;
$out['ini_loaded_file']  = php_ini_loaded_file() ?: null;
$out['ini_scanned_files'] = array_values(array_filter(array_map(
    'trim',
    explode(',', (string) php_ini_scanned_files())
)));

$out['extension_loaded'] = extension_loaded('pdflib');
$out['class_exists']     = class_exists('PDFlib');

// Extension version, if the extension registered one.
$out['extension_version'] = null;
foreach (get_loaded_extensions() as $ext) {
    if (strtolower($ext) === 'pdflib') {
        $v = phpversion($ext);
        $out['extension_version'] = ($v === false) ? null : $v;
        break;
    }
}

// --- The object-oriented surface -----------------------------------------

$out['methods']      = [];
$out['method_count'] = 0;
$out['tier']         = 'unknown';

if (class_exists('PDFlib')) {
    $methods = get_class_methods('PDFlib');
    sort($methods, SORT_STRING);
    $out['methods']      = $methods;
    $out['method_count'] = count($methods);

    $lower = array_map('strtolower', $methods);

    $pdi = array_values(array_filter($methods, static function (string $m): bool {
        return str_contains(strtolower($m), 'pdi');
    }));
    $blocks = array_values(array_filter($methods, static function (string $m): bool {
        return str_contains(strtolower($m), 'block');
    }));

    $out['pdi_methods']   = $pdi;
    $out['block_methods'] = $blocks;

    // Tier is inferred from capability, which is what actually matters:
    // if the binary cannot do PDI, no repo can be using PDI.
    if ($blocks !== []) {
        $out['tier'] = 'PPS (Personalization Server)';
    } elseif ($pdi !== []) {
        $out['tier'] = 'PDFlib+PDI';
    } elseif ($methods !== []) {
        $out['tier'] = 'PDFlib (base)';
    }

    // Feature probes by method-name substring. Advisory only — confirm against
    // the official API reference before drawing conclusions.
    $features = [
        'textflow'   => 'textflow',
        'table'      => 'table',
        'form_field' => 'field',
        'annotation' => 'annot',
        'pdfa_pdfx'  => 'pdfa',
        'tagged_pdf' => 'tag',
        'svg'        => 'svg',
        'shading'    => 'shading',
    ];
    $out['feature_hints'] = [];
    foreach ($features as $label => $needle) {
        $hits = array_values(array_filter($methods, static function (string $m) use ($needle): bool {
            return str_contains(strtolower($m), $needle);
        }));
        if ($hits !== []) {
            $out['feature_hints'][$label] = $hits;
        }
    }
    unset($lower);
}

// --- The procedural surface ----------------------------------------------

$internal = get_defined_functions()['internal'] ?? [];
$procedural = array_values(array_filter($internal, static function (string $f): bool {
    return str_starts_with(strtolower($f), 'pdf_');
}));
sort($procedural, SORT_STRING);
$out['procedural_functions'] = $procedural;
$out['procedural_count']     = count($procedural);

// --- Where the binary lives ----------------------------------------------

$out['extension_dir'] = ini_get('extension_dir') ?: null;
$out['notes'] = [];
if (!$out['extension_loaded']) {
    $out['notes'][] = 'pdflib extension is NOT loaded in this image. '
        . 'Check that the correct base image tag was probed, and that the '
        . 'extension is enabled for the CLI SAPI as well as FPM.';
}
if ($out['extension_loaded'] && $out['method_count'] === 0 && $out['procedural_count'] === 0) {
    $out['notes'][] = 'Extension reports as loaded but exposes no API. '
        . 'This is unexpected — investigate before relying on any of this.';
}

echo json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
