<?php

/**
 * Example Notes: a module written in PHP.
 *
 * Its neighbour, demo-tasks, is written in Python. Neither imports an SDK and
 * neither knows anything about the core beyond four HTTP endpoints and a
 * Postgres DSN it was handed at install. That is the whole point of both of
 * them existing.
 *
 * Notes are markdown. Rendering happens here, in the module, because the core
 * has no opinion about what a module puts on its own page.
 */

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';

use League\CommonMark\Environment\Environment;
use League\CommonMark\Extension\CommonMark\CommonMarkCoreExtension;
use League\CommonMark\Extension\GithubFlavoredMarkdownExtension;
use League\CommonMark\MarkdownConverter;

const CORE = 'http://core';
const SESSION_COOKIE = 'siberian_session';

// ---------------------------------------------------------------- core calls

function currentDomain(): string
{
    return $_SERVER['HTTP_X_SIBERIAN_DOMAIN'] ?? explode(':', $_SERVER['HTTP_HOST'] ?? 'localhost')[0];
}

/** One helper for every core call. No SDK, no signing, no client library. */
function coreCall(string $path, string $token, string $method = 'GET', ?string $body = null): array
{
    $handle = curl_init(CORE . $path);
    $headers = [
        'Authorization: Bearer ' . $token,
        // The domain travels with every request. The Router set it on the way
        // in and the core needs it on the way out to resolve per-domain data.
        'X-Siberian-Domain: ' . currentDomain(),
    ];

    curl_setopt_array($handle, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_TIMEOUT => 10,
        CURLOPT_HTTPHEADER => $headers,
    ]);
    if ($body !== null) {
        curl_setopt($handle, CURLOPT_POSTFIELDS, $body);
    }

    $response = curl_exec($handle);
    $status = curl_getinfo($handle, CURLINFO_HTTP_CODE);
    curl_close($handle);

    if ($response === false || $status >= 400) {
        throw new RuntimeException("{$method} {$path} failed with {$status}");
    }

    return json_decode((string) $response, true) ?? [];
}

/**
 * Who is looking at this page.
 *
 * The browser already carries the session cookie, because the module is framed
 * on a subdomain of the domain it was set on. The module cannot read it as a
 * credential; it hands it to Auth, which is the only service that can.
 */
function currentUser(): ?array
{
    $token = $_COOKIE[SESSION_COOKIE] ?? null;
    if (!$token) {
        return null;
    }

    $handle = curl_init(CORE . '/auth/internal/session');
    curl_setopt_array($handle, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 5,
        CURLOPT_HTTPHEADER => [
            'X-Siberian-Session: ' . $token,
            'X-Siberian-Domain: ' . currentDomain(),
        ],
    ]);
    $response = curl_exec($handle);
    $status = curl_getinfo($handle, CURLINFO_HTTP_CODE);
    curl_close($handle);

    if ($response === false || $status !== 200) {
        return null;
    }

    $payload = json_decode((string) $response, true) ?? [];
    return ($payload['authenticated'] ?? false) ? $payload['user'] : null;
}

/** A granted read of a table this module does not own. Audited by the core. */
function productSettings(): array
{
    static $cache = null;
    if ($cache !== null) {
        return $cache;
    }

    try {
        $payload = coreCall('/database/v1/system/core.configuration/settings', getenv('SIBERIAN_DATABASE_TOKEN') ?: '');
        $settings = [];
        foreach ($payload['rows'] ?? [] as $row) {
            $settings[$row['key']] = $row['value'];
        }
        return $cache = $settings;
    } catch (Throwable) {
        // A module that will not render because an optional read failed is
        // worse than one that renders with defaults.
        return $cache = [];
    }
}

// ------------------------------------------------------------- its own store

function db(): PDO
{
    static $pdo = null;
    if ($pdo instanceof PDO) {
        return $pdo;
    }

    $details = coreCall('/database/v1/credentials', getenv('SIBERIAN_DATABASE_TOKEN') ?: '');

    // A direct connection, with credentials the core issued at install. Nothing
    // proxies this: the core handed over a DSN and got out of the way.
    $dsn = sprintf(
        'pgsql:host=%s;port=%d;dbname=%s',
        $details['host'],
        $details['port'],
        $details['database']
    );

    $pdo = new PDO($dsn, $details['username'], $details['password'], [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);

    // A heredoc, not a single-quoted string: the SQL contains '' as an empty
    // default, which would close a single-quoted PHP string mid-statement.
    $pdo->exec(<<<SQL
        CREATE TABLE IF NOT EXISTS notes (
            id         serial PRIMARY KEY,
            user_email text NOT NULL,
            title      text NOT NULL,
            body       text NOT NULL DEFAULT '',
            updated_at timestamptz NOT NULL DEFAULT now(),
            created_at timestamptz NOT NULL DEFAULT now()
        )
    SQL);

    // The stable name the core hands us, added after the first release.
    //
    // Notes used to be keyed by email address, which is how somebody signs in
    // rather than who they are. The core could not let anybody end an account
    // and free the address, because the next person to claim it would open
    // this module and find the previous person's notes; and changing an
    // address would have orphaned every note with nothing reporting it.
    //
    // Nullable, because notes written before this existed have no subject
    // until their owner next visits. See claimRows.
    $pdo->exec('ALTER TABLE notes ADD COLUMN IF NOT EXISTS user_subject text');
    $pdo->exec('CREATE INDEX IF NOT EXISTS notes_for_person ON notes (user_subject, updated_at DESC)');
    $pdo->exec('CREATE INDEX IF NOT EXISTS notes_by_old_key ON notes (user_email) WHERE user_subject IS NULL');
    // The address stops being required, because new notes do not carry one.
    // Keeping a copy of everybody's address in every module database is a cost
    // with no remaining benefit: the core owns the mapping, and a module that
    // never stores an address cannot leak one or be asked to forget one.
    $pdo->exec('ALTER TABLE notes ALTER COLUMN user_email DROP NOT NULL');

    return $pdo;
}


/**
 * Notes written before this module knew about subjects, attached to the person
 * they belong to.
 *
 * Done on a visit rather than as a migration because a module cannot ask the
 * core for the subject behind an address, and should not be able to: that is a
 * lookup from an address to a person, which a module has no business doing.
 * When somebody visits, this module holds both halves and the join is free.
 *
 * PHP starts a fresh process per request, so there is no set to remember this
 * in the way the Python modules do. The partial index makes the statement cheap
 * enough that it does not need one: after the first visit it matches nothing.
 */
function claimRows(PDO $pdo, array $user): void
{
    $statement = $pdo->prepare(
        'UPDATE notes SET user_subject = ? WHERE user_email = ? AND user_subject IS NULL'
    );
    $statement->execute([$user['subject'], $user['email']]);

    // Closed explicitly. A prepared statement left open on a pgsql connection
    // makes the next one on the same connection return nothing from its
    // RETURNING clause, which showed up as a note that was created and then
    // redirected to /notes/ with no id: created successfully, and lost.
    $statement->closeCursor();
}

// ---------------------------------------------------------------- rendering

function markdown(string $source): string
{
    static $converter = null;
    if ($converter === null) {
        $environment = new Environment([
            'html_input' => 'escape',
            'allow_unsafe_links' => false,
        ]);
        $environment->addExtension(new CommonMarkCoreExtension());
        $environment->addExtension(new GithubFlavoredMarkdownExtension());
        $converter = new MarkdownConverter($environment);
    }

    // html_input escape and allow_unsafe_links off, because a note is text a
    // person typed and this module renders it back to them. A markdown field
    // that renders raw HTML is a cross-site scripting hole with a nice name.
    return (string) $converter->convert($source);
}

function e(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

// --------------------------------------------------------------- app palette

/**
 * The app's colours, when this page is being rendered inside the app.
 *
 * A module has two faces. The native one is drawn by the app and inherits its
 * palette for free. This one is HTML the module renders itself, and inside a
 * WebView it is the one part of the app that would ignore the theme, which is
 * exactly where it shows: a dark app with a white page in the middle of it.
 *
 * The shell puts the palette in the query string. There is no SDK here, in
 * either language, which is the point of this module existing: the contract is
 * a query string, so a module in any language reads it in a few lines.
 *
 * Nothing here is trusted for anything but colour. These values land inside a
 * stylesheet, so they are filtered to shapes that cannot end a declaration.
 * Someone who controls the query string controls the palette of a page they
 * are already looking at, and must not be able to control anything else on it.
 */

/** Hex, rgb/rgba, hsl/hsla, or a plain keyword. An allowlist of shapes rather
 *  than an attempt to strip dangerous characters out of arbitrary text. */
const THEME_COLOUR = '/\A(\#[0-9a-fA-F]{3,8}|rgba?\(\s*[\d.\s,%\/]+\)|hsla?\(\s*[\d.\s,%\/deg]+\)|[a-zA-Z]{3,20})\z/';

/** The fields a theme carries, and what a page falls back to. Kept identical to
 *  the Python SDK's defaults, because a module should look the same in either. */
const THEME_DEFAULTS = [
    'background' => '#f7f8fa',
    'surface' => '#ffffff',
    'text' => '#111827',
    'muted' => '#6b7280',
    'line' => '#e5e7eb',
    'accent' => '#2563eb',
    'on-accent' => '#ffffff',
    'danger' => '#b3261e',
    'danger-surface' => '#fee2e2',
];

/** This module's own variable names, mapped onto the app's. The stylesheet is
 *  not renamed to suit the app: the module keeps calling a colour what it
 *  always called it. */
const THEME_VARIABLES = [
    '--bg' => 'background',
    '--fg' => 'text',
    '--muted' => 'muted',
    '--line' => 'line',
    '--accent' => 'accent',
    '--danger' => 'danger',
    '--surface' => 'surface',
];

/** Where the palette is left for the pages after the first one. */
const THEME_COOKIE = 'siberian_theme';

/**
 * The palette the app opened this module with, kept for the pages after it.
 *
 * The shell puts the palette on one URL. Every link, form and redirect after
 * that is this module's own, and none of them can be expected to thread nine
 * colours through by hand: the second page would render unstyled and going
 * back would change the colours again, which reads as the theme being broken
 * rather than as the link having dropped it.
 *
 * Scoped to this module's own path, so one module's palette is not another's,
 * and session scoped, so it goes when the browser does. A module reached
 * without a palette never sets one and never reads one, which is what keeps an
 * ordinary browser visit unthemed.
 */
function themeRemember(): void
{
    if (!isset($_GET['theme']) || $_GET['theme'] === '' || headers_sent()) {
        return;
    }

    $remembered = ['theme' => themeKey(), 'theme_scheme' => themeScheme()];
    foreach (THEME_DEFAULTS as $field => $fallback) {
        $parameter = 'theme_' . lcfirst(str_replace(' ', '', ucwords(str_replace('-', ' ', $field))));
        $remembered[$parameter] = themeColour($field, $fallback);
    }

    // The Router sets the module name on the way in, and it is the one part of
    // the external path this module can know: the prefix is stripped before
    // the request reaches here.
    $module = $_SERVER['HTTP_X_SIBERIAN_MODULE'] ?? '';
    $path = $module !== '' ? '/m/' . $module : '/';

    setcookie(THEME_COOKIE, http_build_query($remembered), [
        'path' => $path,
        'samesite' => 'Lax',
        'secure' => true,
        'httponly' => false,
    ]);
}

/** The palette left behind by an earlier request, if there was one. */
function themeRemembered(): array
{
    static $parsed = null;

    if ($parsed === null) {
        $parsed = [];
        parse_str((string) ($_COOKIE[THEME_COOKIE] ?? ''), $parsed);
    }

    return $parsed;
}

/** A theme parameter, from this request or from the one that opened the module. */
function themeParameter(string $name): string
{
    $asked = trim((string) ($_GET[$name] ?? ''));

    return $asked !== '' ? $asked : trim((string) (themeRemembered()[$name] ?? ''));
}

function themeKey(): string
{
    $asked = themeParameter('theme');

    return preg_match('/\A[a-z0-9_-]{1,32}\z/', $asked) === 1 ? $asked : 'default';
}

function themeScheme(): string
{
    return themeParameter('theme_scheme') === 'dark' ? 'dark' : 'light';
}

function themeAsked(): bool
{
    // Either this request carried a palette, or the one that opened the module
    // did and left it behind.
    return themeParameter('theme') !== '';
}

function themeColour(string $field, string $fallback): string
{
    // The query parameter is camelCase where the CSS name is kebab: the app
    // sends theme_onAccent for what becomes --theme-on-accent.
    $parameter = 'theme_' . lcfirst(str_replace(' ', '', ucwords(str_replace('-', ' ', $field))));
    $value = themeParameter($parameter);

    return ($value !== '' && preg_match(THEME_COLOUR, $value) === 1) ? $value : $fallback;
}

/**
 * A stylesheet fragment pointing this module's variables at the app's.
 *
 * Empty when no app asked, so a page opened directly in a browser keeps its own
 * styling and its own dark mode. Overriding unconditionally would make every
 * module render light for everybody, which is a regression dressed as a
 * feature.
 *
 * Placed after the module's own rules, because they are the same specificity
 * and the later one wins.
 */
function themeBridge(string $selector = ':root'): string
{
    if (!themeAsked()) {
        return '';
    }

    $scheme = themeScheme();

    $palette = '';
    foreach (THEME_DEFAULTS as $field => $fallback) {
        $palette .= '--theme-' . $field . ':' . themeColour($field, $fallback) . ';';
    }

    $adopt = '';
    foreach (THEME_VARIABLES as $name => $field) {
        $adopt .= $name . ':var(--theme-' . $field . ');';
    }

    return $selector . '{color-scheme:' . $scheme . ';' . $palette . '}'
        . $selector . '{' . $adopt . '}';
}

function page(string $body, string $title = 'Notes'): void
{
    // The module's own stylesheet, then the app's palette when an app is framing
    // this page. Nothing is appended when it is not.
    $style = file_get_contents(__DIR__ . '/style.css') . themeBridge();
    echo <<<HTML
    <!doctype html>
    <html lang="en"><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>{$title}</title><style>{$style}</style>
    </head><body><div class="wrap">{$body}</div></body></html>
    HTML;
}

function redirect(string $path): never
{
    header('Location: ' . $path, true, 302);
    exit;
}

// ------------------------------------------------------------------- routing

// Before anything is written, because a cookie is a header: every response
// this request produces carries the palette on, page or redirect alike.
themeRemember();

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($path === '/up') {
    header('Content-Type: application/json');
    echo json_encode(['ok' => true]);
    exit;
}

$user = currentUser();
if (!$user) {
    page(
        '<h1>Not signed in</h1><p class="muted">This module could not identify you. '
        . 'The core owns sign in, so there is nothing here to log into.</p>'
    );
    exit;
}

$settings = productSettings();
$brand = $settings['brand_name'] ?? 'the product';

try {
    $pdo = db();
    claimRows($pdo, $user);
} catch (Throwable $error) {
    page('<h1>Storage unavailable</h1><p class="muted">' . e($error->getMessage()) . '</p>');
    exit;
}

// Create -------------------------------------------------------------------
if ($path === '/notes' && $method === 'POST') {
    $title = trim((string) ($_POST['title'] ?? ''));
    $body = (string) ($_POST['body'] ?? '');

    if ($title !== '') {
        $statement = $pdo->prepare('INSERT INTO notes (user_subject, title, body) VALUES (?, ?, ?) RETURNING id');
        $statement->execute([$user['subject'], $title, $body]);
        redirect('/notes/' . $statement->fetch()['id']);
    }
    redirect('/');
}

// Update -------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)/update$#', $path, $matches) && $method === 'POST') {
    $title = trim((string) ($_POST['title'] ?? ''));
    $body = (string) ($_POST['body'] ?? '');

    if ($title !== '') {
        // user_subject in the WHERE clause, not only in the INSERT. One tenant's
        // database still holds several people.
        $statement = $pdo->prepare(
            'UPDATE notes SET title = ?, body = ?, updated_at = now() WHERE id = ? AND user_subject = ?'
        );
        $statement->execute([$title, $body, (int) $matches[1], $user['subject']]);
    }
    redirect('/notes/' . $matches[1]);
}

// Delete -------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)/delete$#', $path, $matches) && $method === 'POST') {
    $statement = $pdo->prepare('DELETE FROM notes WHERE id = ? AND user_subject = ?');
    $statement->execute([(int) $matches[1], $user['subject']]);
    redirect('/');
}

// Confirm deletion ---------------------------------------------------------
if (preg_match('#^/notes/(\d+)/delete$#', $path, $matches) && $method === 'GET') {
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_subject = ?');
    $statement->execute([(int) $matches[1], $user['subject']]);
    $note = $statement->fetch();

    if (!$note) {
        redirect('/');
    }

    page(
        '<h1>Delete this note?</h1>'
        . '<p class="muted">"' . e($note['title']) . '" will be gone. There is no undo.</p>'
        . '<form method="post" action="/notes/' . (int) $note['id'] . '/delete" class="row">'
        . '<button class="danger">Delete it</button>'
        . '<a class="button" href="/notes/' . (int) $note['id'] . '">Keep it</a>'
        . '</form>',
        'Delete note'
    );
    exit;
}

// Edit ---------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)/edit$#', $path, $matches)) {
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_subject = ?');
    $statement->execute([(int) $matches[1], $user['subject']]);
    $note = $statement->fetch();

    if (!$note) {
        redirect('/');
    }

    page(
        '<a class="back" href="/notes/' . (int) $note['id'] . '">Back to the note</a>'
        . '<h1>Edit</h1>'
        . '<form method="post" action="/notes/' . (int) $note['id'] . '/update" class="stack">'
        . '<input type="text" name="title" value="' . e($note['title']) . '" required>'
        . '<textarea name="body" rows="16" placeholder="Markdown welcome">' . e($note['body']) . '</textarea>'
        . '<div class="row"><button class="primary">Save</button>'
        . '<a class="button" href="/notes/' . (int) $note['id'] . '">Cancel</a>'
        . '<a class="button danger" href="/notes/' . (int) $note['id'] . '/delete">Delete</a></div>'
        . '</form>',
        'Edit note'
    );
    exit;
}

// Show ---------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)$#', $path, $matches)) {
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_subject = ?');
    $statement->execute([(int) $matches[1], $user['subject']]);
    $note = $statement->fetch();

    if (!$note) {
        redirect('/');
    }

    $updated = (new DateTimeImmutable($note['updated_at']))->format('Y-m-d H:i');

    page(
        '<a class="back" href="/">All notes</a>'
        . '<div class="spread"><h1>' . e($note['title']) . '</h1>'
        . '<div class="row"><a class="button" href="/notes/' . (int) $note['id'] . '/edit">Edit</a>'
        . '<a class="button danger" href="/notes/' . (int) $note['id'] . '/delete">Delete</a></div></div>'
        . '<div class="muted small">Updated ' . e($updated) . '</div>'
        . '<article class="rendered">' . markdown((string) $note['body']) . '</article>',
        e($note['title'])
    );
    exit;
}

// List ---------------------------------------------------------------------
$statement = $pdo->prepare('SELECT * FROM notes WHERE user_subject = ? ORDER BY updated_at DESC');
$statement->execute([$user['subject']]);
$notes = $statement->fetchAll();

$items = '';
foreach ($notes as $note) {
    $preview = trim(preg_replace('/\s+/', ' ', strip_tags(markdown((string) $note['body']))) ?? '');
    $items .= '<li><a href="/notes/' . (int) $note['id'] . '"><strong>' . e($note['title']) . '</strong>'
        . '<span class="muted small">' . e(mb_substr($preview, 0, 110)) . '</span></a></li>';
}

$listing = $items !== '' ? '<ul class="notes">' . $items . '</ul>'
    : '<div class="empty">No notes yet. The first one is below.</div>';

page(
    '<h1>Notes</h1>'
    . '<div class="muted small">' . e($user['name']) . ', in ' . e($brand)
    . '. Notes are markdown, rendered by this module.</div>'
    . $listing
    . '<form method="post" action="/notes" class="stack new">'
    . '<input type="text" name="title" placeholder="Title" required>'
    . '<textarea name="body" rows="6" placeholder="Markdown welcome. # Heading, **bold**, `code`, - lists"></textarea>'
    . '<div><button class="primary">Add note</button></div>'
    . '</form>'
    . '<div class="foot muted small">This module is written in PHP. Its neighbour is written in Python. '
    . 'Neither imports an SDK, and the core has no opinion about either.</div>'
);
