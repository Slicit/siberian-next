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

    return $pdo;
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

function page(string $body, string $title = 'Notes'): void
{
    $style = file_get_contents(__DIR__ . '/style.css');
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
} catch (Throwable $error) {
    page('<h1>Storage unavailable</h1><p class="muted">' . e($error->getMessage()) . '</p>');
    exit;
}

// Create -------------------------------------------------------------------
if ($path === '/notes' && $method === 'POST') {
    $title = trim((string) ($_POST['title'] ?? ''));
    $body = (string) ($_POST['body'] ?? '');

    if ($title !== '') {
        $statement = $pdo->prepare('INSERT INTO notes (user_email, title, body) VALUES (?, ?, ?) RETURNING id');
        $statement->execute([$user['email'], $title, $body]);
        redirect('/notes/' . $statement->fetch()['id']);
    }
    redirect('/');
}

// Update -------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)/update$#', $path, $matches) && $method === 'POST') {
    $title = trim((string) ($_POST['title'] ?? ''));
    $body = (string) ($_POST['body'] ?? '');

    if ($title !== '') {
        // user_email in the WHERE clause, not only in the INSERT. One tenant's
        // database still holds several people.
        $statement = $pdo->prepare(
            'UPDATE notes SET title = ?, body = ?, updated_at = now() WHERE id = ? AND user_email = ?'
        );
        $statement->execute([$title, $body, (int) $matches[1], $user['email']]);
    }
    redirect('/notes/' . $matches[1]);
}

// Delete -------------------------------------------------------------------
if (preg_match('#^/notes/(\d+)/delete$#', $path, $matches) && $method === 'POST') {
    $statement = $pdo->prepare('DELETE FROM notes WHERE id = ? AND user_email = ?');
    $statement->execute([(int) $matches[1], $user['email']]);
    redirect('/');
}

// Confirm deletion ---------------------------------------------------------
if (preg_match('#^/notes/(\d+)/delete$#', $path, $matches) && $method === 'GET') {
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_email = ?');
    $statement->execute([(int) $matches[1], $user['email']]);
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
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_email = ?');
    $statement->execute([(int) $matches[1], $user['email']]);
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
    $statement = $pdo->prepare('SELECT * FROM notes WHERE id = ? AND user_email = ?');
    $statement->execute([(int) $matches[1], $user['email']]);
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
$statement = $pdo->prepare('SELECT * FROM notes WHERE user_email = ? ORDER BY updated_at DESC');
$statement->execute([$user['email']]);
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
